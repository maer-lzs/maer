// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The tone of every mark and pill on a cover or card: the fill of the
/// card's Details pill. One constant, so a change of tone is this line.
enum GlyphTone {
    static let fill = Color.white.opacity(0.22)
}

/// THE stack of state marks at the top right of a cover: the marks the
/// tile carries, one under the other in the order of `CoverGlyphs`, as
/// many as fit above the bottom right control. A mark that does not fit
/// is still said to VoiceOver. Each mark keeps its own view and its own
/// inset, so a single mark stands where it stood alone.
struct CoverGlyphStack<Glyph: View>: View {
    let present: [CoverGlyph]
    let room: Int
    /// What VoiceOver hears for a mark that does not fit.
    let label: (CoverGlyph) -> Text
    @ViewBuilder let glyph: (CoverGlyph) -> Glyph

    var body: some View {
        let split = CoverGlyphs.stack(present, room: room)
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(split.shown, id: \.self) { glyph($0) }
        }
        // Marks are states, not controls: a tap on one reaches the tile.
        .allowsHitTesting(false)
        .overlay {
            if let first = split.hidden.first {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(split.hidden.dropFirst().reduce(label(first)) { $0 + Text(verbatim: ", ") + label($1) })
            }
        }
    }
}
