// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The songs of a server album as single playable items, below the views:
/// what the long-press Shuffle of an album tile draws from
/// (`CollectionMenuItems`). A catalogue album's songs come from the music
/// loader (`ArchiveMusicLoader.albumSongs`). The tiles only hand the answer on.
@MainActor
enum CollectionSongs {
    /// A server album's songs, from its own server.
    static func server(_ itemId: String) async -> [LibraryItem] {
        await AppSession.shared.musicProvider(for: itemId).songItems(forItemId: itemId)
    }

    /// The same songs as a shuffle's pool, with why it is empty when it is.
    static func serverPool(_ itemId: String) async -> ShufflePool {
        _ = MusicSongsFailure.take(itemId)
        let songs = await server(itemId)
        return .of(songs, failure: MusicSongsFailure.take(itemId))
    }
}
