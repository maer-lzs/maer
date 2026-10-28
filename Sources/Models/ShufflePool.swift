// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a shuffle draws from, and whether a pool that holds nothing is
/// empty or merely did not come. The button says each in the words the
/// album page uses, and like the album page it tells offline from a failed
/// source by the device's network, not by an error code
/// (`ShufflePlayButton.start`).
nonisolated enum ShufflePool {
    case songs([LibraryItem])
    /// The source answered and named no track.
    case empty
    /// The songs did not come: the source did not answer, or the device has
    /// no network.
    case unavailable

    /// The songs it holds; empty for every other case.
    var items: [LibraryItem] {
        if case .songs(let items) = self { return items }
        return []
    }

    /// A list already in hand: empty means empty.
    static func of(_ items: [LibraryItem]) -> ShufflePool {
        items.isEmpty ? .empty : .songs(items)
    }

    /// Songs fetched by a path that turns a failure into no songs: nothing
    /// means they did not come, never that there are none.
    static func fetched(_ items: [LibraryItem]) -> ShufflePool {
        items.isEmpty ? .unavailable : .songs(items)
    }

    /// A server's songs with whether its fetch failed (`MusicSongsFailure`):
    /// an answer without a failure that names no song is empty.
    static func server(_ items: [LibraryItem], failed: Bool) -> ShufflePool {
        guard items.isEmpty else { return .songs(items) }
        return failed ? .unavailable : .empty
    }
}
