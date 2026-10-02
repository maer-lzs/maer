// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Reconstruct a playlist's continue-listening position from a
/// Subsonic per-song bookmark. A playlist is one multi-track item with a single
/// `currentTime` over the whole thing (like a multi-file book); a bookmark only
/// knows song + position-within-song, so the enclosing offset must be added back.
/// The SAME `songsByItemId` (id, start) mapping the scrobble uses, never a
/// second arithmetic. Foundation-only, pure, tested.
nonisolated enum BookmarkProgressMath {
    /// The multi-track `currentTime` for a bookmark: the bookmarked song's start
    /// offset within the playlist + the position inside that song. Returns nil
    /// when the song is no longer in the playlist (edited since last listen). The
    /// caller drops it from continue rather than showing something broken.
    static func playlistCurrentTime(songId: String, positionMs: Int,
                                    songs: [(id: String, start: Double)]) -> Double? {
        guard let song = songs.first(where: { $0.id == songId }) else { return nil }
        return song.start + max(0, Double(positionMs) / 1000)
    }

    /// A `BookProgress` from an absolute position within a known total duration.
    ///
    /// `stored` is the raw mark when the position came from `localPosition`.
    /// Then the duration it was written against decides, not today's. Callers
    /// that judge a server payload (position and duration from the same
    /// response) pass nil.
    static func progress(currentTime: Double, duration: Double, lastUpdate: Double,
                         stored: [Double]? = nil) -> BookProgress {
        let fraction = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
        let finished = stored.map { ProgressMark.reachedEnd(stored: $0, currentDuration: duration) }
            ?? ProgressMark.reachedEnd(position: currentTime, duration: duration)
        return BookProgress(
            fraction: fraction,
            isFinished: finished,
            lastUpdate: lastUpdate,
            currentTime: currentTime)
    }

    /// Of several bookmarks for the SAME playlist (one per song played), the one
    /// to resume at is the most recently changed. Returns its index in `stamps`
    /// (ms since 1970), or nil for an empty input.
    static func mostRecent(_ stamps: [Double]) -> Int? {
        guard !stamps.isEmpty else { return nil }
        return stamps.indices.max(by: { stamps[$0] < stamps[$1] })
    }

    /// The stand of a multi-track item (a playlist, an album, a Booksonic
    /// book) from the server's bookmarks: those whose comment names the
    /// item, each put back on the item's time line by its song's offset,
    /// the most recently changed one wins. Nil when none maps: no bookmark
    /// for the item, or its song has left the item. The ONE rule for the
    /// library read and the resume on open. `key` is the form in which a
    /// comment and the item are compared: a comment written before the
    /// server gave its ids a new form names the same item in the old one.
    static func resume(bookmarks: [SubsonicBookmark], itemId: String,
                       songs: [(id: String, start: Double)],
                       stamp: (SubsonicBookmark) -> Double,
                       key: (String) -> String = { $0 }) -> (time: Double, stamp: Double)? {
        let item = key(itemId)
        let candidates: [(time: Double, stamp: Double)] = bookmarks
            .filter { $0.comment.map(key) == item }
            .compactMap { bookmark in
                guard let songId = bookmark.entry?.id,
                      let time = playlistCurrentTime(songId: songId, positionMs: bookmark.position ?? 0, songs: songs)
                else { return nil }
                return (time, stamp(bookmark))
            }
        guard let index = mostRecent(candidates.map(\.stamp)) else { return nil }
        return candidates[index]
    }
}
