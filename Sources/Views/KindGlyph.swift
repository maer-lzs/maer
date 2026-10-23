// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The kind mark of a tile in a MIXED row: which kind this tile is, so a
/// book, an episode, an album and a station side by side tell themselves
/// apart before their covers load. The symbol comes from the one table
/// (`MediaType.systemImage`, the tab bar's glyphs); an id reaches it
/// through `MediaFamily.kind`. On a `MediaTile` the mark is the first of
/// the stack at the top right (`stackedKind`); the other tiles still carry
/// it at the top left (`kindGlyph`) until they take the stack.
struct KindGlyph: View {
    let kind: MediaType

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(5)
            .glyphDisc()
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityLabel(Text(verbatim: kind.label))
    }
}

private struct CoverGlyphKindKey: EnvironmentKey {
    static let defaultValue: MediaType? = nil
}

extension EnvironmentValues {
    /// The kind a `MediaTile` puts first in its stack of marks.
    var coverGlyphKind: MediaType? {
        get { self[CoverGlyphKindKey.self] }
        set { self[CoverGlyphKindKey.self] = newValue }
    }
}

extension View {
    /// Marks a tile of a mixed row with its kind at the top left. nil (an
    /// id no family knows) marks nothing rather than guessing.
    func kindGlyph(_ kind: MediaType?) -> some View {
        overlay(alignment: .topLeading) {
            if let kind { KindGlyph(kind: kind) }
        }
    }

    /// Marks a `MediaTile` of a mixed row with its kind: the tile puts it
    /// first in its stack at the top right. nil marks nothing.
    func stackedKind(_ kind: MediaType?) -> some View {
        environment(\.coverGlyphKind, kind)
    }
}
