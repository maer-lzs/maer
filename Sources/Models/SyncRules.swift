// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Pure, stateless decision rules of the sync core. Extracted here so they are
/// unit-testable without player/network/file system. Behaviour is identical to
/// the former inline versions in PlayerViewModel/SyncQueue. `nonisolated`: pure
/// Foundation logic, callable from background/test contexts under the project's
/// default MainActor isolation.
nonisolated enum SyncRules {

    /// Whether the answer to a mark sent while the person waits is a refusal
    /// with a sentence instead of a queued write: the title is not there
    /// (404, 410) or the write was forbidden (403). The person sees it and
    /// can mark again, so nothing is lost in silence. 401 is the access and
    /// stays queued for after the next sign-in.
    static func refusesTheMark(status: Int) -> Bool {
        switch StatusMeaning.from(status: status) {
        case .notFound: return true
        // 401 asks for the access again, 403 forbids this write.
        case .signIn: return status == 403
        case .throttled, .server: return false
        }
    }

    /// Whether the queue drops a waiting write after this answer: only when
    /// the host said the title is not there. A 403 can come from in front of
    /// the server (a proxy rule, a block on this network) and says nothing
    /// about the title, so the entry waits for the next flush like a 401.
    static func queueDrops(status: Int) -> Bool {
        StatusMeaning.from(status: status).isAbsence
    }

    /// May the player write a podcast's LOCAL state (localPosition +
    /// gpodder push)?
    ///
    /// The reviver, measured on the user' "Rest is History" episode: restoring
    /// a loaded episode flushed the RESTORED state immediately. Position
    /// 21:09 written with a FRESH timestamp, locally and to gpodder, on every
    /// app start of whichever device still held the episode. The finished
    /// mark (both roads: listening to the end AND marking by hand) was made
    /// on another pass, so the freshly-stamped old position outvoted it on
    /// every sync. Twice, which is what turned "a mark got lost" into "a
    /// reviver keeps striking".
    ///
    /// The rule is the Winterfell rule, one layer up: **the restore is a
    /// witness of LOADING, not of LISTENING.** A state may only be written
    /// when something actually happened. Playback, a deliberate restart, or
    /// a deliberate seek. Merely holding an episode in the player is not an
    /// event, and writing it re-stamps old knowledge as new.
    static func mayWritePodcastLocalState(playedSinceLoad: Bool,
                                          deliberateRestart: Bool,
                                          deliberateSeek: Bool) -> Bool {
        playedSinceLoad || deliberateRestart || deliberateSeek
    }


    /// `finished` is DERIVED from the position, at exactly one place. That
    /// is what makes marking a running item as heard safe:
    /// `finalizeAsFinished()` moves the position to the end, so the stop's
    /// final sync writes `finished`. Never the old position behind it.
    /// One second of tolerance because the last tick rarely lands exactly on
    /// the duration.
    static func isFinished(currentTime: Double, duration: Double) -> Bool {
        // The TRUE end, never the person's "counts as played" choice: a
        // server learns "finished" at the end, as before.
        ProgressMark.reachedEnd(position: currentTime, duration: duration)
    }

    /// How the stand in the local store relates to the player's own before
    /// it plays on. `ownStandMs` is the moment of the player's own stand of
    /// the loaded item (its last own write or its pause), nil while it has
    /// not listened since the load.
    enum StoredStand: Equatable {
        /// Within the tolerance of where the player stands.
        case same
        /// Stamped at or before the player's own stand: it never moves it.
        case older
        /// Stamped after it, so another device wrote it: the player moves.
        case newer
    }

    static func storedStand(position: Double, atMs: Double, ownStandMs: Double?,
                            currentTime: Double, tolerance: Double = 2) -> StoredStand {
        guard abs(position - currentTime) > tolerance else { return .same }
        guard let ownStandMs else { return .newer }
        return atMs > ownStandMs ? .newer : .older
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

    /// Device reconcile: is the server entry (within tolerance) a state WE
    /// gave it, or one we are about to give it? A reconcile must not mistake
    /// our own echo for a foreign device. Server clocks can run ahead of the
    /// device clock, so a pure timestamp comparison is not enough after an
    /// offline stretch. Three own states count: the last synced position
    /// (which the queue moves on while offline, for the conflict rule), the
    /// last position the server actually took from us (`flushedTime`, the
    /// flushed witness), and a position still queued for the server
    /// (`queuedTime`): a server that is not ahead of our queued write holds
    /// what we knew before the dead spot, never another device's play.
    /// Measured: after a dead spot the server held the write from
    /// thirty seconds before, `lastSyncedTime` had moved on with the queue,
    /// and the reconcile rewound the listener by that much.
    static func isOwnServerEcho(
        serverTime: Double,
        lastSyncedTime: Double,
        flushedTime: Double? = nil,
        queuedTime: Double? = nil,
        tolerance: Double = 5
    ) -> Bool {
        if abs(serverTime - lastSyncedTime) <= tolerance { return true }
        if let flushedTime, abs(serverTime - flushedTime) <= tolerance { return true }
        if let queuedTime, serverTime <= queuedTime + tolerance { return true }
        return false
    }

    /// What a queue flush does with a pending update, and whether the
    /// library shows it over the server state.
    enum QueuedFate: Equatable {
        /// Goes out: the server has nothing further ahead.
        case send
        /// Leaves the queue unsent: the server is further ahead.
        case drop
        /// Stays queued unsent: the server has an entry whose position is
        /// unknown. It ends when the server names a position or a newer write
        /// of the title replaces the entry.
        case hold
    }

    /// The server's position is its `currentTime`; only without one the
    /// fraction over the queued duration. The fraction alone can be stale: a
    /// write without a known duration sends no fraction, so the server keeps
    /// the old one while its time moves on. A finished update is a status
    /// decision and always goes out; without a server entry there is nothing
    /// to overwrite.
    static func queuedFate(
        queuedTime: Double,
        queuedIsFinished: Bool,
        duration: Double,
        server: BookProgress?,
        tolerance: Double = 5
    ) -> QueuedFate {
        guard !queuedIsFinished, let server else { return .send }
        guard let serverTime = server.currentTime ?? (duration > 0 ? server.fraction * duration : nil)
        else { return .hold }
        return serverTime > queuedTime + tolerance ? .drop : .send
    }

    /// A landed write retires the queued stand of the same title only when
    /// that stand is not newer than the one written: queued at or before the
    /// written stand's moment, or at the same position. A newer queued stand
    /// stays for its own flush; newer by time, not by a larger position, so a
    /// rewind is newer too. An entry from before the queue kept its moment
    /// carries none and goes, as it always did.
    static func writeRetiresQueued(queuedAtMs: Double?, queuedTime: Double,
                                   writtenAtMs: Double, writtenTime: Double) -> Bool {
        guard let queuedAtMs else { return true }
        return queuedAtMs <= writtenAtMs || abs(queuedTime - writtenTime) < 0.5
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

    /// The FLUSHED witness: what this device last pushed to the
    /// server successfully. It is the start source whenever the server has
    /// nothing better to say: no answer at all (offline), an answer that
    /// arrived after the reconcile window, or an answer without a progress
    /// entry. Measured: without it a downloaded book has NO local source.
    /// The crash backup is deleted after every successful sync and the cached
    /// detail carries the download-time state forever. So it starts at 0.
    ///
    /// Deliberately NOT a crash-restore candidate (`shouldRestoreLocalPosition`
    /// stays untouched): that rule is for a value the server never saw, this
    /// one for a value the server already had. Keeping them apart is what
    /// stops the flushed value from resurrecting against a NEWER foreign
    /// device. The timestamp comparison below is the whole guard.
    static func shouldPreferFlushedWitness(
        flushedTime: Double,
        flushedAtMs: Double,
        serverTime: Double,
        serverUpdateMs: Double,
        tolerance: Double = 5
    ) -> Bool {
        guard flushedTime > 0 else { return false }
        // The server said nothing datable. Ours is the only witness there is.
        if serverUpdateMs <= 0 { return true }
        // Another device may legitimately be ahead: only a NEWER own push,
        // and only a noticeably higher one, beats the server's answer.
        return flushedAtMs > serverUpdateMs && flushedTime > serverTime + tolerance
    }

    /// The stomp window. In a FRESH session `lastSyncedTime` is 0,
    /// so the suspicious-drop guard has no reference: if the start found no
    /// source at all (no witness, no local backup, no server answer yet) and
    /// somebody presses play at 00:00, the next periodic sync pushes that
    /// near-zero value and OVERWRITES a server that was hours ahead. That is
    /// the measured overwrite pattern, now understood as mechanics.
    ///
    /// So a push needs a start that was ANSWERED. By any source. Until then
    /// the device only listens. A resolved start pushes as before; this rule
    /// never delays a normal session, because a normal session resolves at
    /// load time.
    /// No tolerance escape on purpose: letting an unresolved start push once
    /// it has played past 5 s is exactly the stomp this prevents, only five
    /// seconds later. A brand-new book is not
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
