// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One gpodder round at a time, and an occasion that comes while one runs
/// is not dropped: it is noted, and the end of the round reads the note in
/// the same step as it opens the gate, so nothing falls between the two
/// (the lost wake the shared core found in its first form of this rule).
nonisolated struct GPodderRoundGate: Equatable, Sendable {
    private var running = false
    private var askedAgain = false

    /// true: this occasion starts a round. false: one runs; it is noted.
    mutating func begin() -> Bool {
        guard !running else { askedAgain = true; return false }
        running = true
        return true
    }

    /// Ends the round; true when an occasion came during it and one more
    /// round is due.
    mutating func end() -> Bool {
        running = false
        defer { askedAgain = false }
        return askedAgain
    }
}
