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

/// The song each item counted last, and the one way a music provider counts
/// a play: booked before it is sent, so a call during the send does not
/// count it twice, and taken back when the server refuses, so the next call
/// asks again. A class, because the booking stands across the send.
@MainActor
final class ScrobbleBook {
    private(set) var last: [String: String] = [:]

    /// Counts the song playing in `itemId` when it is due. A refused count
    /// comes back with its song for the provider's own line; nil otherwise.
    func count(_ playing: ScrobbleTurn.Song?, in itemId: String,
               send: (String) async throws -> Void) async -> (song: String, error: Error)? {
        guard let due = ScrobbleTurn.due(playing, last: last[itemId]) else { return nil }
        last[itemId] = due
        do {
            try await send(due)
            return nil
        } catch {
            last[itemId] = nil
            return (due, error)
        }
    }

    /// The item was loaded anew: its next song counts again.
    func forget(_ itemId: String) { last[itemId] = nil }
}
