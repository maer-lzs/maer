// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Glass tab bar at the bottom (below the mini-player) for the content types —
/// audiobooks/podcasts/music/radio. Its own glass element in the same language
/// as mini-player and pill. A capsule slides behind the SELECTED tab (N1: the
/// primary "where am I" anchor, matchedGeometry), and the selected label carries
/// its media type's tint (Audible orange / Podcasts purple / Music red, Home
/// neutral — see MediaType.tint). Pure component, the state (selected type)
/// lives in LibraryView. Only shown when at least two types are available.
struct MediaTabBar: View {
    let types: [MediaType]
    let selected: MediaType
    /// Direct callback instead of a binding — the switch has side effects
    /// (resetting the navigation path) that were unreliable in a binding setter
    /// (a tap "did nothing").
    let onSelect: (MediaType) -> Void
    /// Native glass-morph identity when hosted in the bottom-bar container.
    var glassMorphID: String? = nil
    var glassMorphNamespace: Namespace.ID? = nil

    /// D7/B6: at accessibility sizes the caption labels truncated anyway —
    /// icons only, the label lives on as the accessibility label.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// N1: shared namespace so the active pill glides between tabs.
    @Namespace private var pillNS

    /// N1d: THE one gap between the pill's edge and the bar's edge — the bar's
    /// horizontal end padding and the pill's vertical inset are the same value.
    /// Because the bar is a capsule, a capsule pill inset uniformly by this gap
    /// IS the concentric shape in closed form: pill radius = pill height / 2 =
    /// (bar height − 2·gap) / 2 = bar radius − gap, at every bar height — so
    /// the relation holds at rest, while gliding and through the collapse
    /// morph, with no radius constant of its own. (iOS 26's ConcentricRectangle
    /// was tried and is NOT usable here: resolving it inside the bar broke the
    /// bottom bar reproducibly — the capsule identity above makes it
    /// unnecessary anyway.)
    /// e053f53: 6 → 5 — the pill breathes a touch taller inside the SAME
    /// bar height (the gap is the pill's vertical inset; smaller gap =
    /// taller pill, bar metrics and morph untouched).
    private static let pillGap: CGFloat = 5

    /// The label size before scaling — `.caption2` at the default size, kept as
    /// a number so ONE scale can be applied to it.
    static let baseLabelSize: CGFloat = 11
    /// Spacing between the cells (the HStack's).
    private static let cellSpacing: CGFloat = 4

    /// Measured bar width — the uniform scale needs to know what there is.
    @State private var barWidth: CGFloat = 0

    /// 7fb1cc1: ONE scale for the whole bar, derived from the LONGEST title, so
    /// every label carries the same size. Floored (`TabBarMetrics.minimumScale`)
    /// — below that the bar would read smaller than the rest of the interface,
    /// which is the defect one layer down.
    private var labelScale: CGFloat {
        guard barWidth > 0, !types.isEmpty else { return 1 }
        let font = UIFont.systemFont(ofSize: Self.baseLabelSize)
        let widths = types.map { TabBarMetrics.labelWidth($0.label, font: font) }
        let gaps = Self.cellSpacing * CGFloat(types.count - 1) + Self.pillGap * 2
        let perCell = (barWidth - gaps) / CGFloat(types.count)
        return TabBarMetrics.uniformScale(
            labelWidths: widths,
            available: perCell - TabBarMetrics.Capsule.horizontalPadding * 2)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(types) { type in
                Button {
                    onSelect(type)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: type.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                        if !dynamicTypeSize.isAccessibilitySize {
                            // 7fb1cc1 (the owner): no title is squeezed on its
                            // own. `minimumScaleFactor` per label made the size
                            // a property of the WORD — "Radio" big, "Hörbücher"
                            // small, and the user looks for the reason. One
                            // size for the whole bar makes it a property of the
                            // BAR, and that nobody notices, because there is
                            // nothing to compare it against.
                            Text(type.label)
                                .font(.system(size: Self.baseLabelSize * labelScale))
                                .lineLimit(1)
                        }
                    }
                    // Selected → the type's own tint; unselected → neutral. The
                    // colour appears only on the active selector, never always.
                    .foregroundStyle(selected == type ? type.tint : Color.primary)
                    // e053f53: noticeable horizontal air between the label
                    // cluster and the pill edge (vertical stays — bar height).
                    // 98c621f: the ONE capsule metric — horizontal stays,
                    // vertical is what grew (extra width would take exactly the
                    // room "Hörbücher" is missing).
                    .padding(.horizontal, TabBarMetrics.Capsule.horizontalPadding)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, TabBarMetrics.Capsule.verticalPadding)
                    .background {
                        // N1/N1d: the sliding pill behind the active tab — a
                        // wash of the type tint (neutral at Home), no glass
                        // (backward-compatible). matchedGeometry glides the
                        // single instance on a tab switch. Capsule inset by the
                        // ONE pill gap → concentric to the bar capsule (see
                        // `pillGap`); no horizontal inset within the cell, the
                        // bar's end padding provides the same gap at the ends.
                        if selected == type {
                            Capsule()
                                .fill(type.tint.opacity(0.16))
                                .matchedGeometryEffect(id: "activeTabPill", in: pillNS)
                                .padding(.vertical, Self.pillGap)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(type.label))
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier("tab-\(type.rawValue)")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .animation(.snappy(duration: 0.3), value: selected)
        // N1d: the end padding IS the pill gap — the pill's horizontal distance
        // to the bar's rounded ends equals its vertical inset everywhere.
        .padding(.horizontal, Self.pillGap)
        .modifier(AdaptiveGlassBackground(
            shape: Capsule(), tier: .glass,
            morphID: glassMorphID, morphNamespace: glassMorphNamespace))
    }
}
