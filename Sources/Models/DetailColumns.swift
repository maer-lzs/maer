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

    /// How far the content of both columns stands from the fold.
    static let foldDistance: CGFloat = 24
    /// What a page in a column pads on its fold edge: the standard padding.
    /// The frame gives the rest up to `foldDistance`.
    static let pageGutter: CGFloat = 16

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

    /// How far a centred view in the leading column moves toward the fold
    /// to stand midway between the column's outer edge and the visible fold,
    /// the middle of the system's band: the column ends the frame's margin
    /// before the band, the band's inner half lies beyond it.
    static func shiftToFoldMiddle(fold: ClosedRange<CGFloat>) -> CGFloat {
        ((fold.upperBound - fold.lowerBound) / 2 + foldDistance - pageGutter) / 2
    }
}

/// How large a detail page's cover is: as large as its column allows and at
/// most `heightShare` of the page's height below the cover's top, never
/// under `minimum`, where a cover stops being one. Taken once from the
/// page's room (width and height), never from what stands under the cover,
/// so it does not change between the first frame and rest; what does not
/// fit lies under the playback bar and is reached by scrolling.
nonisolated enum DetailCoverSide {
    static let minimum: CGFloat = 160
    static let heightShare: CGFloat = 0.55

    static func side(columnWidth: CGFloat, height: CGFloat, top: CGFloat) -> CGFloat {
        let fitsHeight = (height - top) * heightShare
        return max(min(columnWidth, minimum), min(columnWidth, fitsHeight)).rounded(.down)
    }

    /// What a layout keeps as a measured height (the full player's
    /// controls), from a new measurement: the measurement depends on where
    /// the cover lands, and pixel rounding moves it by a fraction each pass,
    /// which unsettled re-renders the view without end. The kept height
    /// grows by a whole point at least and falls only by `shrinkStep` or
    /// more, so a swing smaller than that step comes to rest after finitely
    /// many passes; a new window starts it again from zero.
    static func settled(_ kept: CGFloat, measured: CGFloat) -> CGFloat {
        if measured >= kept + 1 { return measured.rounded(.up) }
        // A first layout pass can measure the block taller than it settles;
        // a clear drop is taken, a small swing not.
        if measured <= kept - shrinkStep { return measured.rounded(.up) }
        return kept
    }

    /// How far a measurement must fall below the kept height to lower it:
    /// above the swing of pixel rounding and wrapping, below a real change.
    static let shrinkStep: CGFloat = 8
}

/// The full player's drag handle, where it stands (without the side
/// column): just under the status bar, as the system's own sheets, a little
/// into the reserved top edge and never closer to the display's edge than
/// `minimumTop`. The cover begins `clearance` below it. In window points.
nonisolated enum PlayerGrabHandle {
    static let height: CGFloat = 5
    static let clearance: CGFloat = 12
    static let intoReservedEdge: CGFloat = 6
    static let minimumTop: CGFloat = 6

    static func top(topInset: CGFloat) -> CGFloat {
        max(minimumTop, topInset - intoReservedEdge)
    }

    static func coverTop(topInset: CGFloat) -> CGFloat {
        top(topInset: topInset) + height + clearance
    }
}

/// The full player fits one view in every posture and never scrolls: the
/// controls keep their height, the cover and the spacing give way. Where
/// the controls alone exceed the view (large type) that is reported, not
/// scrolled.
nonisolated enum PlayerFit {
    /// The cover upright: in the area the controls leave above them, as
    /// wide as the progress bar (`barWidth`) and never taller than the area,
    /// down to nothing.
    static func uprightCover(barWidth: CGFloat, areaHeight: CGFloat) -> CGFloat {
        max(0, min(barWidth, areaHeight)).rounded(.down)
    }

    /// The progress bar upright: as wide as the cover above it, one width
    /// for both; under `barMinimum` the cover has given way so far that the
    /// bar keeps its own room (nil).
    static func uprightBar(coverSide: CGFloat) -> CGFloat? {
        coverSide >= barMinimum ? coverSide : nil
    }

    static let barMinimum: CGFloat = 200

    /// The cover beside the controls (across, without a fold): its fixed
    /// side, smaller where the view's height leaves less.
    static func sideBySideCover(fixed: CGFloat, viewportHeight: CGFloat, margin: CGFloat) -> CGFloat {
        max(0, min(fixed, viewportHeight - 2 * margin)).rounded(.down)
    }

    static func controlsOverflow(controls: CGFloat, viewportHeight: CGFloat, margin: CGFloat) -> Bool {
        controls > viewportHeight - 2 * margin
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
    /// Two compact buttons (glyph and short word) and the gap between
    /// them, at the standard type size.
    static let compactMinWidth: CGFloat = 260

    /// `needs`: the width both take at the current type size (the page's
    /// `@ScaledMetric` of `sideBySideMinWidth`).
    static func stacked(width: CGFloat, needs: CGFloat) -> Bool { width < needs }

    enum Form: Equatable { case sideBySide, compact, stacked }

    /// Side by side with their full words where both fit, else side by
    /// side in their compact form, which leaves more height to the cover,
    /// else one under the other. `compactNeeds` scales like `needs`.
    static func form(width: CGFloat, needs: CGFloat, compactNeeds: CGFloat) -> Form {
        if !stacked(width: width, needs: needs) { return .sideBySide }
        return stacked(width: width, needs: compactNeeds) ? .stacked : .compact
    }
}

/// The cover of a detail page as a card: round corners and a shadow, `gap`
/// under the status bar and at its sides, also where the page's full width
/// would fit. Every page with a `DetailHeader` and the full player take the
/// card's look (`coverCard()`).
nonisolated enum DetailCoverCard {
    static let cornerRadius: CGFloat = 12
    static let gap: CGFloat = 16

    struct Form: Equatable {
        var side: CGFloat
        /// The room above the cover: the status bar and the gap.
        var top: CGFloat
    }

    static func form(width: CGFloat, height: CGFloat, safeTop: CGFloat) -> Form {
        let top = safeTop + gap
        return Form(side: DetailCoverSide.side(columnWidth: max(0, width - 2 * gap), height: height, top: top),
                    top: top)
    }
}
