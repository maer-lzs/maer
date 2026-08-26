// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The ViewThatFits replacement for content that touches isolated state.
///
/// Crash class: `ViewThatFits` evaluates its candidates' bodies on
/// the AsyncRenderer — off the main actor. Data-pure candidates can opt out
/// (`nonisolated`, the two bars), but a candidate holding live viewModel
/// bindings cannot be made data-pure without rebuilding it. This container
/// takes the DECISION out of the measurement engine instead: the full
/// variant's natural width is measured invisibly on the MAIN render path
/// (`onGeometryChange` — a real rendered width, never an estimate: the
/// a computed width is how a truncated tab label happened), and
/// only the chosen branch is built for display. Nobody measures isolated
/// bodies.
///
/// Until both widths are known the COMPACT branch shows (it always fits);
/// the upgrade to the full branch lands within the first layout passes.
struct MeasuredFits<Full: View, Compact: View>: View {
    // NOTE: after crash 4 this construction is the LAW, not an
    // option — ViewThatFits is banned repo-wide (fence), because even
    // data-pure nonisolated candidates trapped on the AsyncRenderer. The
    // sizing engine's reach cannot be enumerated; this container needs no
    // off-main guarantee at all.
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

/// The N-ary sibling of `MeasuredFits` for the two bars: a descending ladder
/// of candidates (best first), each rendered as an invisible natural-size
/// probe on the MAIN render path; the first rung whose probe fits the offered
/// width is the one that gets built for display. Until the widths are known
/// the LAST rung shows (the smallest — the one that must fit, so no title is
/// ever cut while measuring).
///
/// The probes are the REAL rows — no parallel arithmetic that could drift
/// from the rendered truth (the "Hörbüch…" class: a formula that did not
/// know the search capsule). Probe rows should pass `probing: true` where a
/// row carries a `matchedGeometryEffect` (seven hidden copies of one
/// geometry id would fight over it).
struct MeasuredLadder<Row: View>: View {
    let rungs: [CGFloat]
    @ViewBuilder let row: (_ size: CGFloat, _ probing: Bool) -> Row

    @State private var naturalWidths: [CGFloat: CGFloat] = [:]
    @State private var offeredWidth: CGFloat?

    private var chosen: CGFloat {
        guard let offeredWidth else { return rungs.last ?? 0 }
        for rung in rungs {
            if let width = naturalWidths[rung], width <= offeredWidth + 0.5 { return rung }
        }
        return rungs.last ?? 0
    }

    var body: some View {
        row(chosen, false)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { offeredWidth = $0 }
            .background {
                ZStack {
                    ForEach(rungs, id: \.self) { rung in
                        row(rung, true)
                            .fixedSize()
                            .hidden()
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
                                naturalWidths[rung] = $0
                            }
                    }
                }
            }
    }
}
