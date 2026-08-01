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
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(AppTheme.accent)
                    Spacer()
                    if let count {
                        Text("\(count)")
                            .font(.subheadline).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId ?? "category-tile-\(title)")
    }
}
