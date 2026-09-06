// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE moment of a title, for the row that ranks it and the card that
/// names it.
///
/// There were two questions for one thing: the book card read the server's
/// stand alone, the episode card read the newer of local and server, and
/// the row ranked by a third mixture. Two clocks at one title put the same
/// book at two places and named two different times for it.
///
/// And a title that PLAYS is the newest thing there is: its stand is
/// written every thirty seconds, so between two writes a stand arriving
/// from the other device looked newer and pushed the running title down
/// the row.
nonisolated enum ListeningMoment {
    /// Stores stamp in milliseconds; a server or a seed may hand over
    /// seconds. A row ranking the two unnormalized puts every seconds
    /// entry last.
    static func normalizedMs(_ moment: Double) -> Double {
        guard moment > 0 else { return 0 }
        return moment < 100_000_000_000 ? moment * 1000 : moment
    }

    /// The moment of a title: the newer of the two stands, and `now` while
    /// it plays (here or on the other device).
    static func of(local: Double, server: Double, playingNowMs: Double? = nil) -> Double {
        let stands = max(normalizedMs(local), normalizedMs(server))
        guard let playing = playingNowMs else { return stands }
        return max(stands, playing)
    }

    /// What a card says under the title.
    enum Label: Equatable {
        /// It plays right now: a relative time would count up while it runs.
        case playing
        /// Epoch ms of the last stand, for the relative time.
        case at(Double)
        /// Nothing known, nothing claimed.
        case none
    }

    static func label(local: Double, server: Double, playingNowMs: Double?) -> Label {
        if playingNowMs != nil { return .playing }
        let moment = of(local: local, server: server)
        return moment > 0 ? .at(moment) : .none
    }
}
