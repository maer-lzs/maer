// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE category tile. One chip idiom, not two: glyph top-left (accent),
/// count top-right (hidden when nil), title below, rounded field. Born as the
/// search deck's entry tile; the music genre grid reuses it, so both surfaces
/// stay identical by construction.
struct CategoryTile: View {
    let title: String
    let systemImage: String
    /// Numeral top-right; nil hides it (Jellyfin genres ship no counts).
    var count: Int? = nil
    var accessibilityId: String? = nil
    /// Selected tiles carry the accent fill. The same tile serves as a
    /// navigation entry and as a selector, so the state is a parameter.
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        // FLAT single-line anatomy (was a 92-pt stacked field).
        // Glyph · title · count in one row, ~56 pt total: markedly flatter,
        // still comfortably readable, tap target well above the 44-pt floor.
        // One component. The search deck, podcast genre chips and music
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
                .fill(isSelected ? AnyShapeStyle(AppTheme.accent.opacity(0.18))
                                 : AnyShapeStyle(Color.primary.opacity(0.06))))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId ?? "category-tile-\(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
