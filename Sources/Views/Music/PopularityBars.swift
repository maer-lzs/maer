// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Up to three rising bars beside a track, filled by how often it was
/// played (`MusicPopularity.bars`). They grow with the text, and VoiceOver
/// says the level in words, since the shape alone carries it.
struct PopularityBars: View {
    let level: Int
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 11

    var body: some View {
        HStack(alignment: .bottom, spacing: height * 0.18) {
            ForEach(1...3, id: \.self) { step in
                Capsule()
                    .fill(step <= level ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: height * 0.28, height: height * CGFloat(step) / 3)
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel(Text(Self.label(level)))
    }

    static func label(_ level: Int) -> String {
        switch level {
        case 3: return String(localized: "Played often")
        case 2: return String(localized: "Played sometimes")
        default: return String(localized: "Played rarely")
        }
    }
}

/// One track row of an album or playlist page: number, title, the play
/// bars when there are any, duration. Its own view so the row can
/// be looked at on its own, at every text size.
struct AlbumTrackRowLabel: View {
    let number: Int
    let title: String
    let duration: String
    let bars: Int
    /// Track-number column scales with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var numberWidth: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Measured at AX3: beside the bars and the duration a title
                // kept four letters. Here it takes the line, and the rest
                // stands on the right below it.
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        numberText
                        Text(title).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    facts
                }
            } else {
                HStack(spacing: 12) {
                    numberText
                    Text(title).lineLimit(1)
                    Spacer()
                    facts
                }
            }
        }
        .contentShape(Rectangle())
    }

    /// Leading in its column, so the number is the row's first mark and
    /// stands where every list's first mark stands (beside the fold too).
    private var numberText: some View {
        Text("\(number)")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: numberWidth, alignment: .leading)
    }

    /// How often this track was played, beside it instead of a second list
    /// above, and its duration.
    private var facts: some View {
        HStack(spacing: 12) {
            if bars > 0 {
                PopularityBars(level: bars)
            }
            Text(duration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
