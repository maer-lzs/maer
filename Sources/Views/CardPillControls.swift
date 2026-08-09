// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// 5219a7: THE card "Details" pill — Book- and PodcastFeaturedCard carried
/// byte-identical private copies; the playlist card is the third caller, so
/// the anatomy moves into ONE component (Regel 2: extend, don't copy).
/// Bottom-LEFT of a card, opens the detail route.
struct CardDetailPill<Value: Hashable>: View {
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.caption)
                Text("Details").font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Solid, semi-transparent capsule instead of material blur — blur
            // is expensive per frame during horizontal scrolling.
            .background(Capsule().fill(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// 5219a7: the card's bottom-RIGHT corner button in the EXACT
/// `CardDownloadBadge` capsule anatomy (hidden-X metric line, capsule fill,
/// 44-pt hit frame) — an action button variant for cards whose corner is not
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
