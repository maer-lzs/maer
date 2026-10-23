// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The tone of every mark and pill on a cover or card: the fill of the
/// card's Details pill over a dark disc, so it carries on a light cover
/// too. One place, so a change of tone is these lines.
enum GlyphTone {
    static let fill = Color.white.opacity(0.22)
    static let shade = Color.black.opacity(0.35)
}

extension View {
    /// THE disc of a mark or a corner control on a cover: the dark shade,
    /// the tone over it.
    func glyphDisc() -> some View {
        background {
            ZStack {
                Circle().fill(GlyphTone.shade)
                Circle().fill(GlyphTone.fill)
            }
        }
    }
}

/// THE stack of state marks at the top right of a cover: the marks the
/// tile carries, one under the other in the order of `CoverGlyphs`, as
/// many as fit above the bottom right control. A mark that does not fit
/// is still said to VoiceOver. Each mark keeps its own view and its own
/// inset, so a single mark stands where it stood alone. The marks grow
/// with the text up to the first accessibility size and no further:
/// measured at AX3, a 150 pt tile held only one grown mark above its play
/// control.
struct CoverGlyphStack<Glyph: View>: View {
    let present: [CoverGlyph]
    /// The side of the cover, nil until measured (hides nothing).
    let coverSide: CGFloat?
    /// The side of the control at the bottom right, as the tile draws it.
    let cornerSide: CGFloat
    /// What VoiceOver hears for a mark that does not fit.
    let label: (CoverGlyph) -> Text
    @ViewBuilder let glyph: (CoverGlyph) -> Glyph

    /// The largest text size the marks grow with.
    static var largestSize: DynamicTypeSize { .accessibility1 }

    var body: some View {
        Marks(present: present, coverSide: coverSide, cornerSide: cornerSide, label: label, glyph: glyph)
            .dynamicTypeSize(...Self.largestSize)
    }

    /// The marks under the capped text size, so the height of one mark is
    /// measured at the size they are drawn in.
    private struct Marks: View {
        let present: [CoverGlyph]
        let coverSide: CGFloat?
        let cornerSide: CGFloat
        let label: (CoverGlyph) -> Text
        let glyph: (CoverGlyph) -> Glyph
        /// The height one mark takes in the stack: the offline disc and the
        /// lock with their insets.
        @ScaledMetric(relativeTo: .title3) private var glyphSide: CGFloat = 32

        var body: some View {
            let room = CoverGlyphs.room(coverSide: coverSide.map(Double.init), glyphSide: glyphSide,
                                        cornerSide: cornerSide)
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
}
