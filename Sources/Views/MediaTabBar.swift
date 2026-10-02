// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Glass tab bar at the bottom (below the mini-player) for the content types.
/// Audiobooks/podcasts/music/radio. Its own glass element in the same language
/// as mini-player and pill. A capsule slides behind the SELECTED tab (the
/// primary "where am I" anchor, matchedGeometry), and the selected label carries
/// its media type's tint (Audible orange / Podcasts purple / Music red, Home
/// neutral. See MediaType.tint). Pure component, the state (selected type)
/// lives in LibraryView. Only shown when at least two types are available.
struct MediaTabBar: View {
    let types: [MediaType]
    let selected: MediaType
    /// Direct callback instead of a binding. The switch has side effects
    /// (resetting the navigation path) that were unreliable in a binding setter
    /// (a tap "did nothing").
    let onSelect: (MediaType) -> Void
    /// Native glass-morph identity when hosted in the bottom-bar container.
    var glassMorphID: String? = nil
    var glassMorphNamespace: Namespace.ID? = nil

    /// At accessibility sizes the caption labels truncated anyway.
    /// Icons only, the label lives on as the accessibility label.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Shared namespace so the active pill glides between tabs.
    @Namespace private var pillNS

    /// THE one gap between the pill's edge and the bar's edge. The bar's
    /// horizontal end padding and the pill's vertical inset are the same value.
    /// Because the bar is a capsule, a capsule pill inset uniformly by this gap
    /// IS the concentric shape in closed form: pill radius = pill height / 2 =
    /// (bar height − 2·gap) / 2 = bar radius − gap, at every bar height. So
    /// the relation holds at rest, while gliding and through the collapse
    /// morph, with no radius constant of its own. (iOS 26's ConcentricRectangle
    /// was tried and is NOT usable here: resolving it inside the bar broke the
    /// bottom bar reproducibly. The capsule identity above makes it
    /// unnecessary anyway.)
    /// 6 → 5. The pill breathes a touch taller inside the SAME
    /// bar height (the gap is the pill's vertical inset; smaller gap =
    /// taller pill, bar metrics and morph untouched).
    private static let pillGap: CGFloat = 5

    /// Spacing between the cells.
    private static let cellSpacing: CGFloat = 4

    /// The label size at rest, and the sizes the bar may fall back to.
    ///
    /// ONE size for the whole row. A per-label shrink makes the size a
    /// property of the WORD. "Radio" big, "Hörbücher" small, and the user
    /// looks for the reason; a shared size makes it a property of the BAR, and
    /// that nobody notices. The row is offered as a WHOLE at each size, so all
    /// labels always share it.
    ///
    /// The last entry is the floor: below it the bar would read smaller than the
    /// rest of the interface, which is the defect one layer down.
    static let baseLabelSize: CGFloat = 11
    static let labelSizes: [CGFloat] = [baseLabelSize, 10.5, 10, 9.5, 9, 8.5, 8]

    var body: some View {
        // NO arithmetic about the available width. SwiftUI measures.
        // The ladder offers the row at descending sizes and takes the first
        // that fits WHOLE (one size for all labels, no truncation, no number
        // that can drift from the truth).
        //
        // Everything inside these
        // closures is evaluated during the MEASUREMENT. And SwiftUI measures
        // on its AsyncRenderer, a background thread. A closure that captures
        // `self` (this View type is MainActor by project default) trips the
        // isolation check there and TRAPS (`dispatch_assert_queue_fail`).
        // The card tap was only the trigger of the render pass, never the
        // cause. Same class as `AppTheme.accentUIColor`, one layer up.
        // So the candidates are built from PLAIN COPIES taken here, and the
        // closures touch data only, never self.
        let types = self.types
        let selected = self.selected
        let hideLabels = dynamicTypeSize.isAccessibilitySize
        let namespace = pillNS
        let onSelect = self.onSelect
        // MeasuredLadder, never ViewThatFits. Four device
        // crashes proved the sizing engine's off-main reach cannot be
        // enumerated (even nonisolated data-pure candidates trapped). The
        // ladder probes the REAL rows invisibly on main and builds only the
        // chosen one; the behaviour contract (one size per bar, whole titles,
        // descending rungs) is unchanged and the journeys still fence it.
        MeasuredLadder(rungs: Self.labelSizes) { size, probing in
            TabRowCandidate(types: types, selected: selected,
                            labelSize: size, hideLabels: hideLabels,
                            namespace: namespace, probing: probing,
                            onSelect: onSelect)
        }
        .animation(.snappy(duration: 0.3), value: selected)
        // The end padding IS the pill gap. The pill's horizontal distance
        // to the bar's rounded ends equals its vertical inset everywhere.
        .padding(.horizontal, Self.pillGap)
        .modifier(AdaptiveGlassBackground(
            shape: Capsule(), tier: .glass,
            morphID: glassMorphID, morphNamespace: glassMorphNamespace))
    }
}

/// One row of the bar at one ladder size. As a ViewThatFits candidate this
/// was data-pure and `nonisolated` and STILL trapped on the AsyncRenderer:
/// the sizing engine wraps evaluation in ObservationCenter and reaches a live
/// isolated reference. It is therefore only ever evaluated on the MAIN render
/// path. As `MeasuredLadder`'s hidden probe or as the chosen row.
/// `nonisolated` stays as belt and braces, not as the load-bearing fix.
nonisolated private struct TabRowCandidate: View {
    let types: [MediaType]
    let selected: MediaType
    let labelSize: CGFloat
    let hideLabels: Bool
    let namespace: Namespace.ID
    /// Probe rows must not mount the matched-geometry pill. Seven hidden
    /// copies of one geometry id would fight over it.
    var probing: Bool = false
    let onSelect: (MediaType) -> Void

    /// Mirror. Kept in sync with `MediaTabBar.pillGap` via the shared
    /// constant there.
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
                                // to compress is what lets the ladder's probe
                                // see that this rung does not fit.
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    // Selected → the type's own tint; unselected → neutral. The
                    // colour appears only on the active selector, never always.
                    .foregroundStyle(selected == type ? type.tint : Color.primary)
                    // The ONE capsule metric. Horizontal stays (that
                    // width is exactly the room the longest title needs),
                    // vertical is what grew.
                    .padding(.horizontal, TabBarMetrics.Capsule.horizontalPadding)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, TabBarMetrics.Capsule.verticalPadding)
                    .background {
                        // The sliding pill behind the active tab. A
                        // wash of the type tint (neutral at Home), no glass
                        // (backward-compatible). matchedGeometry glides the
                        // single instance on a tab switch. Capsule inset by the
                        // ONE pill gap → concentric to the bar capsule (see
                        // `pillGap`); no horizontal inset within the cell, the
                        // bar's end padding provides the same gap at the ends.
                        if !probing, selected == type {
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
