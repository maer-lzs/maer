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

/// File storage (atomic). Default outside tests. Deliberately top-level: as a
/// type nested in SyncQueue it would inherit its MainActor isolation and could
/// not be constructed as a default argument.
///
/// A CLASS, not a struct. It has to remember across the two calls
/// that the stored queue could not be read, and a value type cannot carry that
/// from `load()` to `save()`. It lives behind SyncQueue's isolation, so the
/// mutable state stays single-threaded.
final class SyncQueueFileStorage: SyncQueueStorage {
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pending_sync.json")

    /// Unread is not empty. What waits here are listening positions
    /// that never reached the server. The one thing this app must not lose
    /// quietly.
    private var readFailed = false

    func load() -> [String: SyncQueue.PendingUpdate] {
        // Synchronous by contract: the queue reads itself back right after
        // every write. The seam keeps an unreadable file aside.
        let outcome = Ablage(directory: fileURL.deletingLastPathComponent())
            .loadNow([String: SyncQueue.PendingUpdate].self, name: fileURL.lastPathComponent)
        if case .corrupt = outcome { readFailed = true }
        return outcome.value ?? [:]
    }

    func save(_ pending: [String: SyncQueue.PendingUpdate]) {
        guard CorruptStore.maySave(isEmpty: pending.isEmpty, afterCorruptRead: readFailed) else {
            Logger.library.error("pending sync queue NOT saved: the stored queue was unreadable and this state is empty")
            return
        }
        // Temp and rename through the seam: an app kill mid-write must not
        // corrupt the queue (load would otherwise return [:], everything
        // lost). A failure is logged by the seam; the entries stay queued in
        // memory for the next write.
        do {
            try Ablage(directory: fileURL.deletingLastPathComponent())
                .saveNow(pending, name: fileURL.lastPathComponent)
            readFailed = false
        } catch {
            return
        }
    }
}

/// Persists unsent progress updates to disk so they survive an app kill during
/// an offline phase. Without it a progress update would be lost if the app is
/// closed offline before the next automatic sync attempt (every 30 s).
///
/// Only the LATEST state per book is stored on purpose (a dictionary, no
/// history). Only the newest progress matters, older intermediate states would
/// be outdated anyway.
@MainActor
final class SyncQueue {
    static let shared = SyncQueue()

    nonisolated struct PendingUpdate: Codable {
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
        self.storage = SyncQueueFileStorage()
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
