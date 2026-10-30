// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// 🔴 The opening GENERATION for `PlayerCoordinator.open`. The rule
/// that keeps hammering play on a bad connection from producing two audio
/// tracks.
///
/// The device case: every tap ran into the network timeouts, and when the
/// connection returned SEVERAL calls came back, each building a player and
/// starting it. A `stop()` at the top of `open` cannot help. The racers are
/// long past it. So each call draws a mark here and asks after every await
/// whether it is still the current one; a stale return cleans itself up.
///
/// Pure and separate from the coordinator on purpose: the coordinator's
/// `open` resolves its provider through `AppSession`, which a unit test
/// cannot substitute. The RULE, however, is exactly what must not break.
struct OpenGate {
    private(set) var current = 0
    /// The item a still-running open() is working on.
    private(set) var openingItemId: String?
    /// A call that coalesced into the running open asked to play. The
    /// running open then plays when it stands, also when it began without
    /// playing (a restore, a mirror); otherwise the wish vanishes with the
    /// coalesced call.
    private(set) var playAsked = false

    /// Draw a generation. Returns nil when this call coalesces into a
    /// running attempt for the SAME item (an explicit restart never
    /// coalesces. It must reload from the start); its wish to play stays
    /// with the running attempt.
    mutating func begin(itemId: String, restart: Bool, autoplay: Bool = false) -> Int? {
        if !restart, openingItemId == itemId {
            if autoplay { playAsked = true }
            return nil
        }
        current &+= 1
        openingItemId = itemId
        playAsked = false
        return current
    }

    /// Is this generation still the current one? Everything after an await
    /// asks this.
    func isCurrent(_ generation: Int) -> Bool { generation == current }

    /// Whether a call that coalesced into this generation asked to play.
    func playWasAsked(_ generation: Int) -> Bool { generation == current && playAsked }

    /// Release the "in flight" marker. But only if no NEWER call has taken
    /// over in the meantime (otherwise the newer one would lose its
    /// coalescing protection).
    mutating func finish(_ generation: Int) {
        guard generation == current else { return }
        openingItemId = nil
    }
}
