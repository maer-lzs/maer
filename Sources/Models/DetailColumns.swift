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
        return max(min(columnWidth, minimum), min(columnWidth, fitsHeight))
    }
}

/// The two buttons under the main one (download, mark as heard) stand side
/// by side only where both fit whole; in a narrower column one under the
/// other, never cut or wrapped. From the width, not from trying.
nonisolated enum DetailButtonRow {
    /// Two buttons of the longest German label (about 170 pt each) and the
    /// gap between them.
    static let sideBySideMinWidth: CGFloat = 360

    static func stacked(width: CGFloat) -> Bool { width < sideBySideMinWidth }
}
