// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The drawn titles of a music shuffle play as songs, as a start from an
/// album's own page does: each release of more than one track becomes its
/// songs (`CatalogSongID`), so the queue, "Up Next" and the skips step
/// song by song. A release of one track stays the one title it is.
///
/// One answer per release, never one per song: the songs come the one way
/// a catalogue album's songs come (`ArchiveMusicLoader.albumSongs`), which
/// counts them from the release's metadata answer and builds them from that
/// same kept answer. Only the first title is asked before playback starts;
/// the others wait in the context as themselves and become their songs one
/// after the other, each only while it is still in the context.
@MainActor
enum CatalogShuffleSongs {
    /// A release's songs from its one answer; empty when none came.
    typealias AlbumSongs = (String) async -> [LibraryItem]

    /// What one title plays as: its songs in order when the release holds
    /// more than one track, else the title itself. A cancelled caller gets
    /// nothing, so a start that was called off stays off.
    static func songs(of title: LibraryItem,
                      albumSongs: AlbumSongs = { await ArchiveMusicLoader.albumSongs(albumId: $0, router: .live) })
        async -> [LibraryItem] {
        let songs = await albumSongs(title.id)
        guard !Task.isCancelled else { return [] }
        return songs.count > 1 ? songs : [title]
    }

    /// The first title's songs start; the rest of the draw follows in the
    /// context, each title expanded to its songs at its place.
    static func start(_ titles: [LibraryItem],
                      context: PlaybackContext = .shared,
                      play: ([LibraryItem]) async -> Void,
                      songs: (LibraryItem) async -> [LibraryItem] = { await songs(of: $0) }) async {
        guard let first = titles.first else { return }
        let rest = Array(titles.dropFirst())
        await play(await songs(first) + rest)
        var expanded = 0
        for title in rest where context.ids.contains(title.id) {
            if context.expand(title.id, into: await songs(title).map(\.id)) { expanded += 1 }
        }
        Logger.library.notice("SHUFFLE songs: titles=\(titles.count) expanded=\(expanded) context=\(context.ids.count)")
    }
}
