// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit
import OSLog

/// Sync-Politik: periodischer Sync, Reentrancy-Guard, Konflikt-Erkennung,
/// Device reconcile, offline-queue integration and played state.
extension PlayerViewModel {

    // MARK: - Sync (the app's actual reason for existing)

    func startSyncTimer() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            var tick = 0
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(PlaybackClaimRules.tickSeconds * 1_000_000_000))
                if Task.isCancelled { break }
                tick += 1
                // The server sync and the own heartbeat keep their 30 s.
                if PlaybackClaimRules.syncDue(tick: tick) {
                    await self.syncProgress(force: false)
                    // Takeover channel: refresh the own claim while playing
                    // (a claim that stops growing means "stopped playing").
                    if self.isPlaying { self.refreshClaim(forced: false) }
                }
                // The poll for a foreign claim runs every ten seconds while
                // playing: measured (D10 d), the takeover reaches a locked,
                // playing device by poll alone, so the poll is the promise;
                // the external-change notification only makes it sooner.
                if PlaybackClaimRules.pollDue(tick: tick, playing: self.isPlaying) {
                    PlaybackClaimSync.shared.poll()
                }
                // The pot's carrier is asked while playing at ITS cadence:
                // every tick on the iCloud carriers (a stand the other
                // device pushed reaches the rows within the tick, D10 d),
                // less often on a carrier that delivers by itself.
                if self.isPlaying { await PodcastCloudSync.shared.pullIfDue(tick: tick, by: "tick") }
            }
        }
    }

    /// Writes the progress to the server. Reentrancy-safe: there is never more
    /// than one write in flight. Parallel writes could overtake each other on
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
        // A start that no source answered may not push. Not even
        // forced. At 00:00 in a fresh session this would overwrite a server
        // that is hours ahead, and the suspicious-drop guard has no reference
        // value to catch it.
        guard SyncRules.mayPushProgress(startSourceResolved: startSourceResolved) else { return }
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

        let isFinishedNow = SyncRules.isFinished(currentTime: currentTime, duration: duration)
        do {
            try await provider.updateProgress(
                itemId: item.id,
                currentTime: currentTime,
                duration: duration,
                isFinished: isFinishedNow
            )
            lastSyncedTime = currentTime
            suppressConflictForNextSync = false
            // A real ABS progress write happened. Keep the "last
            // checked" stamp current (throttled to disk in the store). Only for
            // progress-sync sources (books); Subsonic scrobbles, radio no-ops.
            if provider.capabilities.contains(.progressSync) {
                SyncHistoryStore.shared.noteChecked(.absProgress)
            }
            // Our own write moved the server's lastUpdate forward. Adopt the
            // SERVER's timestamp (not the device clock: the clocks differ),
            // exactly like updateSyncStatusFromQueue does after a queue flush.
            // Otherwise the next reconcile takes our own echo for a foreign
            // device and jumps back after an offline stretch. Only meaningful
            // (and affordable) for real progress-sync sources.
            if provider.capabilities.contains(.progressSync) {
                if let fresh = try? await provider.fetchItemDetail(itemId: item.id),
                   let ms = fresh.userMediaProgress?.lastUpdate {
                    lastKnownServerUpdate = max(lastKnownServerUpdate, ms)
                } else {
                    // The write landed, the read after it did not (a dead
                    // spot closing in). The known server moment stays old,
                    // and the reconcile after the reconnect must not take
                    // this write for a foreign one: the echo guard holds it
                    // by position, not by this moment.
                    Logger.player.notice("SYNC post-write refresh failed item=\(item.id, privacy: .private(mask: .hash)) knownMs kept=\(Int(self.lastKnownServerUpdate))")
                }
            }
            await SyncQueue.shared.remove(itemId: item.id)
            // The library model holds the book's moment for the Continue
            // rows; it learns the written position now (state only, the
            // rows rebuild on the next listening event, never per tick).
            if !PodcastCloudSync.potCarries(item.id) {
                AppSession.shared.libraryViewModel.noteLocalProgress(
                    itemId: item.id, currentTime: currentTime, duration: duration, isFinished: isFinishedNow)
            }
            // Podcasts (rss:/abspod:) keep `localPosition` as the iCloud
            // sync basis. Including ABS podcasts, so iCloud reconciles them
            // across devices. Only for books (server = store of record) is
            // the local crash backup removed after a successful sync.
            let isPodcast = ItemNamespace.isPodcastEpisode(item.id)
            if provider.capabilities.contains(.progressSync) && !isPodcast {
                // The crash backup has done its job and goes.
                // But WHAT we pushed and WHEN stays. A deleted witness is
                // not a fact; that is the same lesson as the `[0, now]`
                // tombstone further down, one level further. Without this
                // a downloaded book has no local source at all (the cached
                // detail keeps the download-time state forever) and starts
                // at 0 whenever the server is missing, late or empty.
                ListeningStore.noteFlushed(
                    item.id, position: currentTime,
                    atMs: Date().timeIntervalSince1970 * 1000)
                ListeningStore.clearBackup(item.id)
            } else if SyncRules.mayWritePodcastLocalState(playedSinceLoad: eventSinceLoad,
                                                           deliberateRestart: false,
                                                           deliberateSeek: false) {
                // This branch is gated on an EVENT since load. The
                // restore flush used to run through here and re-stamped the
                // RESTORED position with a fresh timestamp, locally and to
                // gpodder. The reviver that beat the user's finished mark
                // twice. Restoring is loading, not listening: a merely-loaded
                // episode writes nothing. (restart and deliberate seeks set
                // the flag before they arrive here, so both still write.
                // Their flush is the user acting.)
                //
                // The duration travels along as the third value: at the
                // natural end `currentTime == duration`, and without that
                // reference a later-grown ad duration would show the
                // finished episode as started again. `advancing`, not
                // `entry`. With an unknown duration this must not drop a
                // reference point that is already there.
                ListeningStore.record(item.id, position: currentTime,
                                      duration: duration,
                                      atMs: Date().timeIntervalSince1970 * 1000)
                // gpodder: push the podcast position too (periodically + on
                // pause/stop/seek). No-op without config; abspod: is mapped
                // via the feed-guid bridge.
                if ItemNamespace.isPodcastEpisode(item.id) {
                    GPodderSync.shared.notePlayback(itemId: item.id,
                                                    position: currentTime, duration: duration)
                }
                // The pot: a deliberate sync (pause, stop, seek) sends at
                // once, the timer tick only within the cadence.
                sendStateToPot(deliberate: force)
            }
            // Report only transitions (no 30s spam): offline/queued/failed → saved.
            if syncStatus != .synced {
                showSourceHint(.saved)
            }
            syncStatus = .synced
        } catch {
            // Whatever the error, the current state goes into the offline
            // queue so it survives an app kill instead of being lost. It is
            // flushed automatically on the next start or on reconnect (see
            // SyncQueue) and reconciled against the server there. Only the
            // message and the status differ between the two causes.
            await SyncQueue.shared.enqueue(
                itemId: item.id,
                currentTime: currentTime,
                duration: duration,
                isFinished: isFinishedNow
            )
            if NetworkStatus.isOfflineError(error) {
                // Expected, not a real error: no network right now, e.g. while
                // travelling.
                errorMessage = nil
                if syncStatus != .queued { showSourceHint(.queued) }
                syncStatus = .queued
            } else {
                // A real error (e.g. expired token, server problem). Surface it.
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
    /// Deliberately NOTHING is queued. That still happens only when a real
    /// syncProgress attempt fails.
    func markConnectionLostWhilePlaying() {
        guard isPlaying, syncStatus == .synced else { return }
        syncStatus = .offline
        showSourceHint(.offline)
    }

    /// Call after a flush of the offline queue: if our own entry was sent
    /// successfully, move the visible status from .queued to .synced. Otherwise
    /// the "will be sent" hint would stay until the next sync tick, though long
    /// since synced.
    func updateSyncStatusFromQueue() async {
        guard let item, syncStatus != .synced else { return }
        if !SyncQueue.shared.hasPendingUpdate(itemId: item.id) {
            if syncStatus == .queued || syncStatus == .failed { showSourceHint(.saved) }
            syncStatus = .synced
            // Adopt the server timestamp of OUR own flushed write without
            // adopting the position. Otherwise the next reconcile mistakes our
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

    /// User cancelled: jump back to the state before the jump series began.
    /// Probably pocket contact, not intended.
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
        // Respect the same in-flight guard as syncProgress. Otherwise this
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
        // Invariant "heard = flies out": marking finished drops it from the
        // global Up-Next queue, whether the server write succeeds now or queues.
        if target { PlayQueue.shared.markedPlayed(item.id) }
        do {
            try await provider.updateProgress(
                itemId: item.id,
                currentTime: writeTime,
                duration: duration,
                isFinished: target
            )
            await SyncQueue.shared.remove(itemId: item.id)
        } catch {
            // Don't lose the user's status decision: queue it, apply locally
            // anyway. The flush sends it later.
            await SyncQueue.shared.enqueue(
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
        // `localPosition`. Set or remove it directly here.
        if !provider.capabilities.contains(.progressSync) {
            let nowMs = Date().timeIntervalSince1970 * 1000
            if target {
                // With an unknown duration `entry(position: 0, duration: 0)`
                // wrote `[0, now]`. Which READS as unplayed. Same sentinel as
                // `PodcastProgressStore.setPlayed`: it needs no duration.
                let position = duration > 0 ? duration : ProgressMark.playedSentinel
                ListeningStore.record(item.id, position: position,
                                      duration: duration, atMs: nowMs)
            } else {
                // A deleted key is not a fact: it loses against the older
                // iCloud value on the next reconcile (newest-wins) and the
                // episode flips back to played. The `[0, now]` tombstone is a
                // decided pattern. `setPlayed` has always used it, this path
                // deviated from it.
                ListeningStore.store(item.id, entry: [0.0, nowMs])
            }
        }
        if target {
            // Align the local state: jump to the book end and update the sync
            // state. Otherwise the periodic sync would immediately write the old
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
    /// further ahead than the local position. Never the reverse, which would
    /// discard own progress.
    func reconcileWithServer() async {
        guard let item else { return }
        do {
            let fresh = try await provider.fetchItemDetail(itemId: item.id)
            // The server has spoken. Whatever it said. That RESOLVES the
            // start: even "it knows nothing" is an answer, and a genuinely new
            // book must be able to report progress.
            startSourceResolved = true
            let serverTime = fresh.userMediaProgress?.currentTime ?? 0
            let serverUpdate = fresh.userMediaProgress?.lastUpdate ?? 0
            // Whatever the server says now also goes into
            // the cached detail. That file IS the start source of a
            // downloaded book, and until here it kept the download-time state
            // for good. Covers the case the flushed witness cannot: downloaded
            // on this device, listened to on another one, opened offline.
            if let serverProgress = fresh.userMediaProgress {
                await DownloadManager.shared.updateCachedProgress(itemId: item.id,
                                                                  progress: serverProgress)
            }
            // Newer server entry than the last seen + differing position →
            // another device wrote. Adopt. Also BACKWARDS (a deliberate rewind
            // there is intended). After our own write serverTime ≈ currentTime →
            // no jump. Fallback without lastUpdate (old servers): forward only as
            // before.
            let isNewer = serverUpdate > lastKnownServerUpdate
            // Own-echo guard: if the server holds a state WE gave it (the
            // last synced position, the flushed witness) or one we still
            // owe it (a queued update), it is not a foreign device.
            // Regardless of timestamps (server clocks can run ahead of the
            // device clock, and the known moment goes stale when the read
            // after a write fails in a dead spot).
            let flushedTime = ListeningStore.flushed(item.id)?.first
            let queuedTime = SyncQueue.shared.pendingUpdate(itemId: item.id)?.currentTime
            let ownEcho = SyncRules.isOwnServerEcho(serverTime: serverTime, lastSyncedTime: lastSyncedTime,
                                                    flushedTime: flushedTime, queuedTime: queuedTime)
            let adopt = !ownEcho && SyncRules.shouldAdoptServerState(
                serverTime: serverTime,
                serverUpdateMs: serverUpdate,
                lastKnownServerUpdateMs: lastKnownServerUpdate,
                currentTime: currentTime
            )
            // Every verdict leaves a line: a jump after a dead spot is
            // diagnosed from these numbers, not from the symptom.
            Logger.player.notice("RECONCILE item=\(item.id, privacy: .private(mask: .hash)) server=\(Int(serverTime)) local=\(Int(self.currentTime)) lastSynced=\(Int(self.lastSyncedTime)) flushed=\(Int(flushedTime ?? -1)) queued=\(Int(queuedTime ?? -1)) serverMs=\(Int(serverUpdate)) knownMs=\(Int(self.lastKnownServerUpdate)) own=\(ownEcho) adopt=\(adopt)")
            if adopt {
                await seek(to: serverTime, userInitiated: false)
                lastSyncedTime = serverTime
                showSourceHint(.serverAdopted)
            }
            // Also adopt the finished flag from the newer entry. E.g. marked
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
