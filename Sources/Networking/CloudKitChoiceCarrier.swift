// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CloudKit
import Foundation
import OSLog

/// One user choice as CloudKit carries it: the cloud key, the value as
/// bytes (the tagged dictionary of the service wire as JSON, so one typed
/// shape serves both ways), the event moment, and whether it is a
/// tombstone (a cleared key, kept as a record with an empty payload so the
/// clear travels and the newest wins). One record type, a tombstone is a
/// FLAG, not a second type.
nonisolated struct CloudChoiceRecord: Equatable, Sendable {
    var key: String
    var payload: Data
    var t: Double
    var tombstone: Bool
}

/// The choices zone: `choices`, one record type `Choice`, one record per
/// cloud key. The record name is a hash of the key, because a key carries
/// a station id or a feed key and record names are capped at 255
/// characters; the key itself rides in the `key` field, and a deletion is
/// mapped back through the names of what the mirror holds, like the pot.
nonisolated enum CloudChoiceCodec: CloudRecordCodec {
    typealias Value = CloudChoiceRecord
    static let zoneName = "choices"
    static let recordType = "Choice"
    static let subscriptionID = "choices-zone"

    static func recordName(for value: CloudChoiceRecord) -> String {
        CloudStandNaming.recordName(for: value.key)
    }

    static func fill(_ record: CKRecord, with value: CloudChoiceRecord) {
        record["key"] = value.key as CKRecordValue
        record["payload"] = value.payload as CKRecordValue
        record["t"] = value.t as CKRecordValue
        record["tombstone"] = (value.tombstone ? 1 : 0) as CKRecordValue
    }

    static func value(from record: CKRecord) -> CloudChoiceRecord? {
        guard let key = record["key"] as? String,
              let t = record["t"] as? Double else { return nil }
        let payload = (record["payload"] as? Data) ?? Data()
        let tombstone = (record["tombstone"] as? Int64 ?? 0) != 0
        return CloudChoiceRecord(key: key, payload: payload, t: t, tombstone: tombstone)
    }
}

/// The questions the choice carrier asks its zone.
typealias CloudChoiceDatabase = CloudZoneDatabase<CloudChoiceRecord>
/// The real thing for the choices: the zone database over the codec.
typealias CKChoiceDatabase = CKZoneDatabase<CloudChoiceCodec>

/// One choice value on the wire: the service wire's tagged dictionary as
/// JSON with sorted keys, so the same value gives the same bytes and the
/// type reads back exactly (int stays int, data stays data).
nonisolated enum CloudChoicePayload {
    static func encode(_ value: UserChoiceValue) -> Data {
        // tragbar, weil ein Woerterbuch aus einem Tag und einem plist-Wert immer kodiert; ein Fehlschlag waere ein leerer Rumpf, den der Grabstein-Zweig ohnehin kennt
        (try? JSONSerialization.data(withJSONObject: MaerSyncChoiceWire.tagged(value), options: [.sortedKeys])) ?? Data()
    }

    static func decode(_ data: Data) -> UserChoiceValue? {
        // tragbar, weil ein unlesbarer Wert keiner ist: der Traeger laesst den Eintrag fallen, wie eine halbe Zeile im Blob
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return MaerSyncChoiceWire.untagged(object)
    }
}

/// CloudKit as the choices' carrier: one record per cloud key in the
/// private database, fetched by change token, written through an offline
/// queue. The key-value blob stays beside it, folded into records once,
/// then only READ (a device on an older build still writes it) and never
/// written again. Without an account, or before the first round, the
/// key-value carrier does the whole job.
///
/// The MERGE is not here: `loadBlob()` presents what the cloud holds, with
/// the blob beside it and per key the newer event time winning (that IS
/// the choices' rule, and an older build's newer statement must win), the
/// runner decides against the local state through `UserChoiceMerge`, and
/// `storeBlob()` writes the difference. Unlike a playlist, a choice can
/// simply LEAVE the blob (the rate cap prunes the oldest), so a key the
/// runner dropped leaves the cloud too, or the mirror would bring it back.
@MainActor
final class CloudKitChoiceCarrier: ChoiceCarrier {
    nonisolated static let tokenKey = "cloudChoiceToken"
    nonisolated static let mirrorKey = "cloudChoiceMirror"
    nonisolated static let queueKey = "cloudChoiceQueue"
    nonisolated static let removalsKey = "cloudChoiceRemovals"
    nonisolated static let migratedKey = "cloudChoiceMigrated"
    nonisolated static let subscribedKey = "cloudChoiceSubscribed"
    nonisolated static let foldedKey = "cloudChoiceFolded"

    private let database: any CloudChoiceDatabase
    private let fallback: KeyValueChoiceCarrier
    private let defaults: UserDefaults
    private var onChange: (@MainActor () -> Void)?

    /// What the cloud holds as far as this device knows, by cloud key.
    private var mirror: [String: CloudChoiceRecord]
    /// Records written here, not yet accepted by the cloud, by cloud key.
    private var queue: [String: CloudChoiceRecord]
    /// Keys whose records are to leave the cloud: the runner dropped them
    /// from the blob, and the mirror must not bring them back.
    private var removals: Set<String>
    /// What the blob said per key when it was folded: the event time each
    /// key carried then. After the fold the blob is frozen on this device
    /// (never written again), so of it only what changed SINCE counts,
    /// which is what a device on an older build wrote after the fold; a
    /// key the runner dropped keeps its old time there and stays gone.
    /// Per key, not a wall-clock moment, because the other device's clock
    /// is not this one's.
    private var folded: [String: Double]
    private var token: Data?
    private var migrated: Bool
    private(set) var fellBack = false
    private var zoneReady = false
    private var refreshing = false
    private var subscribed: Bool

    init(database: any CloudChoiceDatabase, fallback: KeyValueChoiceCarrier,
         defaults: UserDefaults = AppStorageKeys.store) {
        self.database = database
        self.fallback = fallback
        self.defaults = defaults
        mirror = Self.records(of: Self.load(Self.mirrorKey, defaults: defaults))
        queue = Self.records(of: Self.load(Self.queueKey, defaults: defaults))
        removals = Set(defaults.stringArray(forKey: Self.removalsKey) ?? [])
        folded = (defaults.dictionary(forKey: Self.foldedKey) as? [String: Double]) ?? [:]
        token = defaults.data(forKey: Self.tokenKey)
        migrated = defaults.bool(forKey: Self.migratedKey)
        subscribed = defaults.bool(forKey: Self.subscribedKey)
    }

    var name: String { fellBack ? "kvs fallback" : (migrated ? "cloudkit" : "cloudkit migrating") }

    // MARK: - ChoiceCarrier

    /// The cloud's choices with the blob's beside them, per key the newer
    /// event time. Before the account answers the blob carries alone;
    /// until the fold is done it carries whole (a refused queue must not
    /// lose it); after the fold only what changed in it since.
    func loadBlob() -> [String: Any] {
        if fellBack { return fallback.loadBlob() }
        return Self.united(cloud: Self.blob(of: mirror), blob: fallback.loadBlob(),
                           folded: migrated ? folded : [:])
    }

    func storeBlob(_ blob: [String: Any]) {
        if fellBack || !migrated {
            // Before the fold is done the blob is still the store for every
            // device; the cloud gets the same state through the queue.
            fallback.storeBlob(blob)
        }
        guard !fellBack else { return }
        enqueue(Self.records(for: blob))
        Task { await self.send(by: "store") }
    }

    /// The old premium-classification lists live in the key-value store
    /// only; the fallback keeps reading them for a device on an older build.
    func legacyList(forKey key: String) -> [String]? {
        fallback.legacyList(forKey: key)
    }

    /// The queue is on its way from `storeBlob`; what may still wait is the
    /// key-value store's own coalescing.
    func flush() {
        fallback.flush()
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        fallback.start(onChange: onChange)
        CloudKitRefreshers.register(self, zone: CloudChoiceCodec.zoneName) { [weak self] caller in
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
            Logger.library.notice("CHOICE cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value store carries on")
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
                Logger.library.notice("CHOICE cloud push subscribed by=\(caller, privacy: .public)")
            } catch {
                Logger.library.notice("CHOICE cloud push subscribe failed reason=\(String(describing: error), privacy: .public); the poll carries on")
            }
        }
        if !migrated { await migrate(by: caller) }
        await send(by: caller)
        await fetch(by: caller)
    }

    // MARK: - The rounds

    /// The blob's entries become records once. `offered` is what the blob
    /// held, `written` what the cloud took.
    private func migrate(by caller: String) async {
        let started = Date()
        let blob = fallback.loadBlob()
        let records = Self.records(for: blob)
        for (key, record) in records where mirror[key] == nil {
            queue[key] = record
        }
        // What the blob says now is what "unchanged since the fold" means.
        folded = Self.stamps(of: blob)
        persist()
        let written = await send(by: caller)
        Logger.library.notice("CHOICE cloud migrate offered=\(records.count) written=\(written) ms=\(Int(Date().timeIntervalSince(started) * 1000)) by=\(caller, privacy: .public)")
    }

    /// Sends the queue and the removals in batches. What the cloud takes
    /// leaves the queue; what fails stays for the next round.
    @discardableResult
    private func send(by caller: String) async -> Int {
        guard !fellBack, zoneReady else { return 0 }
        var written = 0
        while !queue.isEmpty || !removals.isEmpty {
            let batchKeys = Array(queue.keys.prefix(CloudZoneLimits.batch))
            let records = batchKeys.compactMap { queue[$0] }
            let removeKeys = Array(removals.prefix(max(0, CloudZoneLimits.batch - records.count)))
            do {
                try await database.modify(save: records,
                                          delete: removeKeys.map { CloudStandNaming.recordName(for: $0) })
            } catch {
                note(error, by: caller)
                persist()
                return written
            }
            for key in batchKeys {
                if let record = queue[key] { mirror[key] = record }
                queue[key] = nil
            }
            for key in removeKeys {
                mirror[key] = nil
                removals.remove(key)
            }
            written += records.count + removeKeys.count
            persist()
        }
        return written
    }

    /// The changes since the token, into the mirror; a deleted record
    /// leaves it. A tombstone is a record like any other, kept. A record
    /// that arrives for a key on its way out was written newer by another
    /// device: the removal is dropped and the next store decides again.
    private func fetch(by caller: String) async {
        let started = Date()
        var changed = 0
        var tombstones = 0
        var deleted = 0
        var more = true
        while more {
            let page: CloudZoneChanges<CloudChoiceRecord>
            do {
                page = try await database.changes(since: token)
            } catch let failure as CloudStandFailure where failure == .tokenExpired {
                token = nil
                defaults.removeObject(forKey: Self.tokenKey)
                Logger.library.notice("CHOICE cloud token expired, fetching from the start by=\(caller, privacy: .public)")
                continue
            } catch {
                note(error, by: caller)
                return
            }
            for record in page.changed {
                mirror[record.key] = record
                removals.remove(record.key)
                changed += 1
                if record.tombstone { tombstones += 1 }
            }
            if !page.deletedRecordNames.isEmpty {
                let names = Dictionary(mirror.keys.map { (CloudStandNaming.recordName(for: $0), $0) },
                                       uniquingKeysWith: { a, _ in a })
                for name in page.deletedRecordNames {
                    guard let key = names[name] else { continue }
                    mirror[key] = nil
                    deleted += 1
                }
            }
            token = page.token
            more = page.moreComing
        }
        if !migrated, queue.isEmpty, removals.isEmpty {
            migrated = true
            defaults.set(true, forKey: Self.migratedKey)
        }
        persist()
        Logger.library.notice("CHOICE cloud fetch changed=\(changed) tombstones=\(tombstones) deleted=\(deleted) ms=\(Int(Date().timeIntervalSince(started) * 1000)) by=\(caller, privacy: .public)")
        if changed > 0 || deleted > 0 { onChange?() }
    }

    private func note(_ error: Error, by caller: String) {
        if let failure = error as? CloudStandFailure, failure == .noAccount {
            fellBack = true
            Logger.library.notice("CHOICE cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value store carries on")
            return
        }
        Logger.library.error("CHOICE cloud failed reason=\(String(describing: error), privacy: .public) by=\(caller, privacy: .public); queued=\(self.queue.count) removals=\(self.removals.count)")
    }

    /// Only the records that differ from the mirror go to the queue; a key
    /// the mirror holds and the runner dropped goes to the removals.
    private func enqueue(_ desired: [String: CloudChoiceRecord]) {
        for (key, record) in desired where mirror[key] != record {
            queue[key] = record
            removals.remove(key)
        }
        for key in mirror.keys where desired[key] == nil {
            removals.insert(key)
            queue[key] = nil
        }
        persist()
    }

    // MARK: - Pure

    /// The desired record set for a blob: a value becomes a value record, a
    /// cleared key a tombstone with the clear's moment. An entry the blob
    /// cannot read is not a record.
    nonisolated static func records(for blob: [String: Any]) -> [String: CloudChoiceRecord] {
        var out: [String: CloudChoiceRecord] = [:]
        for (key, raw) in blob {
            guard let entry = UserChoiceEntry.from(plist: raw) else { continue }
            if let value = entry.value {
                out[key] = CloudChoiceRecord(key: key, payload: CloudChoicePayload.encode(value),
                                             t: entry.t, tombstone: false)
            } else {
                out[key] = CloudChoiceRecord(key: key, payload: Data(), t: entry.t, tombstone: true)
            }
        }
        return out
    }

    /// The blob a set of records makes: a readable payload is a value, a
    /// tombstone a cleared key with its moment. An unreadable payload is
    /// dropped, like a half entry in the blob.
    nonisolated static func blob(of records: [String: CloudChoiceRecord]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, record) in records {
            if record.tombstone {
                out[key] = UserChoiceEntry(value: nil, t: record.t).plist
            } else if let value = CloudChoicePayload.decode(record.payload) {
                out[key] = UserChoiceEntry(value: value, t: record.t).plist
            }
        }
        return out
    }

    /// The cloud's blob with the key-value blob beside it: per key the newer
    /// event time wins, a tie goes to the cloud. The blob is what a device
    /// on an older build still writes, so its newer statement must count.
    /// `folded` is what the blob said when it was folded: an entry that
    /// still carries that time is the frozen leftover of the fold (a key
    /// the runner dropped since stays dropped), only an entry newer than
    /// its folded time, or a key the fold never saw, is taken. Empty
    /// `folded` takes the whole blob, which is right until the fold is done.
    nonisolated static func united(cloud: [String: Any], blob: [String: Any],
                                   folded: [String: Double] = [:]) -> [String: Any] {
        var out = cloud
        for (key, raw) in blob {
            guard let entry = UserChoiceEntry.from(plist: raw) else { continue }
            if let atFold = folded[key], entry.t <= atFold { continue }
            if let held = UserChoiceEntry.from(plist: out[key]), held.t >= entry.t { continue }
            out[key] = entry.plist
        }
        return out
    }

    /// The event time per key of a blob, as the fold records it.
    nonisolated static func stamps(of blob: [String: Any]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (key, raw) in blob {
            if let entry = UserChoiceEntry.from(plist: raw) { out[key] = entry.t }
        }
        return out
    }

    // MARK: - The door

    /// The mirror and the queue in the key door as `key → [t, tombstone,
    /// payload as base64]`: three strings per record, no stored type of
    /// their own, so a field added later is not a silent migration of a
    /// document only a mirror ever held.
    private func persist() {
        Self.save(Self.rows(of: mirror), key: Self.mirrorKey, defaults: defaults)
        Self.save(Self.rows(of: queue), key: Self.queueKey, defaults: defaults)
        defaults.set(Array(removals).sorted(), forKey: Self.removalsKey)
        defaults.set(folded, forKey: Self.foldedKey)
        if let token { defaults.set(token, forKey: Self.tokenKey) }
    }

    nonisolated static func rows(of records: [String: CloudChoiceRecord]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (key, record) in records {
            out[key] = [String(record.t), record.tombstone ? "1" : "0", record.payload.base64EncodedString()]
        }
        return out
    }

    nonisolated static func records(of rows: [String: [String]]) -> [String: CloudChoiceRecord] {
        var out: [String: CloudChoiceRecord] = [:]
        for (key, row) in rows {
            guard row.count == 3, let t = Double(row[0]), let payload = Data(base64Encoded: row[2]) else { continue }
            out[key] = CloudChoiceRecord(key: key, payload: payload, t: t, tombstone: row[1] == "1")
        }
        return out
    }

    nonisolated private static func load(_ key: String, defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        // tragbar, weil ein unlesbarer Spiegel nur einen vollen Abzug kostet; die Wahrheit liegt in der Wolke und im Geraet
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    nonisolated private static func save(_ value: [String: [String]], key: String, defaults: UserDefaults) {
        // tragbar, weil ein Woerterbuch aus Text immer kodiert
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
