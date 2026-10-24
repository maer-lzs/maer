// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Where a detail page in two columns divides: at the fold the system names
/// (`UIView.reservedRegions(kind: .division)`, the open iPhone Duo), else at
/// the middle of the display. The leading column ends before the fold, the
/// trailing one begins after it, nothing lies over it. All in window points.
nonisolated enum FoldSplit {
    struct Columns: Equatable {
        var leading: CGFloat
        var gap: CGFloat
        var trailing: CGFloat
    }

    /// The columns of a page that spans `contentMinX` to `contentMinX +
    /// contentWidth` in the window: a side column the page leaves free makes
    /// the trailing column narrower, never the leading one.
    static func columns(contentMinX: CGFloat, contentWidth: CGFloat, fold: ClosedRange<CGFloat>?,
                        windowWidth: CGFloat) -> Columns {
        let middle = windowWidth > 0 ? windowWidth / 2 : contentMinX + contentWidth / 2
        let band = fold ?? middle...middle
        let maxX = contentMinX + contentWidth
        let lower = min(max(band.lowerBound, contentMinX), maxX)
        let upper = min(max(band.upperBound, lower), maxX)
        return Columns(leading: lower - contentMinX, gap: upper - lower, trailing: maxX - upper)
    }
}

/// How large a detail page's cover is: as large as its column allows, and
/// small enough that what stands under it down to the main button (title,
/// facts, play) stays above the playback bar without scrolling. Never under
/// `minimum`, where a cover stops being one.
nonisolated enum DetailCoverSide {
    static let minimum: CGFloat = 160

    static func side(columnWidth: CGFloat, height: CGFloat, top: CGFloat, below: CGFloat,
                     bottomReserve: CGFloat) -> CGFloat {
        let fitsHeight = height - top - below - bottomReserve
        // Whole points: a fraction lands on another pixel than asked, the
        // measured distance below moves by it, and the side with it.
        return max(min(columnWidth, minimum), min(columnWidth, fitsHeight)).rounded(.down)
    }

    /// What the page keeps as the height below the cover, from a new
    /// measurement: the measurement depends on where the cover lands, and
    /// pixel rounding moves it by a fraction each pass (measured: the page
    /// re-rendered without end, 100 % CPU). A change under one point is kept
    /// out, so the cover settles after a finite number of passes.
    static func settled(_ kept: CGFloat, measured: CGFloat) -> CGFloat {
        abs(measured - kept) < 1 ? kept : measured.rounded()
    }
}

/// The two buttons under the main one (download, mark as heard) stand side
/// by side only where both fit whole; in a narrower column one under the
/// other, never cut or wrapped. From the width, not from trying; the page
/// scales the need with the type size.
nonisolated enum DetailButtonRow {
    /// Two buttons of the longest German label (about 170 pt each) and the
    /// gap between them, at the standard type size.
    static let sideBySideMinWidth: CGFloat = 360

    /// `needs`: the width both take at the current type size (the page's
    /// `@ScaledMetric` of `sideBySideMinWidth`).
    static func stacked(width: CGFloat, needs: CGFloat) -> Bool { width < needs }
}
