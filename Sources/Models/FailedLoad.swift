// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a load failure of a queued item decides. An item whose asset never
/// loads (no network, a dead address) stays failed for good: the player does
/// not try it again, and setting a rate on it plays nothing. Only a new
/// queue plays, so these rules say when the queue is built again.
nonisolated enum FailedLoad {
    /// Whether a load failure stops playback with a hint now: only when the
    /// failed item is the one playing, in the queue that plays now; a late
    /// word from a queue already replaced stops nothing.
    static func stopsPlayback(failedIndex: Int, currentIndex: Int, inCurrentQueue: Bool) -> Bool {
        inCurrentQueue && failedIndex == currentIndex
    }

    /// Whether a load failure further down the queue becomes the point where
    /// playback holds. The queue would never ask it: measured, it skips a
    /// failed item when the one before ends and plays the next file, so the
    /// position jumped a whole file. The queue is cut before the failed
    /// track, and playback stops at its start when the track before ends.
    /// An earlier held point stays: the queue already ends before it.
    static func holdsAhead(failedIndex: Int, currentIndex: Int, inCurrentQueue: Bool,
                           heldAt held: Int?) -> Bool {
        guard inCurrentQueue, failedIndex > currentIndex else { return false }
        return held.map { failedIndex < $0 } ?? true
    }

    /// What a load failure does when the track may have come from a local
    /// file. Measured: a missing or broken local file fails to load and
    /// never fires FailedToPlayToEndTime, so every play built the same file
    /// again and the hint blamed the network.
    enum LocalFallback: Equatable {
        /// Not a local file: the rules above decide as for any item.
        case none
        /// The file is dropped and fetched again in the background; the
        /// track plays on from the server at the same place.
        case stream
        /// Playback stops with the hint that the track is unavailable.
        case unavailable
    }

    /// Only a local file falls back. One attempt per track: a local file
    /// that already had it is unavailable, so is one without network; with
    /// network it streams instead. A streamed track keeps the network rules
    /// after its attempt, because in a dead spot the network is the cause.
    static func localFallback(fromLocalFile: Bool, retried: Bool, online: Bool) -> LocalFallback {
        guard fromLocalFile else { return .none }
        if retried || !online { return .unavailable }
        return .stream
    }

    /// Whether a play builds the queue anew before it starts: the current
    /// item failed to load, or a stopped failure was not healed yet. The
    /// queue drops a failed item (measured: no current item right after
    /// the failure), so the noted mark carries the case; the status covers
    /// a failed item still in place.
    static func rebuildsBeforePlay(currentItemFailed: Bool, noted: Bool) -> Bool {
        currentItemFailed || noted
    }

    /// Whether a changed network path builds the queue anew, without
    /// starting playback: a stopped failure waits and the path carries again.
    static func rebuildsOnPathChange(noted: Bool, satisfied: Bool) -> Bool {
        noted && satisfied
    }
}
