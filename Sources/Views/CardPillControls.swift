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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption)
            title.font(.subheadline.weight(.medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        // Solid, semi-transparent capsule instead of material blur. Blur
        // is expensive per frame during horizontal scrolling.
        .background(Capsule().fill(fill))
    }
}

/// THE card "Details" pill. Book- and PodcastFeaturedCard carried
/// byte-identical private copies and the playlist card is the third caller,
/// so the anatomy lives in ONE component.
/// Bottom-LEFT of a card, opens the detail route.
struct CardDetailPill<Value: Hashable>: View {
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            PillLabel(systemImage: "info.circle", title: Text("Details"),
                      foreground: .white, fill: .white.opacity(0.22))
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
            .background(Capsule().fill(.white.opacity(0.22)))
            .frame(width: CoverBadge.detailControl, height: CoverBadge.detailControl,
                   alignment: .bottomTrailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityId ?? "card-corner-button")
    }
}
