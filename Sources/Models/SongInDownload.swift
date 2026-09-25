// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A single server song that lies on the device as a track of a downloaded
/// album or server playlist of the SAME server. A song taken into a Mär list
/// keeps its own id (`sub:song:…`, `jf:song:…`) and was never downloaded by
/// that id, so without this it counted as missing offline while its file sat
/// in the album's folder. Pure: the downloader asks it and answers the one
/// question "is it here" for the player and the tile alike.
nonisolated enum SongInDownload {
    struct Place: Equatable, Sendable {
        /// The download that holds the file.
        let downloadId: String
        /// The track index, which is also the file's name in that download.
        let trackIndex: Int
    }

    /// Every server song held inside a complete download, by its item id.
    /// A download counts only when it is complete (`downloaded`) and its
    /// detail names the tracks; the detail's track `contentUrl` is the
    /// server's raw song id (`MusicTrackAssembly`).
    static func index(details: [String: LibraryItemDetail], downloaded: Set<String>) -> [String: Place] {
        var places: [String: Place] = [:]
        for downloadId in downloaded.sorted() {
            guard let namespace = ItemNamespace.songHolderNamespace(downloadId),
                  let tracks = details[downloadId]?.media.tracks else { continue }
            for (position, track) in tracks.enumerated() {
                let songId = ItemNamespace.serverSongId(namespace: namespace, rawId: track.contentUrl)
                // The first download that holds a song keeps it; ids are
                // walked sorted so every run picks the same one.
                if places[songId] == nil {
                    places[songId] = Place(downloadId: downloadId, trackIndex: track.index ?? position)
                }
            }
        }
        return places
    }

    /// The song as a one-track item, cut from the holding download's detail:
    /// its duration, its title (the chapter of the same position), the
    /// album's artist. Nil when the detail does not hold that track.
    static func detail(songId: String, place: Place, in holder: LibraryItemDetail) -> LibraryItemDetail? {
        guard let tracks = holder.media.tracks,
              let position = tracks.firstIndex(where: { ($0.index ?? -1) == place.trackIndex })
                ?? (tracks.indices.contains(place.trackIndex) ? place.trackIndex : nil) else { return nil }
        let track = tracks[position]
        let duration = track.duration ?? 0
        let title = holder.media.chapters?.first { $0.id == position }?.title
        return LibraryItemDetail(
            id: songId,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: title, authorName: holder.media.metadata?.authorName, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: duration,
                chapters: [ABSChapter(id: 0, start: 0, end: duration, title: title ?? "")],
                tracks: [ABSAudioTrack(index: 0, startOffset: 0, duration: duration,
                                       contentUrl: track.contentUrl, metadata: track.metadata)]),
            userMediaProgress: nil)
    }
}
