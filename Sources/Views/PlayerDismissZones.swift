// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CoreGraphics
import SwiftUI

/// Pure geometry for the full-player dismiss zones: no zone may cover the
/// player's interactive controls (chapter buttons, scrubber). The top and
/// bottom zones are capped against the REPORTED controls frame; the side
/// strips have a fixed narrow width, and the row in the scrubber's place is
/// inset past them (`scrubberInset`). Audited failure cases: chapter
/// buttons dead on 375pt, slider thumb not grabbable at position 0 on any
/// iPhone, scrubber fully covered by the top strip in iPhone landscape.
nonisolated enum PlayerDismissZones {
    /// Gap kept between a zone's bottom edge and the controls' top edge.
    static let controlsMargin: CGFloat = 8

    /// Width of the continuous full-height swipe strip along each screen
    /// edge. Kept narrow so the interactive controls (scrubber, chapter
    /// buttons) stay clear of it. The scrubber is inset a touch more than this
    /// so its thumb at position 0/1 is never under the strip.
    static let sideStripWidth: CGFloat = 20

    /// The scrubber's extra inset on top of the content's margin, so the
    /// slider track and its thumb at 0 or 1 lie clear of the side strips.
    static let scrubberInset: CGFloat = 24

    /// The top strip may take EVERYTHING above the controls. The cover has no
    /// interactive elements, so pull-down works from the whole cover area. The
    /// fallback only applies while the controls frame is unknown.
    static func topZoneHeight(controlsFrame: CGRect?, fallback: CGFloat) -> CGFloat {
        guard let controls = controlsFrame, controls.height > 0 else { return max(0, fallback) }
        return max(0, controls.minY - controlsMargin)
    }

    /// A bottom dismiss strip covering the free space BELOW the controls (no
    /// interactive elements down there). Returns the strip's top y and its
    /// height within a container of `containerHeight`. Zero height while the
    /// controls frame is unknown (no strip until we know where controls end).
    static func bottomZone(controlsFrame: CGRect?, containerHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
        guard let controls = controlsFrame, controls.height > 0 else { return (containerHeight, 0) }
        let top = controls.maxY + controlsMargin
        return (top, max(0, containerHeight - top))
    }

    /// Narrowest space beside the controls that takes the notice pill.
    static let noticeSlotMinWidth: CGFloat = 160

    /// The free space the notice pill stands in, never over a control:
    /// first below the controls, then beside them (side by side, over the
    /// cover), then above them (over the cover). The pill hangs above the
    /// dismiss zones, so its tap arrives; the zones keep everything else.
    /// Nil while the controls frame is unknown or no free space in the
    /// visible container holds the pill; the notice then stays in the log.
    static func noticeSlot(controlsFrame: CGRect?, container: CGSize,
                           topInset: CGFloat, bottomInset: CGFloat, pillHeight: CGFloat) -> CGRect? {
        guard let controls = controlsFrame, controls.height > 0 else { return nil }
        let left = sideStripWidth
        let right = container.width - sideStripWidth
        let top = topInset
        let bottom = container.height - bottomInset
        // The spans are compared before a rect is built: a CGRect reports
        // the size of a negative span as positive.
        let belowTop = controls.maxY + controlsMargin
        if bottom - belowTop >= pillHeight {
            return CGRect(x: left, y: belowTop, width: right - left, height: bottom - belowTop)
        }
        let besideRight = controls.minX - controlsMargin
        if besideRight - left >= noticeSlotMinWidth, bottom - top >= pillHeight {
            return CGRect(x: left, y: top, width: besideRight - left, height: bottom - top)
        }
        let aboveBottom = controls.minY - controlsMargin
        if aboveBottom - top >= pillHeight {
            return CGRect(x: left, y: top, width: right - left, height: aboveBottom - top)
        }
        return nil
    }
}

/// Reports the frame of the player's controls column (chapter header, scrubber,
/// transport/secondary/tertiary rows) up to the overlay, in the overlay's
/// named coordinate space.
nonisolated struct PlayerControlsFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension CoordinateSpace {
    /// Shared name between FullPlayerOverlay (defines it) and PlayerView
    /// (reports the controls frame in it).
    nonisolated static let fullPlayerOverlayName = "fullPlayerOverlay"
}
