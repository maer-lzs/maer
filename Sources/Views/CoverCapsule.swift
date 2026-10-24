// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The capsule on a cover's bottom-left corner: a licence on a catalogue
/// tile, a server's name on a music cell while two music servers are active.
/// One component for both, so a tile and a cell carry the same mark.
struct CoverCapsule: View {
    let text: String
    var systemImage: String? = nil
    /// Distance to the cover's edge; a large card sits it further in.
    var inset: CGFloat = 6
    /// Half the height of one line with its padding: one line reads as the
    /// capsule it always was, two lines as a rounded box.
    @ScaledMetric(relativeTo: .caption2) private var radius: CGFloat = 9

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            // Wraps to a second line where the cover is narrower than the
            // text ("Laut Quelle gemeinfrei" on a three-column tile was cut).
            Text(verbatim: text)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .foregroundStyle(.white)
        .padding(inset)
    }
}
