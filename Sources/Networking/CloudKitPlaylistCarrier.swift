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
        var dict: [String: Any] = ["name": entry.name, "updatedAt": entry.updatedAt,
                                   "items": entry.itemIds, "titles": entry.titles,
                                   "snapshots": KeyValuePlaylistCarrier.blob(snapshots: entry.snapshots)]
        if let nameUpdatedAt = entry.nameUpdatedAt { dict["nameUpdatedAt"] = nameUpdatedAt }
        if let device = entry.device { dict["device"] = device }
        if !entry.removed.isEmpty { dict["removed"] = entry.removed }
        if !entry.added.isEmpty { dict["added"] = entry.added }
        // bearable, because a dictionary of plist values always encodes; a failure would be an empty body, which the tombstone branch knows anyway
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    static func decode(_ data: Data) -> MaerPlaylistMerge.Entry? {
        // bearable, because an unreadable entry is none: the carrier drops it, like half a line in the blob
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = dict["name"] as? String,
              let updatedAt = (dict["updatedAt"] as? NSNumber)?.doubleValue,
              let items = dict["items"] as? [String] else { return nil }
        return .init(name: name, updatedAt: updatedAt, itemIds: items,
                     titles: (dict["titles"] as? [String: String]) ?? [:],
                     nameUpdatedAt: (dict["nameUpdatedAt"] as? NSNumber)?.doubleValue,
                     snapshots: KeyValuePlaylistCarrier.snapshots(fromBlob: dict["snapshots"]),
                     removed: KeyValuePlaylistCarrier.moments(fromBlob: dict["removed"]),
                     added: KeyValuePlaylistCarrier.moments(fromBlob: dict["added"]),
                     device: dict["device"] as? String)
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
    nonisolated static let tokenKey = "cloudPlaylistToken"
    nonisolated static let mirrorKey = "cloudPlaylistMirror"
    nonisolated static let queueKey = "cloudPlaylistQueue"
    nonisolated static let migratedKey = "cloudPlaylistMigrated"
    nonisolated static let subscribedKey = "cloudPlaylistSubscribed"

    private let database: any CloudPlaylistDatabase
    private let fallback: KeyValuePlaylistCarrier
    private let defaults: UserDefaults
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
         defaults: UserDefaults = AppStorageKeys.store) {
        self.database = database
        self.fallback = fallback
        self.defaults = defaults
        mirror = Self.records(of: Self.load(Self.mirrorKey, defaults: defaults))
        queue = Self.records(of: Self.load(Self.queueKey, defaults: defaults))
        token = defaults.data(forKey: Self.tokenKey)
        migrated = defaults.bool(forKey: Self.migratedKey)
        subscribed = defaults.bool(forKey: Self.subscribedKey)
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
        return MaerPlaylistMerge.Snapshot(lists: outcome.lists, tombstones: outcome.tombstones)
    }

    func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
        if fellBack || !migrated {
            // Before the fold is done the blob is still the store for every
            // device; the cloud gets the same state through the queue.
            fallback.store(snapshot)
        }
        guard !fellBack else { return }
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

    func refresh(by caller: String = #function) async {
        guard !fellBack, !refreshing else { return }
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
        guard !fellBack, zoneReady else { return 0 }
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
            for id in batchIds {
                if let record = queue[id] { mirror[id] = record }
                queue[id] = nil
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
        for (id, record) in desired where mirror[id] != record {
            queue[id] = record
        }
        persist()
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

    /// The mirror and the queue in the key door as `list id → [t,
    /// tombstone, payload as base64]`: three strings per record, no stored
    /// type of their own, so a field added to a list later is not a silent
    /// migration of a document only a mirror ever held.
    private func persist() {
        Self.save(Self.rows(of: mirror), key: Self.mirrorKey, defaults: defaults)
        Self.save(Self.rows(of: queue), key: Self.queueKey, defaults: defaults)
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

    nonisolated private static func load(_ key: String, defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        // bearable, because an unreadable mirror only costs a full pull; the truth lies in the cloud and on the device
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    nonisolated private static func save(_ value: [String: [String]], key: String, defaults: UserDefaults) {
        // bearable, because a dictionary of text always encodes
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
