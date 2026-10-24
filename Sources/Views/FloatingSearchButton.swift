// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Floating magnifier button at the bottom. Modeled on the separate, floating
/// search button Apple uses since iOS 26 in Music & co. Opens the full-page
/// `SearchScreen` (the bar morphs into the search field) instead of expanding
/// into a field itself.
struct FloatingSearchButton: View {
    let action: () -> Void
    /// Native glass-morph identity when hosted in the bottom-bar container.
    var glassMorphID: String? = nil
    var glassMorphNamespace: Namespace.ID? = nil
    /// 56 at the bottom; the side column is narrower (46, never under the
    /// 44 pt a finger needs). The glyph keeps its share of the circle.
    var diameter: CGFloat = 56
    /// Glass at the bottom; the system's bar material in the side column.
    var tier: GlassTier = .glass

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                // Same glyph size as the collapsed home button's tab
                // glyph; circle size unchanged.
                .font(.system(size: 21 * diameter / 56, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: max(diameter, 44), height: max(diameter, 44))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(
            shape: Circle(), tier: tier,
            morphID: glassMorphID, morphNamespace: glassMorphNamespace))
        .accessibilityLabel(Text("Search"))
    }
}
