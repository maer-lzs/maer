// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The drawn titles of a music shuffle play as songs, as a start from an
/// album's own page does: each release of more than one track becomes its
/// songs (`CatalogSongID`), so the queue, "Up Next" and the skips step
/// song by song. A release of one track stays the one song it is.
///
/// One answer per release, never one per song: the track count comes from
/// the release's metadata answer, and the songs are built from that same
/// kept answer (`FreeCatalogProvider.albumSongs`). Only the first title is
/// asked before playback starts; the others wait in the context as
/// themselves and become their songs one after the other, each only while
/// it is still in the context.
@MainActor
enum CatalogShuffleSongs {
    /// The track count of a release, from its one answer; nil when none came.
    typealias TrackCount = (String) async -> Int?
    /// A release's songs, from the same answer.
    typealias AlbumSongs = (String, Int) async -> [LibraryItem]

    /// What one title plays as: its songs in order when the release holds
    /// more than one track, else the title itself.
    static func songs(of title: LibraryItem,
                      trackCount: TrackCount = liveTrackCount,
                      albumSongs: AlbumSongs = liveAlbumSongs) async -> [LibraryItem] {
        guard let count = await trackCount(title.id), count > 1 else { return [title] }
        let songs = await albumSongs(title.id, count)
        return songs.isEmpty ? [title] : songs
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

    static func liveTrackCount(_ itemId: String) async -> Int? {
        do {
            return try await FreeCatalogProvider.shared.fetchItemDetail(itemId: itemId).media.tracks?.count
        } catch {
            Logger.library.notice("SHUFFLE songs: no track count for \(itemId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
            return nil
        }
    }

    static func liveAlbumSongs(_ albumId: String, _ count: Int) async -> [LibraryItem] {
        await ArchiveMusicLoader.albumSongs(albumId: albumId, count: count).songs
    }
}
