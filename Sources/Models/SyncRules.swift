// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Pure, stateless decision rules of the sync core — extracted here so they are
/// unit-testable without player/network/file system. Behaviour is identical to
/// the former inline versions in PlayerViewModel/SyncQueue. `nonisolated`: pure
/// Foundation logic, callable from background/test contexts under the project's
/// default MainActor isolation.
nonisolated enum SyncRules {

    /// 8b71fd7: may the player write a podcast's LOCAL state (localPosition +
    /// gpodder push)?
    ///
    /// The reviver, measured on the owner's "Rest is History" episode: restoring
    /// a loaded episode flushed the RESTORED state immediately — position
    /// 21:09 written with a FRESH timestamp, locally and to gpodder, on every
    /// app start of whichever device still held the episode. The finished
    /// mark (both roads: listening to the end AND marking by hand) was made
    /// on another pass, so the freshly-stamped old position outvoted it on
    /// every sync — twice, which is what turned "a mark got lost" into "a
    /// reviver keeps striking".
    ///
    /// The rule is the Winterfell rule, one layer up: **the restore is a
    /// witness of LOADING, not of LISTENING.** A state may only be written
    /// when something actually happened — playback, a deliberate restart, or
    /// a deliberate seek. Merely holding an episode in the player is not an
    /// event, and writing it re-stamps old knowledge as new.
    static func mayWritePodcastLocalState(playedSinceLoad: Bool,
                                          deliberateRestart: Bool,
                                          deliberateSeek: Bool) -> Bool {
        playedSinceLoad || deliberateRestart || deliberateSeek
    }


    /// GT 09.08.: „finished" is DERIVED from the position, at exactly one
    /// place. That is what makes „mark as heard" safe on a running item:
    /// `finalizeAsFinished()` moves the position to the end, so the stop's
    /// final sync writes `finished` — never the old position behind it.
    /// One second of tolerance because the last tick rarely lands exactly on
    /// the duration.
    static func isFinished(currentTime: Double, duration: Double) -> Bool {
        duration > 0 && currentTime >= duration - 1   // progress-fence: server payload
    }

    /// Device reconcile: adopt the server state?
    /// With timestamp: newer entry + noticeable difference (also backwards).
    /// Without timestamp (old servers): forward only.
    static func shouldAdoptServerState(
        serverTime: Double,
        serverUpdateMs: Double,
        lastKnownServerUpdateMs: Double,
        currentTime: Double,
        tolerance: Double = 5
    ) -> Bool {
        if serverUpdateMs > 0 {
            return serverUpdateMs > lastKnownServerUpdateMs
                && abs(serverTime - currentTime) > tolerance
        }
        return serverTime > currentTime + tolerance
    }

    /// Device reconcile: is the server entry (within tolerance) exactly the
    /// state WE last wrote? A reconcile must not mistake our own echo for a
    /// foreign device — server clocks can run ahead of the device clock, so a
    /// pure timestamp comparison is not enough after an offline stretch.
    static func isOwnServerEcho(
        serverTime: Double,
        lastSyncedTime: Double,
        tolerance: Double = 5
    ) -> Bool {
        abs(serverTime - lastSyncedTime) <= tolerance
    }

    /// Queue flush: drop a pending update because the server is now further
    /// ahead? isFinished updates are status decisions and are never dropped.
    static func shouldDropQueuedUpdate(
        queuedTime: Double,
        queuedIsFinished: Bool,
        duration: Double,
        serverFraction: Double?,
        tolerance: Double = 5
    ) -> Bool {
        guard !queuedIsFinished, duration > 0, let fraction = serverFraction else { return false }
        return fraction * duration > queuedTime + tolerance
    }

    /// Crash safety: use the local tick backup instead of the server state?
    /// Only if it is NEWER than the server entry and differs noticeably.
    static func shouldRestoreLocalPosition(
        savedTime: Double,
        savedAtMs: Double,
        serverTime: Double,
        serverUpdateMs: Double,
        tolerance: Double = 5
    ) -> Bool {
        savedAtMs > serverUpdateMs && abs(savedTime - serverTime) > tolerance
    }

    /// c59e96e — the FLUSHED witness: what this device last pushed to the
    /// server successfully. It is the start source whenever the server has
    /// nothing better to say: no answer at all (offline), an answer that
    /// arrived after the reconcile window, or an answer without a progress
    /// entry. Measured: without it a downloaded book has NO local source —
    /// the crash backup is deleted after every successful sync and the cached
    /// detail carries the download-time state forever — so it starts at 0.
    ///
    /// Deliberately NOT a crash-restore candidate (`shouldRestoreLocalPosition`
    /// stays untouched): that rule is for a value the server never saw, this
    /// one for a value the server already had. Keeping them apart is what
    /// stops the flushed value from resurrecting against a NEWER foreign
    /// device — the timestamp comparison below is the whole guard.
    static func shouldPreferFlushedWitness(
        flushedTime: Double,
        flushedAtMs: Double,
        serverTime: Double,
        serverUpdateMs: Double,
        tolerance: Double = 5
    ) -> Bool {
        guard flushedTime > 0 else { return false }
        // The server said nothing datable — ours is the only witness there is.
        if serverUpdateMs <= 0 { return true }
        // Another device may legitimately be ahead: only a NEWER own push,
        // and only a noticeably higher one, beats the server's answer.
        return flushedAtMs > serverUpdateMs && flushedTime > serverTime + tolerance
    }

    /// 5f4fdee — the stomp window. In a FRESH session `lastSyncedTime` is 0,
    /// so the suspicious-drop guard has no reference: if the start found no
    /// source at all (no witness, no local backup, no server answer yet) and
    /// somebody presses play at 00:00, the next periodic sync pushes that
    /// near-zero value and OVERWRITES a server that was hours ahead. That is
    /// the measured Winterfell afternoon pattern, now understood as mechanics.
    ///
    /// So a push needs a start that was ANSWERED — by any source. Until then
    /// the device only listens. A resolved start pushes as before; this rule
    /// never delays a normal session, because a normal session resolves at
    /// load time.
    /// No tolerance escape on purpose: my first draft let an unresolved start
    /// push once it had played past 5 s — which is exactly the stomp it is
    /// supposed to prevent, only five seconds later. A brand-new book is not
    /// blocked by this, because "the server answered, and it knows nothing"
    /// RESOLVES the start just as much as an adopted position does.
    static func mayPushProgress(startSourceResolved: Bool) -> Bool {
        startSourceResolved
    }

    /// A non-user-initiated backward jump considered suspicious?
    static func isSuspiciousDrop(
        currentTime: Double,
        lastSyncedTime: Double,
        threshold: Double
    ) -> Bool {
        currentTime < lastSyncedTime - threshold
    }
}

/// Multi-file time math: absolute book time ↔ track index. Pure and
/// unit-testable; PlayerViewModel delegates here.
/// `nonisolated`: pure track-offset math, callable from background/nonisolated
/// contexts (e.g. ChapterModel's track fallback).
nonisolated enum TrackMath {

    /// Cumulative start time of a track: startOffset from the server, else the
    /// sum of the individual durations. Out of range: book duration.
    static func trackStart(index: Int, tracks: [ABSAudioTrack], bookDuration: Double) -> Double {
        guard index >= 0, index < tracks.count else { return bookDuration }
        if let offset = tracks[index].startOffset { return offset }
        return tracks[..<index].reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// Track that an absolute book time falls into (last track catches the rest).
    static func trackIndex(for absoluteTime: Double, tracks: [ABSAudioTrack], bookDuration: Double) -> Int {
        for index in tracks.indices {
            let start = trackStart(index: index, tracks: tracks, bookDuration: bookDuration)
            let end = start + (tracks[index].duration ?? 0)
            if absoluteTime < end || index == tracks.count - 1 {
                return index
            }
        }
        return 0
    }
}
