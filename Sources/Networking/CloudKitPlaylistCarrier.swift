// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CloudKit
import Foundation
import OSLog

/// One Mär playlist as CloudKit carries it: the list id, the list as bytes
/// (its `MaerPlaylistMerge.Entry` as JSON, the same tolerant shape the
/// key-value blob uses), the moment, and whether it is a tombstone (a
/// deleted list, kept as a record with an empty payload so the deletion
/// travels and the newest wins, like the pot's zero entry). One record type,
/// a tombstone is a FLAG, not a second type.
nonisolated struct CloudPlaylistRecord: Equatable, Sendable {
    var listId: String
    var payload: Data
    var t: Double
    var tombstone: Bool
}

/// The playlist zone: `playlists`, one record type `Playlist`, one record
/// per list, record name = the list id (a UUID, well under the 255-char
/// cap, so a deletion maps straight back). The mechanics live in
/// `CKZoneDatabase`; this is the third codec on it.
nonisolated enum CloudPlaylistCodec: CloudRecordCodec {
    typealias Value = CloudPlaylistRecord
    static let zoneName = "playlists"
    static let recordType = "Playlist"
    static let subscriptionID = "playlists-zone"

    static func recordName(for value: CloudPlaylistRecord) -> String { value.listId }

    static func fill(_ record: CKRecord, with value: CloudPlaylistRecord) {
        record["list"] = value.listId as CKRecordValue
        record["payload"] = value.payload as CKRecordValue
        record["t"] = value.t as CKRecordValue
        record["tombstone"] = (value.tombstone ? 1 : 0) as CKRecordValue
    }

    static func value(from record: CKRecord) -> CloudPlaylistRecord? {
        guard let listId = record["list"] as? String,
              let t = record["t"] as? Double else { return nil }
        let payload = (record["payload"] as? Data) ?? Data()
        let tombstone = (record["tombstone"] as? Int64 ?? 0) != 0
        return CloudPlaylistRecord(listId: listId, payload: payload, t: t, tombstone: tombstone)
    }
}

/// The questions the playlist carrier asks its zone.
typealias CloudPlaylistDatabase = CloudZoneDatabase<CloudPlaylistRecord>
/// The real thing for the playlists: the zone database over the codec.
typealias CKPlaylistDatabase = CKZoneDatabase<CloudPlaylistCodec>

/// A single playlist entry on the wire: its `MaerPlaylistMerge.Entry` as
/// JSON in the same plist-shaped dictionary the key-value blob uses (one
/// tolerant shape for every carrier), sorted so the same entry gives the
/// same bytes.
nonisolated enum MaerPlaylistEntryWire {
    static func encode(_ entry: MaerPlaylistMerge.Entry) -> Data {
        // CloudKit leaves the device out when the list carries none.
        let dict = KeyValuePlaylistCarrier.payload(of: entry, device: entry.device)
        // bearable, because a dictionary of plist values always encodes; a failure would be an empty body, which the tombstone branch knows anyway
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    static func decode(_ data: Data) -> MaerPlaylistMerge.Entry? {
        // bearable, because an unreadable entry is none: the carrier drops it, like half a line in the blob
        KeyValuePlaylistCarrier.entry(from: try? JSONSerialization.jsonObject(with: data))
    }
}

/// CloudKit as the playlists' carrier: one record per list in the private
/// database, fetched by change token on the foreground and while playing,
/// written through an offline queue. The key-value blob stays beside it,
/// folded into records once, then only READ (a device on an older build
/// still writes it) and never written again. Without an account, or before
/// the first round, the key-value carrier does the whole job.
///
/// The MERGE is not here: `held()` presents what the cloud holds (with the
/// blob beside it, newest per list), the runner unites it with the local
/// state through `MaerPlaylistMerge`, and `store()` writes the diff. The
/// carrier only mirrors, encodes and queues.
@MainActor
final class CloudKitPlaylistCarrier: PlaylistCarrier {
    /// Under its own name since the records moved into rows: an older build
    /// reads `cloudPlaylistToken` beside a blob it no longer finds
    /// (`CarrierRows`).
    nonisolated static let tokenKey = "cloudPlaylistTokenRows"
    /// The owners of the mirror and the queue in `CarrierRecordRows`.
    nonisolated static let mirrorKey = "cloudPlaylistMirror"
    nonisolated static let queueKey = "cloudPlaylistQueue"
    nonisolated static let migratedKey = "cloudPlaylistMigrated"
    nonisolated static let subscribedKey = "cloudPlaylistSubscribed"

    private let database: any CloudPlaylistDatabase
    private let fallback: KeyValuePlaylistCarrier
    private let defaults: UserDefaults
    private let carrierRows: CarrierRecordRows
    private var onChange: (@MainActor () -> Void)?

    /// What the cloud holds as far as this device knows, by list id (a
    /// record is a list or a tombstone).
    private var mirror: [String: CloudPlaylistRecord]
    /// Records written here, not yet accepted by the cloud, by list id.
    private var queue: [String: CloudPlaylistRecord]
    private var token: Data?
    private var migrated: Bool
    private(set) var fellBack = false
    private var zoneReady = false
    private var refreshing = false
    private var subscribed: Bool

    init(database: any CloudPlaylistDatabase, fallback: KeyValuePlaylistCarrier,
         defaults: UserDefaults = AppStorageKeys.store, rows: CarrierRecordRows? = nil) {
        self.database = database
        self.fallback = fallback
        self.defaults = defaults
        let rows = rows ?? CarrierRecordRows.matching(defaults)
        carrierRows = rows
        mirror = Self.records(of: rows.rows(Self.mirrorKey))
        queue = Self.records(of: rows.rows(Self.queueKey))
        token = defaults.data(forKey: Self.tokenKey)
        migrated = defaults.bool(forKey: Self.migratedKey)
        subscribed = defaults.bool(forKey: Self.subscribedKey)
        rows.forgetUntilRead({
            token = nil
            defaults.removeObject(forKey: Self.tokenKey)
        }, then: { [weak self] in self?.takeTheReadRows() })
    }

    /// The rows read after a start that could not read them, under what
    /// this run learned since: this run wins per list.
    private func takeTheReadRows() {
        mirror = CarrierRecordRows.laterRead(Self.records(of: carrierRows.rows(Self.mirrorKey)), under: mirror)
        queue = CarrierRecordRows.laterRead(Self.records(of: carrierRows.rows(Self.queueKey)), under: queue)
    }

    var name: String { fellBack ? "kvs fallback" : (migrated ? "cloudkit" : "cloudkit migrating") }

    // MARK: - PlaylistCarrier

    /// The cloud's playlists, with the blob's beside them: the ONE rule
    /// unites the two sides, newest per list, tombstones kept. Before the
    /// account answers the blob carries alone.
    func held() -> MaerPlaylistMerge.Snapshot {
        if fellBack { return fallback.held() }
        let cloud = Self.snapshot(of: mirror)
        let outcome = MaerPlaylistMerge.merge(local: fallback.held(), cloud: cloud)
        return outcome.snapshot
    }

    func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
        guard !stopped else { return }
        if fellBack || !migrated {
            // Before the fold is done the blob is still the store for every
            // device; the cloud gets the same state through the queue.
            fallback.store(snapshot)
        }
        guard !stopped, !fellBack else { return }
        enqueue(Self.records(for: snapshot))
        Task { await self.flush(by: "store") }
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        fallback.start(onChange: onChange)
        CarrierRefreshers.register(self, zone: CloudPlaylistCodec.zoneName,
                                   gate: { AppStorageKeys.podcastICloudSyncEnabled }) { [weak self] caller in
            await self?.refresh(by: caller)
        }
        Task { await self.refresh(by: "start") }
    }

    /// No round, no send, no delivery from now on, the blob fallback
    /// included; a send that was queued before finds the carrier stopped.
    func stop() {
        stopped = true
        onChange = nil
        fallback.stop()
        CarrierRefreshers.unregister(self)
    }
    private var stopped = false

    func refresh(by caller: String = #function) async {
        let signpost = PerfSignpost.syncRound(.playlists, .cloudKit)
        defer { signpost.end() }
        guard !stopped, !fellBack, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard await database.accountAvailable() else {
            fellBack = true
            Logger.library.notice("PLAYLIST cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value store carries on")
            return
        }
        if !zoneReady {
            do {
                try await database.ensureZone()
                zoneReady = true
            } catch {
                note(error, by: caller)
                return
            }
        }
        if !subscribed {
            do {
                try await database.ensureSubscription()
                subscribed = true
                defaults.set(true, forKey: Self.subscribedKey)
                Logger.library.notice("PLAYLIST cloud push subscribed by=\(caller, privacy: .public)")
            } catch {
                Logger.library.notice("PLAYLIST cloud push subscribe failed reason=\(String(describing: error), privacy: .public); the poll carries on")
            }
        }
        if !migrated { await migrate(by: caller) }
        await flush(by: caller)
        await fetch(by: caller)
    }

    // MARK: - The rounds

    /// The blob's lists become records once. `offered` is what the blob
    /// held, `written` what the cloud took.
    private func migrate(by caller: String) async {
        let started = Date()
        let blob = fallback.held()
        for record in Self.records(for: blob).values where mirror[record.listId] == nil {
            queue[record.listId] = record
        }
        persist()
        let offered = blob.lists.count + blob.tombstones.count
        let written = await flush(by: caller)
        Logger.library.notice("PLAYLIST cloud migrate offered=\(offered) written=\(written) ms=\(Int(Date().timeIntervalSince(started) * 1000)) by=\(caller, privacy: .public)")
    }

    /// Sends the queue in batches; a record whose desired form matches the
    /// mirror is dropped without a write. What the cloud takes leaves the
    /// queue; what fails stays for the next round.
    @discardableResult
    private func flush(by caller: String) async -> Int {
        await sends.run { [weak self] in await self?.flushNow(by: caller) ?? 0 }
    }

    /// Flushes form a chain, one in flight at a time (`SendChain`).
    private let sends = SendChain()

    private func flushNow(by caller: String) async -> Int {
        guard !stopped, !fellBack, zoneReady else { return 0 }
        var written = 0
        while !queue.isEmpty {
            let batchIds = Array(queue.keys.prefix(CloudZoneLimits.batch))
            let records = batchIds.compactMap { queue[$0] }
            do {
                try await database.modify(save: records, delete: [])
            } catch {
                note(error, by: caller)
                persist()
                return written
            }
            // Only what was SENT leaves the queue and enters the mirror: a
            // store while `modify` was in flight holds a newer list.
            for record in records {
                mirror[record.listId] = record
                if queue[record.listId] == record { queue[record.listId] = nil }
            }
            written += records.count
            persist()
        }
        return written
    }

    /// The changes since the token, into the mirror; a deleted record
    /// leaves it. A tombstone is a record like any other, kept.
    private func fetch(by caller: String) async {
        let started = Date()
        var changed = 0
        var tombstones = 0
        var deleted = 0
        var more = true
        while more {
            let page: CloudZoneChanges<CloudPlaylistRecord>
            do {
                page = try await database.changes(since: token)
            } catch let failure as CloudStandFailure where failure == .tokenExpired {
                token = nil
                defaults.removeObject(forKey: Self.tokenKey)
                Logger.library.notice("PLAYLIST cloud token expired, fetching from the start by=\(caller, privacy: .public)")
                continue
            } catch {
                note(error, by: caller)
                return
            }
            for record in page.changed {
                mirror[record.listId] = record
                changed += 1
                if record.tombstone { tombstones += 1 }
            }
            // The record name is the list id, so a deletion maps straight back.
            for name in page.deletedRecordNames where mirror[name] != nil {
                mirror[name] = nil
                deleted += 1
            }
            token = page.token
            more = page.moreComing
        }
        if !migrated, queue.isEmpty {
            migrated = true
            defaults.set(true, forKey: Self.migratedKey)
        }
        persist()
        Logger.library.notice("PLAYLIST cloud fetch changed=\(changed) tombstones=\(tombstones) deleted=\(deleted) ms=\(Int(Date().timeIntervalSince(started) * 1000)) by=\(caller, privacy: .public)")
        if changed > 0 || deleted > 0 { onChange?() }
    }

    private func note(_ error: Error, by caller: String) {
        if let failure = error as? CloudStandFailure, failure == .noAccount {
            fellBack = true
            Logger.library.notice("PLAYLIST cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value store carries on")
            return
        }
        Logger.library.error("PLAYLIST cloud failed reason=\(String(describing: error), privacy: .public) by=\(caller, privacy: .public); queued=\(self.queue.count)")
    }

    /// Only the records that differ from the mirror go to the queue.
    private func enqueue(_ desired: [String: CloudPlaylistRecord]) {
        for (id, record) in desired where Self.needsWrite(record, over: mirror[id]) {
            queue[id] = record
        }
        persist()
    }

    /// Whether a desired record differs from the mirrored one. A list
    /// record is compared by its entry through the runner's own answer
    /// (`MaerPlaylistMerge.differs`): the device name every reconcile
    /// stamps is no difference, or one changed list would send every list.
    /// A tombstone, or a payload that does not read, is compared whole.
    nonisolated static func needsWrite(_ record: CloudPlaylistRecord, over mirrored: CloudPlaylistRecord?) -> Bool {
        guard let mirrored else { return true }
        guard !record.tombstone, !mirrored.tombstone,
              let desired = MaerPlaylistEntryWire.decode(record.payload),
              let held = MaerPlaylistEntryWire.decode(mirrored.payload) else { return record != mirrored }
        return MaerPlaylistMerge.differs(desired, held)
    }

    // MARK: - Pure

    /// The desired record set for a snapshot: a list becomes a list record,
    /// a tombstone becomes an empty record with the deletion moment. A list
    /// and its tombstone never both stand (the merge keeps a deleted list
    /// out of `lists`), so the ids do not collide.
    nonisolated static func records(for snapshot: MaerPlaylistMerge.Snapshot) -> [String: CloudPlaylistRecord] {
        var out: [String: CloudPlaylistRecord] = [:]
        for (id, entry) in snapshot.lists {
            out[id] = CloudPlaylistRecord(listId: id, payload: MaerPlaylistEntryWire.encode(entry),
                                          t: entry.updatedAt, tombstone: false)
        }
        for (id, moment) in snapshot.tombstones {
            out[id] = CloudPlaylistRecord(listId: id, payload: Data(), t: moment, tombstone: true)
        }
        return out
    }

    /// The snapshot a set of records makes: a record with a readable
    /// payload is a list, a tombstone is a deletion moment. An unreadable
    /// payload is dropped, like a half entry in the blob.
    nonisolated static func snapshot(of records: [String: CloudPlaylistRecord]) -> MaerPlaylistMerge.Snapshot {
        var snapshot = MaerPlaylistMerge.Snapshot()
        for (id, record) in records {
            if record.tombstone {
                snapshot.tombstones[id] = record.t
            } else if let entry = MaerPlaylistEntryWire.decode(record.payload) {
                snapshot.lists[id] = entry
            }
        }
        return snapshot
    }

    // MARK: - The door

    /// The mirror and the queue in the rows as `list id → [t,
    /// tombstone, payload as base64]`: three strings per record, no stored
    /// type of their own, so a field added to a list later is not a silent
    /// migration of a document only a mirror ever held.
    private func persist() {
        carrierRows.set(Self.mirrorKey, Self.rows(of: mirror))
        carrierRows.set(Self.queueKey, Self.rows(of: queue))
        if let token { defaults.set(token, forKey: Self.tokenKey) }
    }

    nonisolated static func rows(of records: [String: CloudPlaylistRecord]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (id, record) in records {
            out[id] = [String(record.t), record.tombstone ? "1" : "0", record.payload.base64EncodedString()]
        }
        return out
    }

    nonisolated static func records(of rows: [String: [String]]) -> [String: CloudPlaylistRecord] {
        var out: [String: CloudPlaylistRecord] = [:]
        for (id, row) in rows {
            guard row.count == 3, let t = Double(row[0]), let payload = Data(base64Encoded: row[2]) else { continue }
            out[id] = CloudPlaylistRecord(listId: id, payload: payload, t: t, tombstone: row[1] == "1")
        }
        return out
    }
}
