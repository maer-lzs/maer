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
/// The settings' sections take the same bar upright beside a side column,
/// with their own cells (`init(cells:selectedID:onSelectID:upright:)`).
struct MediaTabBar: View {
    let cells: [TabBarCell]
    let selectedID: String
    /// Direct callback instead of a binding. The switch has side effects
    /// (resetting the navigation path) that were unreliable in a binding setter
    /// (a tap "did nothing").
    let onSelectID: (String) -> Void
    /// Native glass-morph identity when hosted in the bottom-bar container.
    var glassMorphID: String? = nil
    var glassMorphNamespace: Namespace.ID? = nil
    /// Upright where the system stands its bars upright (`TabBarPlacement`):
    /// the same cells one under the other, symbols only as at accessibility
    /// sizes, the name stays for VoiceOver.
    var upright = false
    /// Upright and collapsed with the bottom bar (`BottomBarState.collapsed`):
    /// only the selected cell stays; a tap on it opens the column again.
    var collapsed = false

    /// The library's media tabs.
    init(types: [MediaType], selected: MediaType, onSelect: @escaping (MediaType) -> Void,
         glassMorphID: String? = nil, glassMorphNamespace: Namespace.ID? = nil, upright: Bool = false,
         collapsed: Bool = false) {
        self.cells = types.map(TabBarCell.init(mediaType:))
        self.selectedID = TabBarCell(mediaType: selected).id
        self.onSelectID = { id in
            if let type = types.first(where: { "tab-\($0.rawValue)" == id }) { onSelect(type) }
        }
        self.glassMorphID = glassMorphID
        self.glassMorphNamespace = glassMorphNamespace
        self.upright = upright
        self.collapsed = collapsed
    }

    /// Any other set of sections in the same bar.
    init(cells: [TabBarCell], selectedID: String, onSelectID: @escaping (String) -> Void,
         upright: Bool = false) {
        self.cells = cells
        self.selectedID = selectedID
        self.onSelectID = onSelectID
        self.upright = upright
    }

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
    /// The value stands once, in `SideColumnStyle`, for the bar and the column.
    private static let pillGap = SideColumnStyle.pillGap

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
        let cells = self.cells
        let selected = self.selectedID
        let hideLabels = dynamicTypeSize.isAccessibilitySize
        let namespace = pillNS
        let onSelect = self.onSelectID
        // MeasuredLadder, never ViewThatFits. Four device
        // crashes proved the sizing engine's off-main reach cannot be
        // enumerated (even nonisolated data-pure candidates trapped). The
        // ladder probes the REAL rows invisibly on main and builds only the
        // chosen one; the behaviour contract (one size per bar, whole titles,
        // descending rungs) is unchanged and the journeys still fence it.
        if upright {
            // A column has no width to fall back on: no labels, no ladder.
            // The column's one capsule (`SideCapsule`).
            SideCapsule {
                TabRowCandidate(cells: collapsed ? cells.filter { $0.id == selected } : cells,
                                selected: selected,
                                labelSize: Self.baseLabelSize, hideLabels: true,
                                namespace: namespace, upright: true, onSelect: onSelect)
            }
            .animation(.snappy(duration: 0.3), value: selected)
            // The bottom bar's own spring, so column and bar move as one.
            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: collapsed)
        } else {
            MeasuredLadder(rungs: Self.labelSizes) { size, probing in
                TabRowCandidate(cells: cells, selected: selected,
                                labelSize: size, hideLabels: hideLabels,
                                namespace: namespace, probing: probing,
                                onSelect: onSelect)
            }
            .animation(.snappy(duration: 0.3), value: selected)
            // The end padding IS the pill gap. The pill's distance to the bar's
            // rounded ends equals its inset along the bar everywhere.
            .padding(.horizontal, Self.pillGap)
            .modifier(AdaptiveGlassBackground(
                shape: Capsule(), tier: .glass,
                morphID: glassMorphID, morphNamespace: glassMorphNamespace))
        }
    }
}

/// One section of the bar: what its cell shows and the handle it answers to.
nonisolated struct TabBarCell: Identifiable, Equatable {
    /// The locale-independent handle (`tab-<rawValue>` for the media tabs).
    let id: String
    let systemImage: String
    let label: String
    let tint: Color

    init(id: String, systemImage: String, label: String, tint: Color) {
        self.id = id
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
    }

    @MainActor init(mediaType type: MediaType) {
        self.init(id: "tab-\(type.rawValue)", systemImage: type.systemImage,
                  label: type.label, tint: type.tint)
    }
}

/// One row of the bar at one ladder size. As a ViewThatFits candidate this
/// was data-pure and `nonisolated` and STILL trapped on the AsyncRenderer:
/// the sizing engine wraps evaluation in ObservationCenter and reaches a live
/// isolated reference. It is therefore only ever evaluated on the MAIN render
/// path. As `MeasuredLadder`'s hidden probe or as the chosen row.
/// `nonisolated` stays as belt and braces, not as the load-bearing fix.
nonisolated private struct TabRowCandidate: View {
    let cells: [TabBarCell]
    let selected: String
    let labelSize: CGFloat
    let hideLabels: Bool
    let namespace: Namespace.ID
    /// Probe rows must not mount the matched-geometry pill. Seven hidden
    /// copies of one geometry id would fight over it.
    var probing: Bool = false
    /// The cells one under the other (`MediaTabBar.upright`).
    var upright: Bool = false
    let onSelect: (String) -> Void

    /// The bar's and the column's measures, standing once in `SideColumnStyle`.
    private static let pillGap = SideColumnStyle.pillGap
    private static let cellSpacing = SideColumnStyle.cellSpacing

    var body: some View {
        let layout = upright ? AnyLayout(VStackLayout(spacing: Self.cellSpacing))
                             : AnyLayout(HStackLayout(spacing: Self.cellSpacing))
        layout {
            ForEach(cells) { cell in
                Button {
                    onSelect(cell.id)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: cell.systemImage)
                            .font(.system(size: SideColumnStyle.glyphSize, weight: .semibold))
                        if !hideLabels {
                            Text(cell.label)
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
                    .foregroundStyle(selected == cell.id ? cell.tint : Color.primary)
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
                        if !probing, selected == cell.id {
                            Capsule()
                                .fill(cell.tint.opacity(0.16))
                                .matchedGeometryEffect(id: "activeTabPill", in: namespace)
                                .padding(upright ? .horizontal : .vertical, Self.pillGap)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(cell.label))
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier(cell.id)
            }
        }
    }
}
