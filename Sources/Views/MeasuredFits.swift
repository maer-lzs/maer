// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The ViewThatFits replacement for content that touches isolated state.
///
/// Crash class 4b2f7a8: `ViewThatFits` evaluates its candidates' bodies on
/// the AsyncRenderer — off the main actor. Data-pure candidates can opt out
/// (`nonisolated`, the two bars), but a candidate holding live viewModel
/// bindings cannot be made data-pure without rebuilding it. This container
/// takes the DECISION out of the measurement engine instead: the full
/// variant's natural width is measured invisibly on the MAIN render path
/// (`onGeometryChange` — a real rendered width, never an estimate: the
/// tab-bar lesson stands, a computed width is how "Hörbüch…" happened), and
/// only the chosen branch is built for display. Nobody measures isolated
/// bodies.
///
/// Until both widths are known the COMPACT branch shows (it always fits);
/// the upgrade to the full branch lands within the first layout passes.
struct MeasuredFits<Full: View, Compact: View>: View {
    @ViewBuilder let full: () -> Full
    @ViewBuilder let compact: () -> Compact

    @State private var naturalWidth: CGFloat?
    @State private var offeredWidth: CGFloat?

    private var fullFits: Bool {
        guard let naturalWidth, let offeredWidth else { return false }
        return naturalWidth <= offeredWidth + 0.5
    }

    var body: some View {
        Group {
            if fullFits { full() } else { compact() }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { offeredWidth = $0 }
        .background {
            // The probe: the REAL full variant at its natural size, invisible,
            // in the background so it can never widen the container. hidden()
            // keeps it out of hit-testing and accessibility.
            full()
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { naturalWidth = $0 }
        }
    }
}
