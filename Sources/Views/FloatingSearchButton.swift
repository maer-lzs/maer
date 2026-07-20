// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Floating magnifier button at the bottom — modeled on the separate, floating
/// search button Apple uses since iOS 26 in Music & co. Opens the full-page
/// `SearchScreen` (the bar morphs into the search field) instead of expanding
/// into a field itself.
struct FloatingSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                // N3b: same glyph size as the collapsed home button's tab
                // glyph (N3); circle size unchanged.
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(shape: Circle()))
        .accessibilityLabel(Text("Search"))
    }
}
