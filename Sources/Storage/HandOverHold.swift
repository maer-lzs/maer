// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A hand-over of a log to an account that could not happen yet (rows or a
/// document unread, a rest not laid), and what was written down meanwhile.
/// The log tries the hand-over again before its next entry and at every
/// change of way (`retry`); an entry that comes while it holds waits here,
/// out of the holder's log, and comes back in order once the log belongs to
/// the account it was made under (`handedOver`).
///
/// One shape for every log that follows the account (`PodcastListenLog`,
/// `PlaybackNotices`): `Pending` is what one waits with (a note to run
/// again, a line to add).
nonisolated struct HandOverHold<Pending> {
    /// The account the hand-over is for and the owner before it.
    private(set) var target: (scope: String, previous: String?)?
    private(set) var waiting: [Pending] = []

    var isHeld: Bool { target != nil }

    /// The hand-over could not happen: it is held for `scope`.
    mutating func hold(scope: String, previous: String?) {
        target = (scope, previous)
    }

    /// The hand-over happened: no hold, and what waited for it, in order.
    mutating func handedOver() -> [Pending] {
        target = nil
        let released = waiting
        waiting = []
        return released
    }

    /// Keeps `item` for after a held hand-over; false when none is held, and
    /// the item goes into the log now.
    mutating func keep(_ item: Pending) -> Bool {
        guard target != nil else { return false }
        waiting.append(item)
        return true
    }
}
