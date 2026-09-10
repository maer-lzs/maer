// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// CloudKit as the pot's carrier (decided D10 d, 06.09.): one record per
/// stand in the private database, fetched by change token on the
/// foreground and on the 10-s poll while playing, written through an
/// offline queue. The key-value blob stays beside it: it is folded into
/// records once, then only READ (a device on an older build still writes
/// it) and never written again. Without an iCloud account, or before the
/// first successful round, the key-value carrier does the whole job.
///
/// The carrier holds a mirror of what the cloud holds as far as this
/// device knows; `stands()` answers from it at once, so the runner's rule
/// stays synchronous and untouched.
@MainActor
final class CloudKitStandCarrier: StandCarrier {
    nonisolated static let tokenKey = "cloudStandToken"
    nonisolated static let mirrorKey = "cloudStandMirror"
    nonisolated static let queueKey = "cloudStandQueue"
    nonisolated static let queueRemovalsKey = "cloudStandQueueRemovals"
    nonisolated static let migratedKey = "cloudStandMigrated"
    nonisolated static let subscribedKey = "cloudStandSubscribed"

    private let database: any CloudStandDatabase
    private let fallback: KeyValueStandCarrier
    private let defaults: UserDefaults
    private var onChange: (@MainActor () -> Void)?

    /// What the cloud holds as far as this device knows, by item id.
    private var mirror: [String: [Double]]
    /// Written here, not yet accepted by the cloud.
    private var queue: [String: [Double]]
    private var queuedRemovals: Set<String>
    private var token: Data?
    /// The blob was folded in and read back once; from then on the cloud
    /// is the pot and the blob is read only.
    private var migrated: Bool
    /// The account said no this session: the key-value carrier runs.
    private(set) var fellBack = false
    private var zoneReady = false
    private var refreshing = false
    /// The zone's silent push was asked for once on this device.
    private var subscribed: Bool

    init(database: any CloudStandDatabase, fallback: KeyValueStandCarrier,
         defaults: UserDefaults = AppStorageKeys.store) {
        self.database = database
        self.fallback = fallback
        self.defaults = defaults
        mirror = StandMirrorStore.load(Self.mirrorKey, defaults: defaults)
        queue = StandMirrorStore.load(Self.queueKey, defaults: defaults)
        queuedRemovals = Set(StandMirrorStore.loadList(Self.queueRemovalsKey, defaults: defaults))
        token = defaults.data(forKey: Self.tokenKey)
        migrated = defaults.bool(forKey: Self.migratedKey)
        subscribed = defaults.bool(forKey: Self.subscribedKey)
    }

    var name: String { fellBack ? "kvs fallback" : (migrated ? "cloudkit" : "cloudkit migrating") }

    /// CloudKit has room; the blob does not. While the blob still carries
    /// (no account, or the fold is not done) the ceiling's rule applies.
    var hasRoomLimit: Bool { fellBack || !migrated }

    // MARK: - StandCarrier

    /// The cloud's stands, with the blob's beside them: per item the newer
    /// moment wins, so a device on an older build is still heard.
    func stands() -> [String: [Double]] {
        if fellBack { return fallback.stands() }
        return Self.union(cloud: mirror, legacy: fallback.stands())
    }

    func write(upserts: [String: [Double]], removing: Set<String>, by caller: String) {
        guard !upserts.isEmpty || !removing.isEmpty else { return }
        if fellBack || !migrated {
            // Before the first round the blob is still the pot for every
            // device; the cloud gets the same write through the queue.
            fallback.write(upserts: upserts, removing: removing, by: caller)
        }
        guard !fellBack else { return }
        for (id, entry) in upserts {
            mirror[id] = entry
            queue[id] = entry
            queuedRemovals.remove(id)
        }
        for id in removing {
            mirror[id] = nil
            queue[id] = nil
            queuedRemovals.insert(id)
        }
        persist()
        Task { await self.flush(by: caller) }
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        // The blob's own delivery still counts: an older device writes it.
        fallback.start(onChange: onChange)
        Task { await self.refresh(by: "start") }
    }

    /// One round: account, zone, the one-time fold of the blob, the queue,
    /// then the changes since the token. Runs on the foreground and on the
    /// poll; a round that finds nothing is a line in the log, not an event.
    func refresh(by caller: String = #function) async {
        guard !fellBack, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard await database.accountAvailable() else {
            fellBack = true
            Logger.library.notice("STAND cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value pot carries on")
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
        // The silent push is an ACCELERATOR, asked for once. A failure
        // here costs speed, never correctness: the poll while playing is
        // the promise, and it runs whatever the push does.
        if !subscribed {
            do {
                try await database.ensureSubscription()
                subscribed = true
                defaults.set(true, forKey: Self.subscribedKey)
                Logger.library.notice("STAND cloud push subscribed by=\(caller, privacy: .public)")
            } catch {
                Logger.library.notice("STAND cloud push subscribe failed reason=\(String(describing: error), privacy: .public); the poll carries on")
            }
        }
        if !migrated { await migrate(by: caller) }
        await flush(by: caller)
        await fetch(by: caller)
    }

    // MARK: - The rounds

    /// The blob's stands become records once. `offered` is what the blob
    /// held, `written` what the cloud took.
    private func migrate(by caller: String) async {
        let started = Date()
        let blob = fallback.stands()
        for (id, entry) in blob where mirror[id] == nil {
            queue[id] = entry
        }
        persist()
        let offered = blob.count
        let written = await flush(by: caller)
        Logger.library.notice("STAND cloud migrate offered=\(offered) written=\(written) ms=\(Int(Date().timeIntervalSince(started) * 1000)) by=\(caller, privacy: .public)")
    }

    /// Sends the queue in batches. What the cloud takes leaves the queue;
    /// what fails stays for the next round.
    @discardableResult
    private func flush(by caller: String) async -> Int {
        guard !fellBack, zoneReady else { return 0 }
        var written = 0
        while !queue.isEmpty || !queuedRemovals.isEmpty {
            let batchIds = Array(queue.keys.prefix(CloudStandLimits.batch))
            // A zero position is the pot's tombstone ("unplayed" with a
            // moment); the flag only names it, the entry travels as it is.
            let records = batchIds.map { id in
                CloudStandRecord(itemId: id, entry: queue[id] ?? [0, 0], tombstone: (queue[id]?.first ?? 0) == 0)
            }
            let room = CloudStandLimits.batch - records.count
            let removals = Array(queuedRemovals.prefix(max(0, room)))
            do {
                try await database.modify(save: records, delete: removals)
            } catch {
                note(error, by: caller)
                persist()
                return written
            }
            for id in batchIds { queue[id] = nil }
            for id in removals { queuedRemovals.remove(id) }
            written += records.count
            persist()
        }
        return written
    }

    /// The changes since the token, into the mirror. A tombstone is a
    /// stand with position zero and its moment, exactly the zero entry the
    /// pot already speaks; a deleted record leaves the mirror.
    private func fetch(by caller: String) async {
        let started = Date()
        var changed = 0
        var tombstones = 0
        var deleted = 0
        var more = true
        while more {
            let page: CloudStandChanges
            do {
                page = try await database.changes(since: token)
            } catch let failure as CloudStandFailure where failure == .tokenExpired {
                token = nil
                defaults.removeObject(forKey: Self.tokenKey)
                Logger.library.notice("STAND cloud token expired, fetching from the start by=\(caller, privacy: .public)")
                continue
            } catch {
                note(error, by: caller)
                return
            }
            for record in page.changed {
                mirror[record.itemId] = record.entry
                changed += 1
                if record.tombstone { tombstones += 1 }
            }
            if !page.deletedItemIds.isEmpty {
                let names = Dictionary(mirror.keys.map { (CloudStandNaming.recordName(for: $0), $0) },
                                       uniquingKeysWith: { a, _ in a })
                for name in page.deletedItemIds {
                    if let id = names[name] { mirror[id] = nil; deleted += 1 }
                }
            }
            token = page.token
            more = page.moreComing
        }
        // The fold is done only when the cloud has taken all of it: while
        // anything is still queued (a schema not yet in production, a
        // refusal), the blob stays the pot for every device and this one
        // keeps writing it.
        if !migrated, queue.isEmpty, queuedRemovals.isEmpty {
            migrated = true
            defaults.set(true, forKey: Self.migratedKey)
        }
        persist()
        Logger.library.notice("STAND cloud fetch changed=\(changed) tombstones=\(tombstones) deleted=\(deleted) ms=\(Int(Date().timeIntervalSince(started) * 1000)) by=\(caller, privacy: .public)")
        if changed > 0 || deleted > 0 { onChange?() }
    }

    private func note(_ error: Error, by caller: String) {
        if let failure = error as? CloudStandFailure, failure == .noAccount {
            fellBack = true
            Logger.library.notice("STAND cloud unavailable reason=noAccount by=\(caller, privacy: .public); the key-value pot carries on")
            return
        }
        Logger.library.error("STAND cloud failed reason=\(String(describing: error), privacy: .public) by=\(caller, privacy: .public); queued=\(self.queue.count) removals=\(self.queuedRemovals.count)")
    }

    // MARK: - Pure

    /// Per item the newer moment wins; the cloud wins a tie.
    nonisolated static func union(cloud: [String: [Double]], legacy: [String: [Double]]) -> [String: [Double]] {
        var out = cloud
        for (id, entry) in legacy {
            guard let mine = out[id] else { out[id] = entry; continue }
            if (ProgressMark.timestamp(entry) ?? -1) > (ProgressMark.timestamp(mine) ?? -1) { out[id] = entry }
        }
        return out
    }

    // MARK: - The door

    private func persist() {
        StandMirrorStore.save(mirror, key: Self.mirrorKey, defaults: defaults)
        StandMirrorStore.save(queue, key: Self.queueKey, defaults: defaults)
        StandMirrorStore.saveList(Array(queuedRemovals), key: Self.queueRemovalsKey, defaults: defaults)
        if let token { defaults.set(token, forKey: Self.tokenKey) }
    }
}
