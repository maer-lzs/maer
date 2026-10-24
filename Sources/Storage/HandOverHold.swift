// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A hand-over of a log to an account that could not happen yet (rows or a
/// document unread, a rest not laid), and what was written down meanwhile.
/// The log tries the hand-over again before its next entry and at every
/// change of way (its `followIfHeld`); an entry that comes while it holds
/// waits here, out of the holder's log, with the account it was made under,
/// and comes back in order once the log belongs to THAT account
/// (`handedOver(to:)`). A hand-over to another account releases nothing of
/// it: what was heard under B never lands at C, it waits on for B.
///
/// One shape for every log that follows the account (`PodcastListenLog`,
/// `PlaybackNotices`, `ListenHistory`): `Pending` is what one waits with (a
/// note to run again, a line to add).
nonisolated struct HandOverHold<Pending> {
    /// The account the hand-over is for and the owner before it.
    private(set) var target: (scope: String, previous: String?)?
    /// What waits, in order, each with the account it was made under.
    private(set) var waiting: [(scope: String, item: Pending)] = []

    var isHeld: Bool { target != nil }

    /// The hand-over could not happen: it is held for `scope`.
    mutating func hold(scope: String, previous: String?) {
        target = (scope, previous)
    }

    /// The hand-over to `scope` happened: no hold, and what waited for that
    /// account, in order. What waits for another account stays
    /// (`stillWaiting`), for a hand-over to its own.
    mutating func handedOver(to scope: String) -> (released: [Pending], stillWaiting: Int) {
        target = nil
        let released = waiting.filter { $0.scope == scope }.map(\.item)
        waiting.removeAll { $0.scope == scope }
        return (released, waiting.count)
    }

    /// Keeps `item` for after a held hand-over, under the account the hold
    /// is for; false when none is held, and the item goes into the log now.
    mutating func keep(_ item: Pending) -> Bool {
        guard let target else { return false }
        waiting.append((target.scope, item))
        return true
    }
}
