// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// GT3: a PERSISTENT adaptive top-edge fade for the library scroll surfaces —
/// content softens into the system tone at the very top (Apple Podcasts/Music
/// look) and STAYS visible while scrolling. Mär replaces the system toolbar
/// with its own adaptive glass (LibraryView: "our own adaptive glass instead of
/// the system's toolbar"), which detaches the iOS 26 system scroll-edge effect
/// — that one only flashes and then vanishes on scroll. So we own the fade
/// instead: not tied to any toolbar/scroll state, always on.
///
/// Adaptive (reuses the `BookDetailScreen` white/black tone pattern, Regel 2):
/// white in light mode, black in dark, full at the very top → clear downward
/// (a touch stronger/opaque per GT3). Non-interactive; applied once over the
/// tab content so every library tab shares it (no per-tab duplication).
struct TopScrollEdgeFade: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Fade depth from the top edge (GT3b: taller, softer).
    var height: CGFloat = 68
    /// GT3b: top-tone start opacity — subtler than a full-opaque edge.
    var topOpacity: Double = 0.7

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: tone.opacity(topOpacity), location: 0.0),
                .init(color: tone.opacity(0), location: 1.0),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var tone: Color { colorScheme == .dark ? .black : .white }
}

extension View {
    /// GT3c: anchor the top-edge fade to THIS scroll surface's viewport top.
    /// Apply to each tab's ROOT `ScrollView` — the ScrollView IS the viewport,
    /// so its top edge is the real content top under the nav bar (reliable,
    /// unlike hanging the fade on a layout container, which centered it when a
    /// tab didn't fill the height — GT3/GT3b). ONE implementation, applied per
    /// tab = tab parity, no duplicated fade. `.overlay` sits on the ScrollView
    /// frame, so it stays FIXED at the top while the content scrolls under it.
    func topEdgeFade() -> some View {
        overlay(alignment: .top) { TopScrollEdgeFade() }
    }
}
