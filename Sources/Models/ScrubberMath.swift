// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The arithmetic behind the hand built scrubber, pure so a witness can drive
/// it at its edges.
///
/// It lived as three private members of the view, where nothing could reach
/// it. That is rule 1 done by halves: the branch that decides WHETHER the
/// hand built control appears was pure and tested, while the part that can
/// actually be wrong was not.
///
/// Each of the three clamps, and one of them divides. The division used to
/// be safe only because the caller wrote `max(geo.size.width, 1)` before
/// calling it, which is a promise about every future caller rather than a
/// property of the thing itself.
nonisolated enum ScrubberMath {
    /// How far along the range a value sits, between 0 and 1.
    ///
    /// An empty or inverted range answers 0 rather than dividing: a track of
    /// no length has no position along it, and the alternative is a NaN that
    /// travels into a frame width and takes the layout with it.
    static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// The value under a horizontal touch at `x` on a track of `width`.
    ///
    /// The guard on the width lives HERE and not at the call site. It is the
    /// same guard either way, but only in this seat is it a property of the
    /// calculation instead of a habit of whoever calls it.
    static func value(atX x: Double, width: Double, in range: ClosedRange<Double>) -> Double {
        guard width > 0 else { return range.lowerBound }
        let share = min(max(x / width, 0), 1)
        return range.lowerBound + share * (range.upperBound - range.lowerBound)
    }

    /// One step of the accessibility adjustable action: a twentieth of the
    /// range, and never less than a second.
    ///
    /// The floor is what makes it usable on a short track, where a twentieth
    /// would be a fraction of a second and the control would feel dead to
    /// somebody stepping through it.
    static func step(in range: ClosedRange<Double>) -> Double {
        max((range.upperBound - range.lowerBound) / 20, 1)
    }

    /// Where one step of the adjustable action lands, clamped to the range.
    static func stepped(from value: Double, in range: ClosedRange<Double>,
                        increasing: Bool) -> Double {
        let next = increasing ? value + step(in: range) : value - step(in: range)
        return min(max(next, range.lowerBound), range.upperBound)
    }
}
