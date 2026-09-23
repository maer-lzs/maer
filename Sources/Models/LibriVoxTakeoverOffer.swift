// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS


import Foundation

/// What the catalog detail page may offer for taking a LibriVox book into
/// the library. Nothing is offered that cannot be delivered (the product
/// rule of 17.08.): without the book in the catalog there is nothing to import and
/// nothing to subscribe, and a menu without an entry is no offer either.
nonisolated enum LibriVoxTakeoverOffer {
    struct Offers: Equatable {
        /// Upload into an Audiobookshelf audiobook library.
        var server: Bool
        /// Subscribe to the book's feed on this device.
        var feed: Bool
        var any: Bool { server || feed }
    }

    static func offers(book: LibriVoxBook?, hasServerLibraries: Bool) -> Offers {
        guard let book else { return Offers(server: false, feed: false) }
        return Offers(server: hasServerLibraries, feed: book.url_rss?.isEmpty == false)
    }
}
