// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When a failed lookup may be asked again.
///
/// A failure is no knowledge, so it is never kept as an answer. But asking
/// again at once turned into a loop: measured on 20.09.2026, the same old-time
/// radio id was asked six times, every answer `fetch-failed`, one of them
/// after 64 seconds. The rule keeps both: nothing is written down as a
/// result, and the next question waits.
nonisolated enum FetchHoldback {
    /// Ten minutes in the session. Long enough that a scroll back and forth
    /// over the same shelf does not ask again, short enough that a dead spot
    /// on the move is forgotten by the next time the shelf is opened.
    static let seconds: TimeInterval = 600

    /// Whether an ended lookup starts a holdback. A cancellation is no event
    /// (asked again at once), and "gone" is a finding the dead-item list
    /// records, not a failure. Everything else is: a timeout, a refusal, a
    /// server error, an answer that does not decode.
    static func starts(after error: Error) -> Bool {
        if error.isCancellation { return false }
        if FreeCatalog.isGone(error) { return false }
        return true
    }

    /// Whether a lookup may be asked now, after a failure at `failedAt`.
    static func mayAsk(failedAt: Date?, now: Date, holdback: TimeInterval = seconds) -> Bool {
        guard let failedAt else { return true }
        return now.timeIntervalSince(failedAt) >= holdback
    }
}

/// The answer of a lookup refused during its holdback. A failure to the
/// caller, without a network question.
nonisolated struct FetchHeldBack: Error {}
