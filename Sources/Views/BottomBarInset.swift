// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Height of the floating bottom zone (mini-player + tab bar), which sits as an
/// overlay above everything and therefore reserves NO space. Every scroll
/// content (library, podcasts, detail pages) keeps this much free at the bottom
/// so the last covers don't disappear under the mini-player.
private struct BottomBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var bottomBarInset: CGFloat {
        get { self[BottomBarInsetKey.self] }
        set { self[BottomBarInsetKey.self] = newValue }
    }
}

/// ARCHITECTURE (25.07): the reserved clearance is a CONSTANT per composition —
/// never a live measurement of the (morphing) bar. This CUTS the feedback
/// circle offset → bar state → bar height → content padding → contentSize →
/// offset for good: the bar can morph freely, content geometry never moves.
/// The reserve covers the EXPANDED shape (sim-measured: 126 pt with the mini
/// player mounted, 66 pt without); a collapsed bar simply leaves a little air
/// at the very end of a list — the accepted price for structurally calm
/// scrolling. It may change on REAL composition changes (mini player mounts/
/// unmounts) but NEVER on `collapsed` or mid-morph.
enum BottomBarReserve {
    /// Media pill row + spacing + bottom padding (expanded, no mini player).
    static let base: CGFloat = 66
    /// Additional mini-player row (bar + row spacing).
    static let miniPlayer: CGFloat = 60

    static func total(hasMiniPlayer: Bool) -> CGFloat {
        base + (hasMiniPlayer ? miniPlayer : 0)
    }
}

extension View {
    /// Leave as much space at the bottom as the floating bottom zone is tall.
    func bottomBarClearance() -> some View {
        modifier(BottomBarClearance())
    }

    /// THE treatment for a `List`/`Form` that scrolls UNDER the floating bottom
    /// bar (i.e. lives in the tab navigation stack): releases the opaque system
    /// list background so content scrolls full-bleed behind the glass — the
    /// opaque patch behind the bar (S17b class) — AND reserves the bar
    /// clearance. One place; a new in-stack list inherits it instead
    /// of re-discovering both halves. Modally presented lists (settings sheet:
    /// no bar behind, inset 0) do not need it.
    func barAwareList() -> some View {
        scrollContentBackground(.hidden)
            .bottomBarClearance()
    }
}

private struct BottomBarClearance: ViewModifier {
    @Environment(\.bottomBarInset) private var inset
    func body(content: Content) -> some View {
        content.padding(.bottom, inset)
    }
}
