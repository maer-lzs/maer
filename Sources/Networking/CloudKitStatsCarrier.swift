// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CloudKit
import Foundation
import OSLog

/// One device's statistics pot as CloudKit carries it: the device, the
/// pot as bytes (its own JSON, the same wire the service takes) and the
/// moment it was published.
nonisolated struct CloudStatsRecord: Equatable, Sendable {
    var deviceId: String
    var payload: Data
    var t: Double
}

/// The statistics zone: `stats`, one record type `Stats`, one record per
/// device, record name = the device id. The mechanics live in
/// `CKZoneDatabase`; this is the second codec on it.
nonisolated enum CloudStatsCodec: CloudRecordCodec {
    typealias Value = CloudStatsRecord
    static let zoneName = "stats"
    static let recordType = "Stats"
    static let subscriptionID = "stats-zone"

    static func recordName(for value: CloudStatsRecord) -> String { value.deviceId }

    static func fill(_ record: CKRecord, with value: CloudStatsRecord) {
        record["device"] = value.deviceId as CKRecordValue
        record["payload"] = value.payload as CKRecordValue
        record["t"] = value.t as CKRecordValue
    }

    static func value(from record: CKRecord) -> CloudStatsRecord? {
        guard let deviceId = record["device"] as? String,
              let payload = record["payload"] as? Data,
              let t = record["t"] as? Double else { return nil }
        return CloudStatsRecord(deviceId: deviceId, payload: payload, t: t)
    }
}

typealias CKStatsDatabase = CKZoneDatabase<CloudStatsCodec>

/// CloudKit as the statistics' carrier: one record per device in the
/// private database, fetched by change token on the foreground and on the
/// tick while playing, the own record written through a queue of one.
/// The key-value store stays beside it as fallback and legacy reader: a
/// device on an older build still publishes its pot there, and this
/// device keeps publishing there until the cloud has taken its record
/// once. Per device the cloud's record wins where there is one.
///
/// The carrier holds a mirror of what the cloud holds as far as this
/// device knows; `pots()` answers from it at once, so the store's
/// synchronous rule stays untouched.
@MainActor
final class CloudKitStatsCarrier: StatsCarrier {
    nonisolated static let tokenKey = "cloudStatsToken"
    nonisolated static let mirrorKey = "cloudStatsMirror"
    nonisolated static let queueKey = "cloudStatsQueue"
    nonisolated static let migratedKey = "cloudStatsMigrated"
    nonisolated static let subscribedKey = "cloudStatsSubscribed"

    private let database: any CloudStatsDatabase
    private let fallback: KeyValueStatsCarrier
    private let defaults: UserDefaults
    private var onChange: (@MainActor () -> Void)?

    /// What the cloud holds as far as this device knows, by device.
    private var mirror: [String: CloudStatsRecord]
    /// The own pot written here, not yet accepted by the cloud.
    private var queued: CloudStatsRecord?
    private var token: Data?
    /// The cloud took the own record once; from then on the cloud is the
    /// carrier and the key-value pot is read only.
    private var migrated: Bool
    /// The account said no this session: the key-value carrier runs.
    private(set) var fellBack = false
    private var zoneReady = false
    private var refreshing = false
    private var subscribed: Bool

    init(database: any CloudStatsDatabase, fallback: KeyValueStatsCarrier,
         defaults: UserDefaults = AppStorageKeys.store) {
        self.database = database
        self.fallback = fallback
        self.defaults = defaults
        mirror = Self.loadMirror(defaults: defaults)
        queued = Self.loadQueued(defaults: defaults)
        token = defaults.data(forKey: Self.tokenKey)
        migrated = defaults.bool(forKey: Self.migratedKey)
        subscribed = defaults.bool(forKey: Self.subscribedKey)
    }

    var name: String { fellBack ? "kvs fallback" : (migrated ? "cloudkit" : "cloudkit migrating") }

    /// CloudKit has room; the key-value pot does not. While the pot still
    /// carries (no account, or the own record not yet taken) the ceiling's
    /// rule applies, so what is published there stays capped.
    var hasRoomLimit: Bool { fellBack || !migrated }

    // MARK: - StatsCarrier

    /// Per device the cloud's record, the key-value pot for the devices
    /// the cloud has none for (a device on an older build).
    func pots() -> [String: ListeningStatsData] {
        if fellBack { return fallback.pots() }
        var out = fallback.pots()
        for (deviceId, record) in mirror {
            if let pot = MaerSyncStatsWire.decode(record.payload) { out[deviceId] = pot }
        }
        if let queued, let pot = MaerSyncStatsWire.decode(queued.payload) { out[queued.deviceId] = pot }
        return out
    }

    func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {
        guard !stopped else { return }
        if fellBack || !migrated {
            // Before the first round the pot is still the carrier for
            // every device; the cloud gets the same write through the queue.
            fallback.publish(pot, deviceId: deviceId, by: caller)
        }
        guard !stopped, !fellBack else { return }
        do {
            let record = CloudStatsRecord(deviceId: deviceId, payload: try MaerSyncStatsWire.encode(pot),
                                          t: Date().timeIntervalSince1970 * 1000)
            queued = record
            mirror[deviceId] = record
            persist()
        } catch {
            Logger.library.error("STATS cloud pot not encodable by=\(caller, privacy: .public)")
            return
        }
        Task { await self.flush(by: caller) }
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        // The pot's own delivery still counts: an older device writes it.
        fallback.start(onChange: onChange)
        CarrierRefreshers.register(self, zone: CloudStatsCodec.zoneName,
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

    /// One round: account, zone, the silent push once, the queue, then the
    /// changes since the token. A round that finds nothing is a line in
    /// the log, not an event.
    func refresh(by caller: String) async {
        let signpost = PerfSignpost.syncRound(.stats, .cloudKit)
        defer { signpost.end() }
        guard !stopped, !fellBack, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard await database.accountAvailable() else {
            fellBack = true
            Logger.library.notice("STATS cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value pot carries on")
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
            } catch {
                Logger.library.notice("STATS cloud push subscribe failed reason=\(String(describing: error), privacy: .public); the poll carries on")
            }
        }
        await flush(by: caller)
        await fetch(by: caller)
    }

    // MARK: - The rounds

    /// Flushes form a chain, one in flight at a time (`SendChain`): an older
    /// pot that lands last would stand in the cloud.
    private let sends = SendChain()

    /// Sends the queued own record. What the cloud takes leaves the queue
    /// and marks the fold done; what fails stays for the next round.
    private func flush(by caller: String) async {
        await sends.run { [weak self] in
            await self?.flushNow(by: caller)
            return 0
        }
    }

    private func flushNow(by caller: String) async {
        guard !stopped, !fellBack, zoneReady, let record = queued else { return }
        do {
            try await database.modify(save: [record], delete: [])
        } catch {
            note(error, by: caller)
            return
        }
        if queued == record { queued = nil }
        if !migrated {
            migrated = true
            defaults.set(true, forKey: Self.migratedKey)
            Logger.library.notice("STATS cloud migrate: the own pot is a record, the key-value pot is read only from here by=\(caller, privacy: .public)")
        }
        persist()
        Logger.library.notice("STATS cloud written bytes=\(record.payload.count) by=\(caller, privacy: .public)")
    }

    /// The changes since the token, into the mirror; a deleted record
    /// leaves it.
    private func fetch(by caller: String) async {
        let started = Date()
        var changed = 0
        var deleted = 0
        var more = true
        while more {
            let page: CloudZoneChanges<CloudStatsRecord>
            do {
                page = try await database.changes(since: token)
            } catch let failure as CloudStandFailure where failure == .tokenExpired {
                token = nil
                defaults.removeObject(forKey: Self.tokenKey)
                Logger.library.notice("STATS cloud token expired, fetching from the start by=\(caller, privacy: .public)")
                continue
            } catch {
                note(error, by: caller)
                return
            }
            for record in page.changed {
                // The own record comes back too; the queued one, when
                // there is one, is newer than anything the cloud sends.
                if let queued, queued.deviceId == record.deviceId { continue }
                mirror[record.deviceId] = record
                changed += 1
            }
            for name in page.deletedRecordNames where mirror[name] != nil {
                mirror[name] = nil
                deleted += 1
            }
            token = page.token
            more = page.moreComing
        }
        persist()
        Logger.library.notice("STATS cloud fetch changed=\(changed) deleted=\(deleted) ms=\(Int(Date().timeIntervalSince(started) * 1000)) by=\(caller, privacy: .public)")
        if changed > 0 || deleted > 0 { onChange?() }
    }

    private func note(_ error: Error, by caller: String) {
        if let failure = error as? CloudStandFailure, failure == .noAccount {
            fellBack = true
            Logger.library.notice("STATS cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value pot carries on")
            return
        }
        Logger.library.error("STATS cloud failed reason=\(String(describing: error), privacy: .public) by=\(caller, privacy: .public); queued=\(self.queued == nil ? 0 : 1)")
    }

    // MARK: - The door

    /// The mirror and the queue in the key door as `device → [moment,
    /// payload as base64]`: two strings per device, no stored type of
    /// their own, so a field added later is not a silent migration of a
    /// document that only a mirror ever held.
    private func persist() {
        StandMirrorStore.saveRows(Self.rows(of: Array(mirror.values)), key: Self.mirrorKey, defaults: defaults)
        StandMirrorStore.saveRows(Self.rows(of: queued.map { [$0] } ?? []), key: Self.queueKey, defaults: defaults)
        if let token { defaults.set(token, forKey: Self.tokenKey) }
    }

    nonisolated static func rows(of records: [CloudStatsRecord]) -> [String: [String]] {
        Dictionary(records.map { ($0.deviceId, [String($0.t), $0.payload.base64EncodedString()]) },
                   uniquingKeysWith: { a, _ in a })
    }

    nonisolated static func records(of rows: [String: [String]]) -> [String: CloudStatsRecord] {
        var out: [String: CloudStatsRecord] = [:]
        for (deviceId, row) in rows {
            guard row.count == 2, let t = Double(row[0]), let payload = Data(base64Encoded: row[1]) else { continue }
            out[deviceId] = CloudStatsRecord(deviceId: deviceId, payload: payload, t: t)
        }
        return out
    }

    nonisolated private static func loadMirror(defaults: UserDefaults) -> [String: CloudStatsRecord] {
        records(of: StandMirrorStore.loadRows(Self.mirrorKey, defaults: defaults))
    }

    nonisolated private static func loadQueued(defaults: UserDefaults) -> CloudStatsRecord? {
        records(of: StandMirrorStore.loadRows(Self.queueKey, defaults: defaults)).values.first
    }
}

/// The questions the stats carrier asks its zone.
typealias CloudStatsDatabase = CloudZoneDatabase<CloudStatsRecord>
