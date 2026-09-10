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
}

/// Narrow API view the flush needs. APIClient satisfies it; tests can inject a
/// mock.
@MainActor
protocol ProgressSyncAPI {
    func fetchAllProgress() async throws -> [String: BookProgress]
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws
}

extension APIClient: ProgressSyncAPI {}

/// Row storage. Default outside tests. The queue is a set of items, so it
/// is one row per item in `pending_sync` (`KeyedRowStore`). The dictionary
/// in memory is the truth the queue reads back right after every write,
/// synchronous by contract; the rows follow in a serial write chain as the
/// diff against the last landed write. The document of the builds before
/// is read once when the rows hold nothing, poured into them and set
/// aside; an unreadable one stays `.corrupt` at the seam and is never
/// poured, the rows start fresh. What waits here are listening positions
/// that never reached the server, the one thing this app must not lose
/// quietly: a failed start read leaves the rows unknown, so the first
/// write only upserts and removes nothing it never saw.
final class SyncQueueRowStorage: SyncQueueStorage {
    private let database: MaerDatabase
    /// The seam to disk for the document of the builds before.
    private let ablage: Ablage
    private let documentName = "pending_sync.json"
    private var pending: [String: SyncQueue.PendingUpdate] = [:]
    /// What the rows hold, as far as this run knows: the last LANDED write
    /// or the start read.
    private var rowBase: RowBase<[String: SyncQueue.PendingUpdate]> = .fresh
    /// The one opening of the rows: every caller awaits the same task.
    private var rowsOpening: Task<KeyedRowStore<SyncQueue.PendingUpdate>?, Never>?
    /// The last handed-over write; each write waits for the one before it.
    private var pendingWrite: Task<Void, Never>?

    init(database: MaerDatabase, ablage: Ablage) {
        self.database = database
        self.ablage = ablage
        var loaded: [String: SyncQueue.PendingUpdate]?
        var base: RowBase<[String: SyncQueue.PendingUpdate]> = .fresh
        var rowsFailed = false
        do {
            // No file yet is a fresh install: nothing to read, fresh base.
            let reader = try database.readerNow()
            let rows = try reader.map { try KeyedRowStore<SyncQueue.PendingUpdate>.loadNow(table: .pendingSync, reader: $0) }
                ?? KeyedRowStore<SyncQueue.PendingUpdate>.Load(rows: [:], skipped: 0)
            if !rows.rows.isEmpty || rows.skipped > 0 {
                loaded = rows.rows
                base = RowBase.afterLoad(rows: rows.rows.isEmpty ? nil : rows.rows, skipped: rows.skipped)
            }
        } catch {
            base = .unknown
            rowsFailed = true
            Logger.library.error("SYNCQUEUE rows read failed reason=\(String(describing: error), privacy: .public) fallback=migrated")
        }
        var document: URL?
        if loaded == nil {
            // Corrupt is kept aside by the seam and never buried; the rows
            // then start fresh.
            if let current = ablage.loadNow([String: SyncQueue.PendingUpdate].self, name: documentName).value {
                loaded = current
                document = ablage.url(for: documentName)
            }
            if rowsFailed {
                loaded = loaded ?? ablage.loadNow([String: SyncQueue.PendingUpdate].self, name: documentName + ".migrated").value
                document = nil
            }
        }
        pending = loaded ?? [:]
        rowBase = base
        Logger.library.notice("SYNCQUEUE start: entries=\(self.pending.count) migrate=\(document != nil)")
        if let document, let loaded { migrate(document, stock: loaded) }
    }

    func load() -> [String: SyncQueue.PendingUpdate] {
        pending
    }

    /// The memory is the truth at once; the rows get the diff in the chain.
    /// A failure is logged and the base kept, so the next write diffs
    /// against what really landed and the entries stay queued in memory.
    func save(_ pending: [String: SyncQueue.PendingUpdate]) {
        self.pending = pending
        let snapshot = pending
        let previous = pendingWrite
        pendingWrite = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard let self, let rows = await self.openRows() else { return }
            // The base is read HERE, after the write before landed or failed.
            let base = self.rowBase
            do {
                switch base.plan {
                case .diff:
                    _ = try await rows.apply(previous: base.knownValue ?? [:], current: snapshot)
                case .upsertOnly:
                    _ = try await rows.apply(previous: [:], current: snapshot)
                }
                self.rowBase = .known(snapshot)
            } catch {
                Logger.library.error("SYNCQUEUE save failed reason=\(String(describing: error), privacy: .public) base kept")
            }
        }
    }

    /// Waits for every queued write of the rows (tests, teardown).
    func awaitPendingWrites() async {
        await pendingWrite?.value
    }

    /// The document into the rows, whole, then set aside as `.migrated`
    /// (excluded from the backup; removed by the release after next).
    private func migrate(_ document: URL, stock: [String: SyncQueue.PendingUpdate]) {
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, let rows = await self.openRows() else { return }
            do {
                _ = try await rows.replaceAll(stock)
                try DocumentMigration.setAside(document)
                self.rowBase = .known(stock)
                Logger.library.notice("SYNCQUEUE migrate: entries=\(stock.count) document=\(document.lastPathComponent, privacy: .public)")
            } catch {
                Logger.library.error("SYNCQUEUE migrate failed reason=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func openRows() async -> KeyedRowStore<SyncQueue.PendingUpdate>? {
        if let rowsOpening { return await rowsOpening.value }
        let opening = Task<KeyedRowStore<SyncQueue.PendingUpdate>?, Never> { [database] in
            do {
                return try await KeyedRowStore<SyncQueue.PendingUpdate>(connection: try database.connection(), table: .pendingSync)
            } catch {
                Logger.library.error("SYNCQUEUE rows open failed reason=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        rowsOpening = opening
        return await opening.value
    }
}

/// Persists unsent progress updates so they survive an app kill during an
/// offline phase. Without it a progress update would be lost if the app is
/// closed offline before the next automatic sync attempt (every 30 s).
///
/// Only the LATEST state per book is stored on purpose (a dictionary, no
/// history). Only the newest progress matters, older intermediate states would
/// be outdated anyway.
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

    func enqueue(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) {
        var pending = loadAll()
        pending[itemId] = PendingUpdate(
            currentTime: currentTime,
            duration: duration,
            isFinished: isFinished,
            queuedAt: Date().timeIntervalSince1970 * 1000
        )
        save(pending)
    }

    /// All pending updates. For the library, so it can show the locally newest
    /// (not-yet-sent) state.
    func allPending() -> [String: PendingUpdate] {
        loadAll()
    }

    func remove(itemId: String) {
        var pending = loadAll()
        guard pending[itemId] != nil else { return }
        pending.removeValue(forKey: itemId)
        save(pending)
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

    /// True while a flush is running. App start and reconnect could otherwise
    /// flush in parallel (duplicate/overtaking writes).
    private var flushInFlight = false

    /// Tries to send all pending updates to the server. Called at app start and
    /// on reconnect (see LibraryView). Updates that keep failing (e.g. still
    /// offline) stay in the queue and are retried on the next call.
    func flush(apiClient: ProgressSyncAPI) async {
        guard !flushInFlight else { return }
        flushInFlight = true
        defer { flushInFlight = false }

        let pending = loadAll()
        guard !pending.isEmpty else { return }
        let flushStarted = Date()
        var sent = 0

        // Fetch the current server state of all books once before writing, to
        // detect stale offline updates. If this fetch fails (e.g. still
        // offline), NOTHING is written blindly. The queue stays untouched and
        // the next call retries.
        let serverProgress: [String: BookProgress]
        do {
            serverProgress = try await apiClient.fetchAllProgress()
        } catch {
            return
        }
        // The flush reached the server (fetch succeeded). Record the
        // check even if no position ends up written below, so ABS progress sync
        // is visible in the history when nothing was hanging in the queue.
        await MainActor.run { SyncHistoryStore.shared.noteChecked(.absProgress) }

        for (itemId, update) in pending {
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
                remove(itemId: itemId)
                continue
            }
            do {
                try await apiClient.updateProgress(
                    itemId: itemId,
                    currentTime: update.currentTime,
                    duration: update.duration,
                    isFinished: update.isFinished
                )
                remove(itemId: itemId)
                sent += 1
            } catch {
                // Still offline or another error. Keep it in the queue, the
                // next attempt comes automatically.
            }
        }
        // Record the flush when it actually wrote something.
        if sent > 0 {
            await MainActor.run {
                SyncHistoryStore.shared.append(SyncHistory.entry(
                    service: .absProgress, direction: .up,
                    counters: [.init(key: .positionsUp, value: sent)],
                    duration: Date().timeIntervalSince(flushStarted),
                    deviceId: SyncHistoryStore.deviceId, startedAt: flushStarted))
            }
        }
    }

    private func loadAll() -> [String: PendingUpdate] {
        storage.load()
    }

    private func save(_ pending: [String: PendingUpdate]) {
        storage.save(pending)
    }
}
