// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
    private static let pillGap: CGFloat = 6

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
                            Text(type.label)
                                .font(.caption2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    // Selected → the type's own tint; unselected → neutral. The
                    // colour appears only on the active selector, never always.
                    .foregroundStyle(selected == type ? type.tint : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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
        .animation(.snappy(duration: 0.3), value: selected)
        // N1d: the end padding IS the pill gap — the pill's horizontal distance
        // to the bar's rounded ends equals its vertical inset everywhere.
        .padding(.horizontal, Self.pillGap)
        .modifier(AdaptiveGlassBackground(shape: Capsule(), tier: .glass))
    }
}
