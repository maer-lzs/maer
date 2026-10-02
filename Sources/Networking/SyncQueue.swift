// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Persistence abstraction of the queue. Replaceable with in-memory in tests.
protocol SyncQueueStorage {
    func load() -> [String: SyncQueue.PendingUpdate]
    func save(_ pending: [String: SyncQueue.PendingUpdate])
    /// Returns once every handed-over save has landed on disk.
    func awaitPendingWrites() async
}

/// Narrow API view the flush needs. APIClient satisfies it; tests can inject a
/// mock.
@MainActor
protocol ProgressSyncAPI {
    func fetchAllProgress() async throws -> [String: BookProgress]
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws
}

/// Which server answers for ONE queued title, and under which name.
///
/// The queue used to take a single client for everything in it. That was
/// true while only the main library could queue anything; the shelf mixes
/// secondary audiobook sources now, so a `jf:` or `sub:` id lands in the
/// same queue and was then offered to the main server.
///
/// The `key` exists so the stale check asks the SAME server as the write:
/// the server state is fetched once per key, not once per queue.
struct ProgressTarget {
    let key: String
    let client: any ProgressSyncAPI
}

extension APIClient: ProgressSyncAPI {}

/// Row storage. Default outside tests. The queue is a set of items, so it
/// is one row per item in `pending_sync` (`KeyedRowStore`). The dictionary
/// in memory answers every question at once; the rows follow in the
/// keeper's serial chain as the diff against the last landed write, and
/// `awaitPendingWrites` is how the queue makes a write LAND before it
/// answers its caller (see `SyncQueue.enqueue`). The document of the
/// builds before is read once when the rows hold nothing, poured into them
/// and set aside; an unreadable one stays `.corrupt` at the seam and is
/// never poured, the rows start fresh. What waits here are listening
/// positions that never reached the server, the one thing this app must
/// not lose quietly: a failed start read leaves the rows unknown, so the
/// first write only upserts and removes nothing it never saw.
final class SyncQueueRowStorage: SyncQueueStorage {
    private let keeper: RowKeeper<SyncQueue.PendingUpdate>
    /// The seam to disk for the document of the builds before.
    private let ablage: Ablage
    private let documentName = "pending_sync.json"
    private var pending: [String: SyncQueue.PendingUpdate] = [:]

    init(database: MaerDatabase, ablage: Ablage) {
        self.keeper = RowKeeper(database: database, table: .pendingSync, label: "SYNCQUEUE")
        self.ablage = ablage
        let start = keeper.startNow()
        var loaded = start.rows
        var document: URL?
        if loaded == nil {
            // Corrupt is kept aside by the seam and never buried; the rows
            // then start fresh.
            if let current = ablage.loadNow([String: SyncQueue.PendingUpdate].self, name: documentName).value {
                loaded = current
                document = ablage.url(for: documentName)
            }
            if start.failed {
                loaded = loaded ?? ablage.loadNow([String: SyncQueue.PendingUpdate].self, name: documentName + ".migrated").value
                document = nil
            }
        }
        pending = loaded ?? [:]
        Logger.library.notice("SYNCQUEUE start: entries=\(self.pending.count) migrate=\(document != nil)")
        if let document, let loaded { keeper.pour(loaded, settingAside: [document]) }
    }

    func load() -> [String: SyncQueue.PendingUpdate] {
        pending
    }

    /// The memory is the truth at once; the rows get the diff in the chain,
    /// and a failed write keeps the entries queued in memory.
    func save(_ pending: [String: SyncQueue.PendingUpdate]) {
        self.pending = pending
        keeper.write(pending)
    }

    /// Waits for every queued write of the rows (tests, teardown).
    func awaitPendingWrites() async {
        await keeper.awaitPendingWrites()
    }
}

/// Persists unsent progress updates so they survive an app kill during an
/// offline phase. Without it a progress update would be lost if the app is
/// closed offline before the next automatic sync attempt (every 30 s).
///
/// Only the LATEST state per book is stored on purpose (a dictionary, no
/// history). Only the newest progress matters, older intermediate states would
/// be outdated anyway.
///
/// Kill-safety is the contract: `enqueue` and `remove` return only when the
/// row has landed (one atomic transaction), so an app killed after the call
/// keeps the entry. The window that remains is a kill DURING the call, the
/// same window the atomic document write had before the rows.
@MainActor
final class SyncQueue {
    static let shared = SyncQueue()

    nonisolated struct PendingUpdate: Codable, Equatable, Sendable {
        let currentTime: Double
        let duration: Double
        let isFinished: Bool
        /// ms epoch when queued. For "recently listened" in the library.
        /// Optional: entries from older app versions lack this field.
        var queuedAt: Double? = nil
    }

    private let storage: SyncQueueStorage

    /// Tolerance (seconds) at which a server state counts as "further ahead".
    /// The same threshold as the device reconcile in PlayerViewModel.
    private let reconcileThreshold: Double = 5

    /// For tests: inject a custom storage.
    init(storage: SyncQueueStorage) {
        self.storage = storage
    }

    /// No default argument: it would be evaluated in the (nonisolated) caller
    /// context and clash with the MainActor isolation.
    private init() {
        self.storage = SyncQueueRowStorage(database: MaerDatabase.shared, ablage: Ablage.documents)
    }

    /// Returns when the entry has landed on disk.
    func enqueue(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async {
        var pending = loadAll()
        pending[itemId] = PendingUpdate(
            currentTime: currentTime,
            duration: duration,
            isFinished: isFinished,
            queuedAt: Date().timeIntervalSince1970 * 1000
        )
        save(pending)
        await storage.awaitPendingWrites()
    }

    /// All pending updates. For the library, so it can show the locally newest
    /// (not-yet-sent) state.
    func allPending() -> [String: PendingUpdate] {
        loadAll()
    }

    /// Every waiting update under the id in the form the server answers to
    /// (`NavidromeRekey`); where an old and a new id of one title meet, the
    /// one queued later stays. Returns how many entries changed, after the
    /// write landed.
    @discardableResult
    func rekey(_ map: (String) -> String) async -> Int {
        let pending = loadAll()
        let moves = NavidromeRekey.moves(pending.keys, map)
        guard !moves.isEmpty else { return 0 }
        var rekeyed = pending
        for move in moves {
            guard let update = rekeyed.removeValue(forKey: move.from) else { continue }
            if let present = rekeyed[move.to], (present.queuedAt ?? 0) >= (update.queuedAt ?? 0) { continue }
            rekeyed[move.to] = update
        }
        save(rekeyed)
        await storage.awaitPendingWrites()
        return moves.count
    }

    /// Returns when the removal has landed on disk. With `ifStill`, only
    /// while the stored entry is that one: the queue is an actor and a flush
    /// waits on the network, so a newer update for the same title can arrive
    /// meanwhile, and it must stay.
    func remove(itemId: String, ifStill sent: PendingUpdate? = nil) async {
        var pending = loadAll()
        guard let stored = pending[itemId] else { return }
        if let sent, stored != sent { return }
        pending.removeValue(forKey: itemId)
        save(pending)
        await storage.awaitPendingWrites()
    }

    /// True if at least one update is waiting to be sent. E.g. to show the user
    /// a subtle hint.
    var hasPendingUpdates: Bool {
        !loadAll().isEmpty
    }

    /// True if an update for this book is still queued. So the player can check
    /// after a flush whether its own state was sent.
    func hasPendingUpdate(itemId: String) -> Bool {
        loadAll()[itemId] != nil
    }

    /// The queued update itself, so the reconcile can tell a server that
    /// is behind our own queued write from a foreign device.
    func pendingUpdate(itemId: String) -> PendingUpdate? {
        loadAll()[itemId]
    }

    /// True while a flush is running. App start and reconnect could otherwise
    /// flush in parallel (duplicate/overtaking writes).
    private var flushInFlight = false

    /// Tries to send all pending updates to the server. Called at app start and
    /// on reconnect (see LibraryView). Updates that keep failing (e.g. still
    /// offline) stay in the queue and are retried on the next call.
    /// `targetFor` answers, per queued id, which server owns it. Nil means
    /// nobody does, and then nothing is sent: an entry without an owner is
    /// kept, never offered to whoever happens to be at hand.
    func flush(targetFor: (String) -> ProgressTarget?) async {
        guard !flushInFlight else { return }
        flushInFlight = true
        defer { flushInFlight = false }

        let pending = loadAll()
        guard !pending.isEmpty else { return }
        let flushStarted = Date()
        var sent = 0

        // The server state per OWNING server, fetched at most once each, and
        // only for servers that actually have an entry waiting. It used to be
        // one fetch from one client for the whole queue, and for a title of a
        // secondary source that answered with nothing: the stale guard
        // („the server wins") then silently did not apply to it, because a
        // missing entry reads as "no server state", not as "wrong server".
        var serverProgressPerTarget: [String: [String: BookProgress]] = [:]
        var unreachable: Set<String> = []
        for (itemId, update) in pending {
            guard let target = targetFor(itemId) else { continue }
            if serverProgressPerTarget[target.key] == nil, !unreachable.contains(target.key) {
                do {
                    serverProgressPerTarget[target.key] = try await target.client.fetchAllProgress()
                } catch {
                    // Offline, or this one server is down. Its entries stay
                    // and the next call retries THEM; the other servers are
                    // not held up by it.
                    unreachable.insert(target.key)
                }
            }
            guard let serverProgress = serverProgressPerTarget[target.key] else { continue }
            let apiClient = target.client
            // The entry may be gone by now (an active player synced and removed
            // it successfully). Then do NOT write the older state anymore.
            guard hasPendingUpdate(itemId: itemId) else { continue }
            // Server wins: if a further-ahead state is now there. E.g. because
            // another device kept listening while this one was offline. The
            // stale offline state must not overwrite it. The pending entry is
            // then dropped. A deliberate "finished" update (isFinished) is
            // exempt, since it is a status decision, not a lagging state.
            if SyncRules.shouldDropQueuedUpdate(
                queuedTime: update.currentTime,
                queuedIsFinished: update.isFinished,
                duration: update.duration,
                serverFraction: serverProgress[itemId]?.fraction,
                tolerance: reconcileThreshold
            ) {
                await remove(itemId: itemId, ifStill: update)
                continue
            }
            do {
                try await apiClient.updateProgress(
                    itemId: itemId,
                    currentTime: update.currentTime,
                    duration: update.duration,
                    isFinished: update.isFinished
                )
                await remove(itemId: itemId, ifStill: update)
                sent += 1
            } catch {
                // Still offline or another error. Keep it in the queue, the
                // next attempt comes automatically.
            }
        }
        // The flush reached the server (the fetch succeeded): a write is a
        // ring entry, a clean pass only the service's stamp, so ABS progress
        // sync is visible in the history either way.
        SyncHistoryStore.shared.record(SyncHistory.entry(
            service: .absProgress, direction: .up,
            counters: [.init(key: .positionsUp, value: sent)],
            duration: Date().timeIntervalSince(flushStarted),
            deviceId: SyncHistoryStore.deviceId, startedAt: flushStarted), moved: sent > 0)
    }

    private func loadAll() -> [String: PendingUpdate] {
        storage.load()
    }

    private func save(_ pending: [String: PendingUpdate]) {
        storage.save(pending)
    }
}
