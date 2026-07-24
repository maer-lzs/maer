// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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

extension View {
    /// Leave as much space at the bottom as the floating bottom zone is tall.
    func bottomBarClearance() -> some View {
        modifier(BottomBarClearance())
    }

    /// THE treatment for a `List`/`Form` that scrolls UNDER the floating bottom
    /// bar (i.e. lives in the tab navigation stack): releases the opaque system
    /// list background so content scrolls full-bleed behind the glass — the
    /// opaque patch behind the bar (S17b class) — AND reserves the bar
    /// clearance. One place (Regel 2); a new in-stack list inherits it instead
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
