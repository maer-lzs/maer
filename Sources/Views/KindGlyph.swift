// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The kind mark of a tile in a MIXED row: which kind this tile is, so a
/// book, an episode, an album and a station side by side tell themselves
/// apart before their covers load. The symbol comes from the one table
/// (`MediaType.systemImage`, the tab bar's glyphs); an id reaches it
/// through `MediaFamily.kind`. The mark sits top-leading on the cover,
/// the one corner no tile uses (lock top-trailing, control
/// bottom-trailing, show badge and licence bottom-leading), in the same
/// form as the station favourite star.
struct KindGlyph: View {
    let kind: MediaType

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(.black.opacity(0.45)))
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityLabel(Text(verbatim: kind.label))
    }
}

extension View {
    /// Marks a tile of a mixed row with its kind. nil (an id no family
    /// knows) marks nothing rather than guessing.
    func kindGlyph(_ kind: MediaType?) -> some View {
        overlay(alignment: .topLeading) {
            if let kind { KindGlyph(kind: kind) }
        }
    }
}
