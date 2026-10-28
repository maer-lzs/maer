// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a shuffle draws from, and why it holds nothing when it does. The
/// button says each case in the words the album page already uses
/// (`ShufflePlayButton.start`), so a flight mode no longer reads as a
/// failed server and an empty list no longer reads as either.
nonisolated enum ShufflePool {
    case songs([LibraryItem])
    /// The source answered and named no track.
    case empty
    /// The device has no network, and nothing here to play.
    case offline
    /// The source did not answer.
    case failed

    /// The songs it holds; empty for every other case.
    var items: [LibraryItem] {
        if case .songs(let items) = self { return items }
        return []
    }

    /// A list already in hand: empty means empty.
    static func of(_ items: [LibraryItem]) -> ShufflePool {
        items.isEmpty ? .empty : .songs(items)
    }

    /// A source's songs with the cause of a fetch that failed, if one did
    /// (`MusicSongsFailure`): without the network it is offline, otherwise
    /// a failure; without a failure an empty answer is empty.
    static func of(_ items: [LibraryItem], failure: NoticeCause?) -> ShufflePool {
        guard items.isEmpty else { return .songs(items) }
        guard let failure else { return .empty }
        return failure == .network ? .offline : .failed
    }
}
