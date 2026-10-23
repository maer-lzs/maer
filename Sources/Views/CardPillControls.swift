// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE glyph-and-word pill: a caption glyph and a word in a capsule. The
/// card "Details" pill draws it white on a coloured card, the "Retry" of a
/// failed load in the accent on a list; one anatomy, one inner padding.
struct PillLabel: View {
    let systemImage: String
    let title: Text
    let foreground: Color
    let fill: Color
    /// A dark capsule under the fill (the card pill: the tone of the marks).
    var shade: Color? = nil
    /// The glyph behind the word ("Details ⓘ") instead of in front of it.
    var glyphAfterTitle = false

    var body: some View {
        HStack(spacing: 6) {
            if !glyphAfterTitle { Image(systemName: systemImage).font(.caption) }
            title.font(.subheadline.weight(.medium))
            if glyphAfterTitle { Image(systemName: systemImage).font(.caption) }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        // Solid, semi-transparent capsule instead of material blur. Blur
        // is expensive per frame during horizontal scrolling.
        .background {
            ZStack {
                if let shade { Capsule().fill(shade) }
                Capsule().fill(fill)
            }
        }
    }
}

/// THE card "Details" pill. Book- and PodcastFeaturedCard carried
/// byte-identical private copies and the playlist card is the third caller,
/// so the anatomy lives in ONE component.
/// Bottom-LEFT of a card, opens the detail route; the glyph stands behind
/// the word, "Details ⓘ".
struct CardDetailPill<Value: Hashable>: View {
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            PillLabel(systemImage: "info.circle", title: Text("Details"),
                      foreground: .white, fill: GlyphTone.fill, shade: GlyphTone.shade, glyphAfterTitle: true)
        }
        .buttonStyle(.plain)
    }
}

/// 5219a7: the card's bottom-RIGHT corner button in the EXACT
/// `CardDownloadBadge` capsule anatomy (hidden-X metric line, capsule fill,
/// 44-pt hit frame). An action button variant for cards whose corner is not
/// a download (playlist shuffle). One anatomy, two behaviours.
struct CardCornerButton: View {
    let systemImage: String
    let accessibilityLabel: Text
    var accessibilityId: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(verbatim: "X").font(.subheadline.weight(.medium)).hidden()
                Image(systemName: systemImage).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .glyphCapsule()
            .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl,
                   alignment: .bottomTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityId ?? "card-corner-button")
    }
}
