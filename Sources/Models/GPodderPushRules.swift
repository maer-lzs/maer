// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The two rules of pushing a listening position to gpodder, pure.
///
/// Both used to live inside the runner, where nothing drove them: the
/// real-time throttle was marked BEFORE the push went out, so a push that
/// failed still ate the window of the next one, and the batch cursor was
/// set to the moment of writing it, so a position written between
/// gathering the batch and moving the cursor was never `> cursor` and never
/// sent. gpodder had no witness for positions at all until these existed.
nonisolated enum GPodderPushRules {
    /// The real-time push's coalescing: rapid ticks and seeks of ONE
    /// episode collapse into one push per window, unless the position moved
    /// noticeably. A mark is made when a push is attempted and TAKEN BACK
    /// when it fails, so a failed push frees the window instead of eating
    /// it; a success keeps the mark.
    nonisolated struct Throttle: Equatable, Sendable {
        var windowMs: Double = 8_000
        var minimumDelta: Int = 5
        private(set) var marks: [String: Mark] = [:]

        nonisolated struct Mark: Equatable, Sendable {
            var position: Int
            var atMs: Double
        }

        init(windowMs: Double = 8_000, minimumDelta: Int = 5) {
            self.windowMs = windowMs
            self.minimumDelta = minimumDelta
        }

        /// Whether a push for this episode at this position goes out now.
        func shouldPush(_ id: String, position: Int, nowMs: Double) -> Bool {
            guard let last = marks[id] else { return true }
            return nowMs - last.atMs >= windowMs || abs(position - last.position) >= minimumDelta
        }

        /// A push is on its way: from now on the window is taken.
        mutating func noteAttempt(_ id: String, position: Int, nowMs: Double) {
            marks[id] = Mark(position: position, atMs: nowMs)
        }

        /// The push did not land. Only the mark of THAT attempt is taken
        /// back: a newer attempt for the same episode keeps its own.
        mutating func noteFailure(_ id: String, position: Int, nowMs: Double) {
            guard marks[id] == Mark(position: position, atMs: nowMs) else { return }
            marks[id] = nil
        }
    }

    /// Whether a stored entry belongs in the batch after the cursor. The
    /// entry's moment is in milliseconds, the cursor in seconds, as the two
    /// stores keep them.
    static func isAfterCursor(entryMs: Double, cursorSeconds: Double) -> Bool {
        entryMs / 1000 > cursorSeconds
    }

    /// Where the cursor goes after a batch went out: to the moment the
    /// batch was GATHERED, never to the moment of writing the cursor. An
    /// entry written between the two is then still after the cursor and
    /// goes out with the next batch, at worst twice, never not at all.
    static func cursorAfterPush(gatheredAtSeconds: Double) -> Double {
        gatheredAtSeconds
    }
}
