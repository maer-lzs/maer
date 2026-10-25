// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The side column is built from two parts and nothing else: the capsule
/// (`SideCapsule`: the tabs, the search's scopes, the settings' sections)
/// and the round button (`SideRoundButton`: the search, the cog, the search's
/// close button, the close button of the full player and of the settings).
/// Measure, spacing and material stand here once.
nonisolated enum SideColumnStyle {
    /// The column's one measure (`TabBarPlacement.sideMeasure`): the width
    /// of the capsule and of every round button.
    static let measure = TabBarPlacement.sideMeasure
    /// The gap between a cell's pill and the capsule's edge, which is also
    /// the capsule's end padding (concentric pill, see `MediaTabBar`).
    static let pillGap: CGFloat = 5
    /// The spacing between the cells.
    static let cellSpacing: CGFloat = 4
    /// THE one gap between the column's parts: Wi-Fi glyph to cog, capsule
    /// to round button, playback bar to search.
    static let gap: CGFloat = 14
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

/// Where the side column stands: its edge, its top under the system's
/// glyphs, the shift onto the system's axis and the width of the strip the
/// system keeps free. The library measures it; the library and the full
/// player stand their column by it (`placedInSideColumn`), so the player's
/// column is the library's column with other parts in it.
struct SideColumnPlacement: Equatable {
    var leading: Bool
    var top: CGFloat
    var shift: CGFloat
    var strip: CGFloat

    /// The edge the column stands at.
    var edge: Edge.Set { leading ? .leading : .trailing }
}

extension EnvironmentValues {
    /// The side column's placement, nil while the tabs stand below.
    @Entry var sideColumnPlacement: SideColumnPlacement? = nil
}

extension View {
    /// Stands this stack of parts as THE side column: in the column's
    /// measure on the system's axis, from `placement.top` down to `bottom`
    /// above the window's lower edge. `onMaxX` hears the column's right edge
    /// in the window (the library reads the axis from it).
    func placedInSideColumn(_ placement: SideColumnPlacement, bottom: CGFloat,
                            onMaxX: @escaping (CGFloat) -> Void = { _ in }) -> some View {
        frame(width: SideColumnStyle.measure)
            .offset(x: placement.shift)
            .frame(width: max(placement.strip, SideColumnStyle.measure + 8))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { onMaxX($0) }
            .frame(maxHeight: .infinity)
            .padding(.top, placement.top)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: placement.leading ? .topLeading : .topTrailing)
            .ignoresSafeArea()
    }
}

/// A cell of the side capsule that is one tool: its label as a glyph in the
/// column's glyph size, the cell's square as the tap area. The sleep timer
/// adds its remaining time under the glyph (`SleepTimerMenu.columnCell`).
struct SideCapsuleToolCell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .font(.system(size: SideColumnStyle.glyphSize))
            .foregroundStyle(.primary)
            .tint(.primary)
            .frame(width: SideColumnStyle.measure - 2 * SideColumnStyle.pillGap,
                   height: SideColumnStyle.measure - 2 * SideColumnStyle.pillGap)
            .contentShape(Rectangle())
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
        SideRound {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 21 * SideColumnStyle.measure / 56, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: SideRound<EmptyView>.side, height: SideRound<EmptyView>.side)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel(Text(label))
    }
}

/// The round surface of the side column: its circle in the column's
/// measure on the column's glass. `SideRoundButton` stands on it, and a
/// control that brings its own button (AirPlay's route picker) too.
struct SideRound<Content: View>: View {
    static var side: CGFloat { max(SideColumnStyle.measure, 44) }
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(width: Self.side, height: Self.side)
            .modifier(AdaptiveGlassBackground(shape: Circle(), tier: SideColumnStyle.tier))
    }
}
