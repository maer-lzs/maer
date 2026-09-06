// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What the progress bar spans. A book is one work and its bar is the
/// work: that is how an audiobook is listened to. Music follows the
/// convention of every music player instead: the bar is the SONG, with
/// the song's elapsed and remaining time, and dragging moves inside the
/// song.
///
/// An album is one item with several tracks here, so the song is a
/// chapter of it. The rule turns the player's absolute time into the
/// song's own, and back for a seek.
nonisolated enum ScrubberSpan: Equatable {
    /// Start and end of the span in the item's absolute seconds.
    case span(start: Double, end: Double)

    /// The span for the player's state. `isMusic` is the ONE form
    /// question; without a current song (a single track, a stream) music
    /// spans the whole item like everything else.
    static func of(isMusic: Bool, chapterStart: Double?, chapterEnd: Double?,
                   duration: Double) -> ScrubberSpan {
        let whole = ScrubberSpan.span(start: 0, end: max(duration, 1))
        guard isMusic, let start = chapterStart, let end = chapterEnd, end > start else { return whole }
        return .span(start: start, end: min(end, max(duration, end)))
    }

    var start: Double { if case .span(let start, _) = self { return start } else { return 0 } }
    var end: Double { if case .span(_, let end) = self { return end } else { return 1 } }
    /// The length of the span, never zero (a slider needs a range).
    var length: Double { max(end - start, 1) }

    /// The absolute time as a position inside the span, clamped.
    func position(absolute: Double) -> Double {
        min(max(absolute - start, 0), length)
    }

    /// A position inside the span as the absolute time to seek to.
    func absolute(position: Double) -> Double {
        start + min(max(position, 0), length)
    }

    /// What the two labels under the bar say: elapsed inside the span, and
    /// what is left of it.
    func elapsed(absolute: Double) -> Double { position(absolute: absolute) }
    func remaining(absolute: Double) -> Double { max(length - position(absolute: absolute), 0) }
}
