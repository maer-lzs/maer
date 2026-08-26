// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE single download-progress indicator for every media type (books,
/// podcasts, music). A subtle determinate ring when the total size is known,
/// an indeterminate spinner for the `-1` sentinel (server sent no
/// Content-Length). Ring/spinner only — tap-to-cancel is supplied by the
/// enclosing control (`DownloadRing` button, `DownloadInstallRing` overlay).
/// The determinate case uses a custom trim arc rather than
/// `ProgressView(value:).circular`, which does not render determinately on iOS.
struct UnifiedDownloadRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 3
    var tint: Color = .secondary

    var body: some View {
        if fraction < 0 {
            // Unknown size → indeterminate spinner.
            ProgressView()
                .tint(tint)
        } else {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.3), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .animation(.linear(duration: 0.3), value: fraction)
        }
    }
}

/// Small inline download indicator for the control clusters (podcast row/card,
/// music album). Thin wrapper around `UnifiedDownloadRing` so every surface
/// shares the same look and the same determinate/indeterminate behaviour.
struct DownloadRing: View {
    let fraction: Double
    var tint: Color = .secondary

    var body: some View {
        UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: tint)
            // Matches the former ProgressView footprint in the 44pt controls.
            .frame(width: 22, height: 22)
    }
}
