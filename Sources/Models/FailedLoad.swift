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
    /// Whether a load failure stops playback with a hint: only when the
    /// failed item is the one playing, in the queue that plays now. A
    /// failure further down the queue waits for its turn, where the status
    /// of the current item is asked; a late word from a queue already
    /// replaced stops nothing.
    static func stopsPlayback(failedIndex: Int, currentIndex: Int, inCurrentQueue: Bool) -> Bool {
        inCurrentQueue && failedIndex == currentIndex
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
