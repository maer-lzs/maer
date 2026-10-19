// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// When a music server counts a play: once per song of an album or a
/// playlist, as the song starts. The Subsonic and the Jellyfin provider ask
/// this one rule on every progress call.
nonisolated enum ScrobbleTurn {
    typealias Song = (id: String, start: Double)

    /// The song playing at `currentTime` within an item's songs: the last one
    /// that has started, with half a second of slack, so a position written
    /// just before the next song's start counts for that song. Nil before
    /// the first.
    static func song(at currentTime: Double, in songs: [Song]) -> Song? {
        songs.last(where: { $0.start <= currentTime + 0.5 })
    }

    /// The song whose play is counted now: the playing one, unless it is the
    /// one counted last for this item.
    static func due(_ playing: Song?, last: String?) -> String? {
        guard let playing, playing.id != last else { return nil }
        return playing.id
    }
}
