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
    /// The glyph column grows with the text size.
    @ScaledMetric(relativeTo: .body) var glyphWidth: CGFloat = 24
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
                    .frame(width: glyphWidth)
                // A title of several words takes a second line instead of
                // shrinking ("Listening History" stood smaller than its
                // neighbours); a single word keeps one line and shrinks a
                // little, so it is never hyphenated ("Down-loaded").
                let fit = Self.titleFit(title)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(fit.lines)
                    .minimumScaleFactor(fit.minimumScale)
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

    /// How a tile title fits its width: several words wrap at a space onto
    /// a second line at full size; one word stays on one line and may
    /// shrink a little, because the only way to wrap it is a hyphen.
    nonisolated static func titleFit(_ title: String) -> (lines: Int, minimumScale: CGFloat) {
        title.contains(" ") ? (2, 1) : (1, 0.8)
    }
}

/// One entry-point descriptor of a deck: title, glyph, count and target.
/// Decouples the data from the tile, so a host describes its entries and
/// the grid renders them.
struct CategoryDeckEntry: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// nil hides the numeral (a stock the host does not hold cheaply).
    let count: Int?
    /// The accessibility handle of the tile; nil derives one from the id.
    var accessibilityId: String? = nil
    let action: () -> Void
}

/// THE deck of category tiles: two columns where the width allows, one
/// otherwise. One component for the search deck (audiobooks, music, the
/// library scope) and the music tab's library list, so both surfaces show
/// the same entries in the same form, and a count only where it is known.
struct CategoryDeckGrid: View {
    let entries: [CategoryDeckEntry]
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The columns of every grid of category tiles: two, and one at the
    /// accessibility sizes, where a tile in half the width of a phone cuts
    /// its title even after shrinking it.
    static func columns(for size: DynamicTypeSize) -> [GridItem] {
        let column = GridItem(.flexible(), spacing: 12)
        return size.isAccessibilitySize ? [column] : [column, column]
    }

    var body: some View {
        if !entries.isEmpty {
            LazyVGrid(columns: Self.columns(for: typeSize), spacing: 12) {
                ForEach(entries) { entry in
                    CategoryTile(title: entry.title, systemImage: entry.systemImage,
                                 count: entry.count,
                                 accessibilityId: entry.accessibilityId ?? "deck-tier-\(entry.id)",
                                 action: entry.action)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

/// The row a deck tile opens into: title, an optional source capsule, the
/// count and the chevron. A label only, so a button (the artists of the
/// search) and a navigation link (the groups of the own library) carry
/// the same row.
struct DeckEntryRowLabel: View {
    let title: String
    let count: Int
    var capsule: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if let capsule { OriginCapsule(compact: true, text: capsule, systemImage: nil) }
            Spacer()
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}
