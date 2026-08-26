// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CoreGraphics
import SwiftUI

/// Pure geometry for the full-player dismiss zones (D1/B1): the side rails and
/// the top strip must never cover the player's interactive controls (chapter
/// buttons, scrubber). Instead of a fixed bottom inset, each zone is capped
/// against the REPORTED controls frame. Audited failure cases: chapter
/// buttons dead on 375pt, slider thumb not grabbable at position 0 on any
/// iPhone, scrubber fully covered by the top strip in iPhone landscape.
nonisolated enum PlayerDismissZones {
    /// Gap kept between a zone's bottom edge and the controls' top edge.
    static let controlsMargin: CGFloat = 8

    /// Width of the continuous full-height swipe strip along each screen
    /// edge. Kept narrow so the interactive controls (scrubber, chapter
    /// buttons) stay clear of it. The scrubber is inset a touch more than this
    /// so its thumb at position 0/1 is never under the strip (D1).
    static let sideStripWidth: CGFloat = 20

    /// Width of each side rail: everything outside the max 500pt content
    /// column (incl. its margin), at least 56pt on narrow phones. On iPads the
    /// rails therefore sit entirely OUTSIDE the content column. Their
    /// behavior is unchanged by the controls cap below.
    static func sideZoneWidth(containerWidth: CGFloat) -> CGFloat {
        max(56, (containerWidth - 520) / 2)
    }

    /// Height a top-aligned zone may take without covering the controls: when
    /// the zone's x-range overlaps the controls frame, the zone ends
    /// `controlsMargin` above the controls; otherwise (or while the frame is
    /// still unknown) the legacy fallback applies. Never negative.
    static func zoneHeight(zoneRect: CGRect, controlsFrame: CGRect?, fallback: CGFloat) -> CGFloat {
        guard let controls = controlsFrame, controls.height > 0,
              zoneRect.minX < controls.maxX, zoneRect.maxX > controls.minX else {
            return max(0, fallback)
        }
        return max(0, min(fallback, controls.minY - controlsMargin))
    }

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
