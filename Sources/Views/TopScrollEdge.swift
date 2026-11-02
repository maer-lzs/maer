// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

extension View {
    /// The declared top edge of every navigation stack, its root and its
    /// pushed pages: soft in every posture. The platform's default changed
    /// between SDK 26.5 and 27 (the top edge became a hard-edged milky band
    /// reaching far under the status bar, measured at the pixel on both
    /// SDKs), and it stays on once content has been under the bar, a band
    /// over a page at rest. A presented stack does not inherit it from the
    /// stack below, so every stack names it. Scroll edge effects exist from
    /// iOS 26; below it there is none to declare.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// No top edge at all: for the settings, in two columns under one bar,
    /// where an edge over each column draws a band across the page, and in
    /// one form under the pills, where it draws one over the first rows.
    @ViewBuilder
    func withoutTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
