import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

/// Sync-Politik: periodischer Sync, Reentrancy-Guard, Konflikt-Erkennung,
/// Device reconcile, offline-queue integration and played state.
extension PlayerViewModel {

    // MARK: - Sync (the app's actual reason for existing)

    func startSyncTimer() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await self.syncProgress(force: false)
            }
        }
    }

    /// Writes the progress to the server. Reentrancy-safe: there is never more
    /// than one write in flight — parallel writes could overtake each other on
    /// the network and the older state would win.
    /// - Parameter force: forces a sync even without the 5-second threshold
    ///   (e.g. on pause or when the app goes to the background).
    func syncProgress(force: Bool) async {
        if syncInFlight {
            // Drop timer ticks (the next one comes anyway); deliberate syncs
            // (pause/seek) are re-run once with a fresh state after completion.
            if force { syncFollowUpRequested = true }
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }

        var runForce = force
        repeat {
            syncFollowUpRequested = false
            await performSync(force: runForce)
            runForce = true
        } while syncFollowUpRequested
    }

    private func performSync(force: Bool) async {
        guard let item else { return }
        guard force || abs(currentTime - lastSyncedTime) >= 5 else { return }

        // Core rule: a backward jump the user did NOT initiate is never written
        // silently.
        if !suppressConflictForNextSync,
           SyncRules.isSuspiciousDrop(
               currentTime: currentTime,
               lastSyncedTime: lastSyncedTime,
               threshold: suspiciousDropThreshold
           ) {
            if pendingServerConflict == nil {
                pendingServerConflict = ServerConflict(serverTime: lastSyncedTime, localTime: currentTime)
                showSourceHint(.conflict)
            }
            return
        }

        let isFinishedNow = duration > 0 && currentTime >= duration - 1
        do {
            try await provider.updateProgress(
                itemId: item.id,
                currentTime: currentTime,
                duration: duration,
                isFinished: isFinishedNow
            )
            lastSyncedTime = currentTime
            suppressConflictForNextSync = false
            // Our own write moved the server's lastUpdate forward — adopt the
            // SERVER's timestamp (not the device clock: the clocks differ),
            // exactly like updateSyncStatusFromQueue does after a queue flush.
            // Otherwise the next reconcile takes our own echo for a foreign
            // device and jumps back after an offline stretch. Only meaningful
            // (and affordable) for real progress-sync sources.
            if provider.capabilities.contains(.progressSync),
               let fresh = try? await provider.fetchItemDetail(itemId: item.id),
               let ms = fresh.userMediaProgress?.lastUpdate {
                lastKnownServerUpdate = max(lastKnownServerUpdate, ms)
            }
            SyncQueue.shared.remove(itemId: item.id)
            if let key = localPositionKey {
                // Podcasts (rss:/abspod:) keep `localPosition` as the iCloud
                // sync basis — including ABS podcasts, so iCloud reconciles them
                // across devices. Only for books (server = store of record) is
                // the local crash backup removed after a successful sync.
                let isPodcast = item.id.hasPrefix("rss:") || item.id.hasPrefix("abspod:")
                if provider.capabilities.contains(.progressSync) && !isPodcast {
                    UserDefaults.standard.removeObject(forKey: key)
                } else {
                    UserDefaults.standard.set([currentTime, Date().timeIntervalSince1970 * 1000], forKey: key)
                    // gpodder: push the podcast position too (periodically + on
                    // pause/stop/seek). No-op without config; abspod: is mapped
                    // via the feed-guid bridge.
                    if item.id.hasPrefix("rss:") || item.id.hasPrefix("abspod:") {
                        GPodderSync.shared.notePlayback(itemId: item.id,
                                                        position: currentTime, duration: duration)
                    }
                }
            }
            // Report only transitions (no 30s spam): offline/queued/failed → saved.
            if syncStatus != .synced {
                showSourceHint(.saved)
            }
            syncStatus = .synced
        } catch {
            if NetworkStatus.isOfflineError(error) {
                // Expected, not a real error: no network right now, e.g. while
                // travelling. Put the current state into the offline queue so it
                // survives an app kill instead of being lost — it is flushed
                // automatically on the next start or on reconnect (see SyncQueue).
                SyncQueue.shared.enqueue(
                    itemId: item.id,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinishedNow
                )
                errorMessage = nil
                if syncStatus != .queued { showSourceHint(.queued) }
                syncStatus = .queued
            } else {
                // A real error (e.g. expired token, server problem) — surface
                // it, but queue the state anyway: it would otherwise be lost if
                // the app is closed before the next attempt. The flush reconciles
                // against the server anyway.
                SyncQueue.shared.enqueue(
                    itemId: item.id,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinishedNow
                )
                errorMessage = String(localized: "Sync failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                syncStatus = .failed
            }
            // The state is persisted in the queue = locally committed: treat it
            // like a successful write for the conflict bookkeeping. Otherwise a
            // user-confirmed rewind that failed to send would re-trigger the
            // conflict dialog on every following tick (lastSyncedTime still on
            // the old higher value), and the suppress flag would stay stuck.
            lastSyncedTime = currentTime
            suppressConflictForNextSync = false
        }
    }

    /// Connection lost while playing: set the visible sync status to "offline"
    /// immediately instead of waiting for the next sync tick (every 30s).
    /// Deliberately NOTHING is queued — that still happens only when a real
    /// syncProgress attempt fails.
    func markConnectionLostWhilePlaying() {
        guard isPlaying, syncStatus == .synced else { return }
        syncStatus = .offline
        showSourceHint(.offline)
    }

    /// Call after a flush of the offline queue: if our own entry was sent
    /// successfully, move the visible status from .queued to .synced — otherwise
    /// the "will be sent" hint would stay until the next sync tick, though long
    /// since synced.
    func updateSyncStatusFromQueue() async {
        guard let item, syncStatus != .synced else { return }
        if !SyncQueue.shared.hasPendingUpdate(itemId: item.id) {
            if syncStatus == .queued || syncStatus == .failed { showSourceHint(.saved) }
            syncStatus = .synced
            // Adopt the server timestamp of OUR own flushed write without
            // adopting the position — otherwise the next reconcile mistakes our
            // (older) flush state for a foreign device and jumps back.
            if let fresh = try? await provider.fetchItemDetail(itemId: item.id),
               let ms = fresh.userMediaProgress?.lastUpdate {
                lastKnownServerUpdate = max(lastKnownServerUpdate, ms)
            }
        }
    }

    /// User confirmed in the dialog: really write the lower state.
    func confirmLowerProgress() async {
        suppressConflictForNextSync = true
        pendingServerConflict = nil
        await syncProgress(force: true)
    }

    /// User cancelled: jump back to the last saved server state so the conflict
    /// is resolved and does not pop up again.
    func cancelAndRestoreServerPosition() {
        pendingServerConflict = nil
        Task { await seek(to: lastSyncedTime, userInitiated: false) }
    }

    func dismissLowerProgressConflict() {
        pendingServerConflict = nil
    }

    /// User confirmed in the dialog: the jump series was really intended, sync
    /// the current (further-ahead) state immediately.
    func confirmLockscreenJump() async {
        suspiciousLockscreenJump = nil
        suppressConflictForNextSync = true
        await syncProgress(force: true)
    }

    /// User cancelled: jump back to the state before the jump series began —
    /// probably pocket contact, not intended.
    func cancelLockscreenJump() {
        guard let jump = suspiciousLockscreenJump else { return }
        suspiciousLockscreenJump = nil
        Task { await seek(to: jump.beforeTime, userInitiated: false) }
    }

    func dismissLockscreenJump() {
        suspiciousLockscreenJump = nil
    }


    /// Sets the book to "finished" server-side, or reverses it.
    func toggleFinished() async {
        guard let item else { return }
        // Respect the same in-flight guard as syncProgress — otherwise this
        // write could overtake a running position write on the network.
        while syncInFlight {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        syncInFlight = true
        defer { syncInFlight = false }

        let target = !isFinished
        // Marking as finished sets the progress explicitly to the book end;
        // undoing keeps the current state and only flips the flag.
        let writeTime = target ? duration : currentTime
        do {
            try await provider.updateProgress(
                itemId: item.id,
                currentTime: writeTime,
                duration: duration,
                isFinished: target
            )
            SyncQueue.shared.remove(itemId: item.id)
        } catch {
            // Don't lose the user's status decision: queue it, apply locally
            // anyway — the flush sends it later.
            SyncQueue.shared.enqueue(
                itemId: item.id,
                currentTime: writeTime,
                duration: duration,
                isFinished: target
            )
            if NetworkStatus.isOfflineError(error) {
                if syncStatus != .queued { showSourceHint(.queued) }
                syncStatus = .queued
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                syncStatus = .failed
            }
        }
        isFinished = target
        // Providers without server sync (RSS/local): the played state lives in
        // `localPosition` — set or remove it directly here.
        if !provider.capabilities.contains(.progressSync), let key = localPositionKey {
            if target {
                UserDefaults.standard.set([duration, Date().timeIntervalSince1970 * 1000], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if target {
            // Align the local state: jump to the book end and update the sync
            // state — otherwise the periodic sync would immediately write the old
            // state with isFinished=false again.
            await seek(to: duration, userInitiated: false)
            lastSyncedTime = duration
        } else {
            lastSyncedTime = currentTime
        }
    }


    /// Called when the app comes back to the foreground. Covers the case that
    /// another device kept listening in the meantime while this app instance was
    /// only in the background (not killed). Adopts the server state ONLY if it is
    /// further ahead than the local position — never the reverse, which would
    /// discard own progress.
    func reconcileWithServer() async {
        guard let item else { return }
        do {
            let fresh = try await provider.fetchItemDetail(itemId: item.id)
            let serverTime = fresh.userMediaProgress?.currentTime ?? 0
            let serverUpdate = fresh.userMediaProgress?.lastUpdate ?? 0
            // Newer server entry than the last seen + differing position →
            // another device wrote. Adopt — also BACKWARDS (a deliberate rewind
            // there is intended). After our own write serverTime ≈ currentTime →
            // no jump. Fallback without lastUpdate (old servers): forward only as
            // before.
            let isNewer = serverUpdate > lastKnownServerUpdate
            // Own-echo guard: if the server holds exactly the state WE last
            // wrote, it is not a foreign device — regardless of timestamps
            // (server clocks can run ahead of the device clock).
            let ownEcho = SyncRules.isOwnServerEcho(serverTime: serverTime, lastSyncedTime: lastSyncedTime)
            let adopt = !ownEcho && SyncRules.shouldAdoptServerState(
                serverTime: serverTime,
                serverUpdateMs: serverUpdate,
                lastKnownServerUpdateMs: lastKnownServerUpdate,
                currentTime: currentTime
            )
            if adopt {
                await seek(to: serverTime, userInitiated: false)
                lastSyncedTime = serverTime
                showSourceHint(.serverAdopted)
            }
            // Also adopt the finished flag from the newer entry — e.g. marked
            // (un)played on another device.
            if isNewer, let serverFinished = fresh.userMediaProgress?.isFinished,
               serverFinished != isFinished {
                isFinished = serverFinished
            }
            lastKnownServerUpdate = max(lastKnownServerUpdate, serverUpdate)
            syncStatus = .synced
        } catch {
            // No network etc.: just continue with the local state, no playback
            // interruption because of a reconcile error.
        }
    }
}
