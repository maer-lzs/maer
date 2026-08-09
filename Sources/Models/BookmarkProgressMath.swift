// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Package 3: reconstruct a playlist's continue-listening position from a
/// Subsonic per-song bookmark. A playlist is one multi-track item with a single
/// `currentTime` over the whole thing (like a multi-file book); a bookmark only
/// knows song + position-within-song, so the enclosing offset must be added back
/// — the SAME `songsByItemId` (id, start) mapping the scrobble uses (Regel 2, no
/// second arithmetic). Foundation-only, pure, tested.
nonisolated enum BookmarkProgressMath {
    /// The multi-track `currentTime` for a bookmark: the bookmarked song's start
    /// offset within the playlist + the position inside that song. Returns nil
    /// when the song is no longer in the playlist (edited since last listen) — the
    /// caller drops it from continue rather than showing something broken.
    static func playlistCurrentTime(songId: String, positionMs: Int,
                                    songs: [(id: String, start: Double)]) -> Double? {
        guard let song = songs.first(where: { $0.id == songId }) else { return nil }
        return song.start + max(0, Double(positionMs) / 1000)
    }

    /// A `BookProgress` from an absolute position within a known total duration.
    static func progress(currentTime: Double, duration: Double, lastUpdate: Double) -> BookProgress {
        let fraction = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
        return BookProgress(
            fraction: fraction,
            isFinished: duration > 0 && currentTime >= duration - 1,
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
}
