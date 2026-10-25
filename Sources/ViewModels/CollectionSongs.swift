// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The songs of an album as single playable items, below the views: what
/// the long-press Shuffle of an album tile draws from (`CollectionMenuItems`).
/// The tiles only hand the answer on.
@MainActor
enum CollectionSongs {
    /// A server album's songs, from its own server.
    static func server(_ itemId: String) async -> [LibraryItem] {
        await AppSession.shared.musicProvider(for: itemId).songItems(forItemId: itemId)
    }

    /// A catalogue album's songs: its detail counts them, the catalogue
    /// names each. `router` answers the item's source.
    static func catalog(_ itemId: String, router: ItemRouter = .live) async -> [LibraryItem] {
        // A missing detail is bearable, because an empty pool starts nothing.
        let detail = try? await router.provider(itemId).fetchItemDetail(itemId: itemId)
        return await FreeCatalogProvider.shared.albumSongs(
            albumId: itemId, count: detail?.media.tracks?.count ?? 0).songs
    }
}
