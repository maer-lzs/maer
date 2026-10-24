// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The side column is built from two parts and nothing else: the capsule
/// (`SideCapsule`: the tabs, the search's scopes, the settings' sections)
/// and the round button (`SideRoundButton`: the search, the cog, the search's
/// close button). Measure, spacing and material stand here once.
nonisolated enum SideColumnStyle {
    /// The column's one measure (`TabBarPlacement.sideMeasure`): the width
    /// of the capsule and of every round button.
    static let measure = TabBarPlacement.sideMeasure
    /// The gap between a cell's pill and the capsule's edge, which is also
    /// the capsule's end padding (concentric pill, see `MediaTabBar`).
    static let pillGap: CGFloat = 5
    /// The spacing between the cells.
    static let cellSpacing: CGFloat = 4
    /// The glyph size of a cell.
    static let glyphSize: CGFloat = 17
    /// The glass of every part of the column: the system's bar material.
    static let tier = GlassTier.sideColumn

    /// The brightness of the column's parts: what the page under it asks
    /// for (a dark page: dark glass, light glyphs, as the system's status
    /// glyphs turn light there), else the app's own. The system does not
    /// hand out the style it gives the status bar (`.default` on every
    /// page), and the glass does not follow its ground reliably by itself,
    /// so the page says it.
    static func scheme(page: ColorScheme?, system: ColorScheme) -> ColorScheme {
        page ?? system
    }
}

/// What a page under the side column asks of the column's brightness;
/// nil asks nothing. Only the visible tab's page counts (`LibraryView`).
struct SideColumnSchemeKey: PreferenceKey {
    static let defaultValue: ColorScheme? = nil
    static func reduce(value: inout ColorScheme?, nextValue: () -> ColorScheme?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// The page stands on a ground of this brightness under the side column.
    func sideColumnScheme(_ scheme: ColorScheme?) -> some View {
        preference(key: SideColumnSchemeKey.self, value: scheme)
    }
}

/// THE upright capsule of the side column: its cells one under the other,
/// the pill gap as end padding, the column's glass.
struct SideCapsule<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: SideColumnStyle.cellSpacing) { content() }
            .padding(.vertical, SideColumnStyle.pillGap)
            .frame(width: SideColumnStyle.measure)
            .modifier(AdaptiveGlassBackground(shape: Capsule(), tier: SideColumnStyle.tier))
    }
}

/// THE round button of the side column: one glyph on the column's glass,
/// in the column's measure, the glyph keeping its share of the circle.
struct SideRoundButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 21 * SideColumnStyle.measure / 56, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: max(SideColumnStyle.measure, 44), height: max(SideColumnStyle.measure, 44))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(shape: Circle(), tier: SideColumnStyle.tier))
        .accessibilityLabel(Text(label))
    }
}
