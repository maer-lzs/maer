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
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    /// Plain reference (actions only), so creating a row subscribes to
    /// nothing; the offline dim resolves in the scope leaf.
    let playerCoordinator: PlayerCoordinator

    var body: some View {
        // An offline, not-downloaded queue entry must dim AND carry the
        // white wifi.slash glyph. Reactive via the ONE scope leaf.
        MediaAvailabilityScope(itemId: item.id) { unavailable in
            Button {
                Task { await playerCoordinator.open(item: item) }
            } label: {
                MediaRowContent(
                    coverURL: router.coverURL(item.id),
                    eyebrow: item.media?.metadata?.authorName ?? item.author,
                    title: item.title,
                    titleDimmed: unavailable,
                    coverDimmed: unavailable,
                    offlineBadge: unavailable,
                    placeholderSystemImage: placeholderSystemImage,
                    // The queue mixes both servers' titles.
                    sourceCapsule: router.sourceLabel(item.id)
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
    }

    /// Cover-less placeholder glyph: the one positive rule. The own rule
    /// here knew podcasts and Subsonic only, so Jellyfin music, radio and
    /// archive music showed a book.
    private var placeholderSystemImage: String {
        MediaFamily.placeholderSymbol(for: item.id, markedForm: ListeningStore.startedForm(item.id))
    }
}
