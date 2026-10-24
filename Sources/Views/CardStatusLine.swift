// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The status line of a featured card (time left · last heard, or played),
/// the one form for the book and the podcast cards. One line at the usual
/// sizes; above them two lines, held on every card, so the line wraps
/// instead of being cut and the cards of a row keep one height. The cards
/// cap their type at accessibility1.
struct CardStatusLine: View {
    let text: String
    var played = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let lines = Self.lines(for: dynamicTypeSize)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if played { Image(systemName: "checkmark.circle.fill") }
            Text(text).lineLimit(lines, reservesSpace: lines > 1)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.85))
    }

    /// How many lines the status line holds at a type size.
    nonisolated static func lines(for size: DynamicTypeSize) -> Int {
        size > .large ? 2 : 1
    }
}
