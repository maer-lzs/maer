// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One row of the GLOBAL Up-Next queue. Renders any media type — audiobook,
/// podcast episode, music album/song — uniformly through the shared
/// `MediaRowContent` (Regel 2: one parametrised component, used by both the
/// Up-Next section and the reorderable queue page). Tapping plays the item,
/// which removes it from the queue via the coordinator ("start = flies out").
struct PlayQueueRow: View {
    let item: LibraryItem
    /// Cell-cost sweep: plain reference (actions only) — no subscriptions on
    /// row creation; the A3 dim resolves in the scope leaf.
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        // Y60: an offline, not-downloaded queue entry must dim AND carry the
        // white wifi.slash glyph (the A3 rule) — reactive via the ONE scope leaf.
        MediaAvailabilityScope(itemId: item.id) { unavailable in
            Button {
                Task { await playerCoordinator.open(item: item) }
            } label: {
                MediaRowContent(
                    coverURL: AppSession.shared.coverURL(forItemId: item.id),
                    eyebrow: item.media?.metadata?.authorName ?? item.author,
                    title: item.title,
                    titleDimmed: unavailable,
                    coverDimmed: unavailable,
                    offlineBadge: unavailable,
                    placeholderSystemImage: placeholderSystemImage
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    /// Cover-less placeholder glyph by media type.
    private var placeholderSystemImage: String {
        if item.id.hasPrefix("rss:") || item.id.hasPrefix("abspod:") { return "mic" }
        if item.id.hasPrefix("sub:") { return "music.note" }
        return "book.closed"
    }
}
