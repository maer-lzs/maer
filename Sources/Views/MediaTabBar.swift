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

    /// Spacing between the cells.
    private static let cellSpacing: CGFloat = 4

    /// The label size at rest, and the sizes the bar may fall back to.
    ///
    /// 7fb1cc1: ONE size for the whole row. A per-label shrink makes the size a
    /// property of the WORD — "Radio" big, "Hörbücher" small, and the user
    /// looks for the reason; a shared size makes it a property of the BAR, and
    /// that nobody notices. The row is offered as a WHOLE at each size, so all
    /// labels always share it.
    ///
    /// The last entry is the floor: below it the bar would read smaller than the
    /// rest of the interface, which is the defect one layer down.
    static let baseLabelSize: CGFloat = 11
    static let labelSizes: [CGFloat] = [11, 10.5, 10, 9.5, 9, 8.5, 8]

    var body: some View {
        // 85a7c00: NO arithmetic about the available width — SwiftUI measures.
        // `ViewThatFits` offers the row at descending sizes and takes the
        // first that fits WHOLE (one size for all labels, no truncation, no
        // number that can drift from the truth).
        //
        // cd2b3be (the owner's crash, twice in 12 s): everything inside these
        // closures is evaluated during the MEASUREMENT — and SwiftUI measures
        // on its AsyncRenderer, a background thread. A closure that captures
        // `self` (this View type is MainActor by project default) trips the
        // isolation check there and TRAPS (`dispatch_assert_queue_fail`).
        // The card tap was only the trigger of the render pass, never the
        // cause. Same class as Y32/`AppTheme.accentUIColor`, one layer up —
        // so the candidates are built from PLAIN COPIES taken here, and the
        // closures touch data only, never self.
        let types = self.types
        let selected = self.selected
        let hideLabels = dynamicTypeSize.isAccessibilitySize
        let namespace = pillNS
        let onSelect = self.onSelect
        ViewThatFits(in: .horizontal) {
            ForEach(Self.labelSizes, id: \.self) { size in
                TabRowCandidate(types: types, selected: selected,
                                labelSize: size, hideLabels: hideLabels,
                                namespace: namespace, onSelect: onSelect)
            }
        }
        .animation(.snappy(duration: 0.3), value: selected)
        // N1d: the end padding IS the pill gap — the pill's horizontal distance
        // to the bar's rounded ends equals its vertical inset everywhere.
        .padding(.horizontal, Self.pillGap)
        .modifier(AdaptiveGlassBackground(
            shape: Capsule(), tier: .glass,
            morphID: glassMorphID, morphNamespace: glassMorphNamespace))
    }
}

/// One row candidate for `ViewThatFits` — a value of PLAIN data, so building
/// it inside the measurement closures touches nothing MainActor-isolated
/// (cd2b3be). Its `body` runs on the main actor as usual; only the
/// CONSTRUCTION happens during measurement.
private struct TabRowCandidate: View {
    let types: [MediaType]
    let selected: MediaType
    let labelSize: CGFloat
    let hideLabels: Bool
    let namespace: Namespace.ID
    let onSelect: (MediaType) -> Void

    /// e053f53 mirror — kept in sync with `MediaTabBar.pillGap` via the
    /// shared constant there.
    private static let pillGap: CGFloat = 5
    private static let cellSpacing: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.cellSpacing) {
            ForEach(types) { type in
                Button {
                    onSelect(type)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: type.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                        if !hideLabels {
                            Text(type.label)
                                .font(.system(size: labelSize))
                                // Whole or not at all: a cut-off word is a
                                // defect, a small word only a metric. Refusing
                                // to compress is what lets `ViewThatFits` see
                                // that this candidate does not fit.
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    // Selected → the type's own tint; unselected → neutral. The
                    // colour appears only on the active selector, never always.
                    .foregroundStyle(selected == type ? type.tint : Color.primary)
                    // 98c621f: the ONE capsule metric — horizontal stays (that
                    // width is exactly the room the longest title needs),
                    // vertical is what grew.
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
                                .matchedGeometryEffect(id: "activeTabPill", in: namespace)
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
    }
}
