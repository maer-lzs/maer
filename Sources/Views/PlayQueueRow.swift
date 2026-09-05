// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// One row of the GLOBAL Up-Next queue. Renders any media type. Audiobook,
/// podcast episode, music album/song. Uniformly through the shared
/// `MediaRowContent`. One parametrised component, used by both the
/// Up-Next section and the reorderable queue page). Tapping plays the item,
/// which removes it from the queue via the coordinator ("start = flies out").
struct PlayQueueRow: View {
    let item: LibraryItem
    /// Cell-cost sweep: plain reference (actions only). No subscriptions on
    /// row creation; the A3 dim resolves in the scope leaf.
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        // An offline, not-downloaded queue entry must dim AND carry the
        // white wifi.slash glyph (the A3 rule). Reactive via the ONE scope leaf.
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
        if ItemNamespace.isPodcastEpisode(item.id) { return "mic" }
        if ItemNamespace.isSubsonic(item.id) { return "music.note" }
        return "book.closed"
    }
}
