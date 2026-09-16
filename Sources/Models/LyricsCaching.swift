// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// May a "this song has no lyrics" be written down?
///
/// The lyrics cache keeps negatives for sixty days, on disk and in memory,
/// so a no costs two months. Until now every way to end up without lyrics
/// produced the same nil: a source that answered "there are none", a
/// source that refused (LRCLIB answers 429 to a series of questions), and
/// a device that was offline and could ask nobody. All three were booked
/// the same way.
///
/// The rule is the one the feed artwork already follows: only a source
/// that ANSWERED may say "none". A failure says nothing about the song.
nonisolated enum LyricsCaching {
    /// What one source did when it was consulted.
    enum Outcome: Equatable {
        /// It answered, with lyrics or with "there are none".
        case answered
        /// It refused, timed out, or could not be reached. This says
        /// nothing about the song.
        case failed
        /// It was not consulted at all. Either the person turned the
        /// online lookup off, or a previous source already had lyrics.
        /// Not a finding and not a failure.
        case notAsked
    }

    /// A negative is written down only when nothing failed and at least
    /// one source really answered.
    ///
    /// Both halves matter. Without the first, a refusal becomes a no for
    /// sixty days. Without the second, a round in which nobody was asked
    /// (offline, and the device has no server either) would book a no that
    /// no one ever said.
    static func mayRemember(_ outcomes: [Outcome]) -> Bool {
        !outcomes.contains(.failed) && outcomes.contains(.answered)
    }
}
