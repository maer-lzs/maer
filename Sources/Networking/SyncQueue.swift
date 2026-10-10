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
    /// Whether the start could not read the stored entries: then the store
    /// may hold entries `load()` lacks.
    var startReadFailed: Bool { get }
    /// Whether the start missed entries, also single ones that did not
    /// decode (`RowChain.startIncomplete`).
    var startIncomplete: Bool { get }
}

extension SyncQueueStorage {
    /// A storage without rows misses nothing.
    var startIncomplete: Bool { false }
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
/// answers its caller (see `SyncQueue.enqueue`). What waits here are listening
/// positions that never reached the server, the one thing this app must
/// not lose quietly: a failed start read leaves the rows unknown, so the
/// first write only upserts and removes nothing it never saw.
final class SyncQueueRowStorage: SyncQueueStorage {
    private let keeper: RowKeeper<SyncQueue.PendingUpdate>
    private var pending: [String: SyncQueue.PendingUpdate] = [:]

    init(database: MaerDatabase) {
        self.keeper = RowKeeper(database: database, table: .pendingSync, label: "SYNCQUEUE")
        pending = keeper.startNow() ?? [:]
        // Rows read after a failed start join the queue; an entry this run
        // queued again is the newer one.
        keeper.adopt = { [weak self] read in
            guard let self else { return }
            self.pending = RowKeeper.union(read: read, run: self.pending)
        }
        Logger.library.notice("SYNCQUEUE start: entries=\(self.pending.count)")
    }

    func load() -> [String: SyncQueue.PendingUpdate] {
        pending
    }

    var startReadFailed: Bool { keeper.startReadFailed }
    var startIncomplete: Bool { keeper.startIncomplete }

    /// The memory is the truth at once; the rows get the diff in the chain,
    /// and a failed write keeps the entries queued in memory. Emptying is
    /// allowed: a sent entry leaves the queue, and one that stayed would be
    /// sent again.
    func save(_ pending: [String: SyncQueue.PendingUpdate]) {
        self.pending = pending
        keeper.write(emptying: .allowed) { [weak self] in self?.pending }
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
        self.storage = SyncQueueRowStorage(database: MaerDatabase.shared)
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

    /// Whether the start missed entries (named by the move, not waited for).
    var startIncomplete: Bool { storage.startIncomplete }

    /// Every waiting update under the id in the form the server answers to
    /// (`NavidromeRekey`); where an old and a new id of one title meet, the
    /// one queued later stays. Returns how many entries changed, after the
    /// write landed. Nil while the start could not read the entries: the
    /// rows may hold old ids this memory lacks.
    @discardableResult
    func rekey(_ map: (String) -> String) async -> Int? {
        if storage.startReadFailed { return nil }
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

    /// Returns when the removal has landed on disk. Only while the stored
    /// entry is still the one the caller saw before its own write: the queue
    /// is an actor and every writer waits on the network, so a decision
    /// queued meanwhile by another path (the detail sheet, the grid) must
    /// stay. A caller that saw nothing (`nil`) removes nothing. No default:
    /// every caller says what it saw.
    func remove(itemId: String, ifStill sent: PendingUpdate?) async {
        var pending = loadAll()
        guard let stored = pending[itemId], stored == sent else { return }
        pending.removeValue(forKey: itemId)
        save(pending)
        await storage.awaitPendingWrites()
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
                    Logger.library.notice("SYNCQUEUE fetch failed, entries stay queued: \(FailureReason.of(error), privacy: .public)")
                    unreachable.insert(target.key)
                }
            }
            guard let serverProgress = serverProgressPerTarget[target.key] else { continue }
            let apiClient = target.client
            // The entry may be gone by now (an active player synced and removed
            // it successfully), or a newer state of the same title may have
            // been queued while the server was asked. Then do NOT write the
            // older state: only the entry this flush read goes out, the newer
            // one waits for the next flush.
            guard pendingUpdate(itemId: itemId) == update else { continue }
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
                // A refusal of the content gets the same answer every time:
                // the entry leaves instead of being sent on every flush.
                if Self.refusesTheWrite(error) {
                    Logger.library.error("SYNCQUEUE dropped, the server refused the write: \(FailureReason.of(error), privacy: .public)")
                    await remove(itemId: itemId, ifStill: update)
                    continue
                }
                // Still offline or another error. It stays queued; the next
                // attempt comes automatically.
                Logger.library.notice("SYNCQUEUE send stays queued: \(FailureReason.of(error), privacy: .public)")
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

    /// Whether a server refused a progress write for its content, from any
    /// of the three server clients (`SyncRules.refusesContent`).
    nonisolated static func refusesTheWrite(_ error: Error) -> Bool {
        let status: Int?
        if let api = error as? APIError, case .http(let code, _) = api { status = code }
        else if let jellyfin = error as? JellyfinClient.JellyfinError, case .http(let code) = jellyfin { status = code }
        else if let subsonic = error as? SubsonicClient.SubsonicError, case .http(let code) = subsonic { status = code }
        else { status = nil }
        return status.map(SyncRules.refusesContent(status:)) ?? false
    }

    private func loadAll() -> [String: PendingUpdate] {
        storage.load()
    }

    private func save(_ pending: [String: PendingUpdate]) {
        storage.save(pending)
    }
}
