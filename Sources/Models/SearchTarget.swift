// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a tap on a search hit means. The DECISION, not the doing: the
/// view performs it (it owns the navigation path), the rule decides it.
///
/// This is the second of the search door's two questions. It used to live
/// in `LibraryView.openSearchResult`, at a caller that has nothing to do
/// with searching, and it was the reason a new hit kind could be added
/// without anybody noticing that it went nowhere.
nonisolated enum SearchTarget: Equatable {
    /// A book page, addressed by its item id.
    case book(itemId: String)
    /// An episode page.
    case episode(itemId: String)
    /// A show page, addressed by its feed address (catalog shows too: a
    /// catalog show IS a feed nobody follows yet).
    case show(feedURL: String)
    /// A catalog work with parts: its series page.
    case catalogSeries(itemId: String)
    /// A catalog work without parts: the detail sheet.
    case catalogBook(itemId: String)
    /// An album or a playlist. Both push the SAME music route; a playlist
    /// detail is not a second mechanism.
    case album(itemId: String)
    /// An artist page, addressed by the provider's raw artist id.
    case artist(rawId: String)
    /// Songs and stations start playing instead of routing anywhere.
    case play(itemId: String)
    /// Authors and series drill down inside the search overlay and are
    /// never routed out of it.
    case drillInPlace
    /// The hit cannot be opened right now (offline, gone from the source).
    /// The surface says so; it never silently does nothing.
    case unavailable
}

/// What the target rule may ask about the world. Closures instead of the
/// session itself, so the rule is testable without an app.
nonisolated struct SearchLookups {
    /// Does the session know this id as a library item?
    var item: (String) -> Bool
    /// Does the free catalog hold a parts list for this id?
    var catalogHasParts: (String) -> Bool
    /// Does the free catalog know this id at all?
    var catalogKnows: (String) -> Bool
    /// The provider's raw artist id inside an item id, if it is one.
    var artistId: (String) -> String?
    /// Is that artist known to the provider?
    var artistKnown: (String) -> Bool

    init(item: @escaping (String) -> Bool,
         catalogHasParts: @escaping (String) -> Bool,
         catalogKnows: @escaping (String) -> Bool,
         artistId: @escaping (String) -> String?,
         artistKnown: @escaping (String) -> Bool) {
        self.item = item
        self.catalogHasParts = catalogHasParts
        self.catalogKnows = catalogKnows
        self.artistId = artistId
        self.artistKnown = artistKnown
    }
}

nonisolated enum SearchRouting {
    /// The one place that decides where a hit leads. Every kind is named:
    /// the switch is exhaustive on purpose, so a new hit kind cannot be
    /// added without answering this question.
    static func target(for result: SearchResult, lookups: SearchLookups) -> SearchTarget {
        switch result.kind {
        case .book:
            return .book(itemId: result.id)
        case .episode:
            return .episode(itemId: result.id)
        case .show, .catalogShow:
            return .show(feedURL: result.id)
        case .catalogBook:
            if lookups.catalogHasParts(result.id) { return .catalogSeries(itemId: result.id) }
            return lookups.catalogKnows(result.id) ? .catalogBook(itemId: result.id) : .unavailable
        case .album, .playlist:
            return lookups.item(result.id) ? .album(itemId: result.id) : .unavailable
        case .artist:
            guard let raw = lookups.artistId(result.id), lookups.artistKnown(raw) else { return .unavailable }
            return .artist(rawId: raw)
        case .song, .radioStation:
            return lookups.item(result.id) ? .play(itemId: result.id) : .unavailable
        case .author, .series:
            return .drillInPlace
        }
    }
}
