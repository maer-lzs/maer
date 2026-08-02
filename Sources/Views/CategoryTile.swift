// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// THE category tile (Regel 2 — one chip idiom, not two): glyph top-left
/// (accent), count top-right (hidden when nil), title below, rounded field.
/// Born as the search deck's entry tile (Y43); M3 reuses it for the music
/// genre grid, so both surfaces stay identical by construction.
struct CategoryTile: View {
    let title: String
    let systemImage: String
    /// Numeral top-right; nil hides it (Jellyfin genres ship no counts).
    var count: Int? = nil
    var accessibilityId: String? = nil
    let action: () -> Void

    var body: some View {
        // b34966c: FLAT single-line anatomy (was a 92-pt stacked field) —
        // glyph · title · count in one row, ~56 pt total: markedly flatter,
        // still comfortably readable, tap target well above the 44-pt floor.
        // One component — the search deck, podcast genre chips and music
        // genres all flatten together.
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let count {
                    Text("\(count)")
                        .font(.footnote).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId ?? "category-tile-\(title)")
    }
}
