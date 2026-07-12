import Foundation

/// Persistenz-Abstraktion der Queue — in Tests durch In-Memory ersetzbar.
protocol SyncQueueStorage {
    func load() -> [String: SyncQueue.PendingUpdate]
    func save(_ pending: [String: SyncQueue.PendingUpdate])
}

/// Narrow API view the flush needs — APIClient satisfies it; tests can inject a
/// mock.
@MainActor
protocol ProgressSyncAPI {
    func fetchAllProgress() async throws -> [String: BookProgress]
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws
}

extension APIClient: ProgressSyncAPI {}

/// File storage (atomic) — default outside tests. Deliberately top-level: as a
/// type nested in SyncQueue it would inherit its MainActor isolation and could
/// not be constructed as a default argument.
struct SyncQueueFileStorage: SyncQueueStorage {
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pending_sync.json")

    func load() -> [String: SyncQueue.PendingUpdate] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: SyncQueue.PendingUpdate].self, from: data) else {
            return [:]
        }
        return dict
    }

    func save(_ pending: [String: SyncQueue.PendingUpdate]) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        // Atomic: an app kill mid-write must not corrupt the queue (load would
        // otherwise silently return [:] → everything lost).
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Persists unsent progress updates to disk so they survive an app kill during
/// an offline phase. Without it a progress update would be lost if the app is
/// closed offline before the next automatic sync attempt (every 30 s).
///
/// Only the LATEST state per book is stored on purpose (a dictionary, no
/// history) — only the newest progress matters, older intermediate states would
/// be outdated anyway.
@MainActor
final class SyncQueue {
    static let shared = SyncQueue()

    struct PendingUpdate: Codable {
        let currentTime: Double
        let duration: Double
        let isFinished: Bool
        /// ms epoch when queued — for "recently listened" in the library.
        /// Optional: entries from older app versions lack this field.
        var queuedAt: Double? = nil
    }

    private let storage: SyncQueueStorage

    /// Tolerance (seconds) at which a server state counts as "further ahead" —
    /// the same threshold as the device reconcile in PlayerViewModel.
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

    /// All pending updates — for the library, so it can show the locally newest
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

    /// True if at least one update is waiting to be sent — e.g. to show the user
    /// a subtle hint.
    var hasPendingUpdates: Bool {
        !loadAll().isEmpty
    }

    /// True if an update for this book is still queued — so the player can check
    /// after a flush whether its own state was sent.
    func hasPendingUpdate(itemId: String) -> Bool {
        loadAll()[itemId] != nil
    }

    /// True while a flush is running — app start and reconnect could otherwise
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

        // Fetch the current server state of all books once before writing, to
        // detect stale offline updates. If this fetch fails (e.g. still
        // offline), NOTHING is written blindly — the queue stays untouched and
        // the next call retries.
        let serverProgress: [String: BookProgress]
        do {
            serverProgress = try await apiClient.fetchAllProgress()
        } catch {
            return
        }

        for (itemId, update) in pending {
            // The entry may be gone by now (an active player synced and removed
            // it successfully) — then do NOT write the older state anymore.
            guard hasPendingUpdate(itemId: itemId) else { continue }
            // Server wins: if a further-ahead state is now there — e.g. because
            // another device kept listening while this one was offline — the
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
            } catch {
                // Still offline or another error — keep it in the queue, the
                // next attempt comes automatically.
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
