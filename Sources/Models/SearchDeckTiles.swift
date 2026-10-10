// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The kinds of groups of the own library. One page lists the groups of a
/// kind (`LibraryListRoute.groups`); the books tab and the search deck open
/// the same page, with the same title and glyph.
nonisolated enum BookGroupKind: String, CaseIterable, Hashable, Sendable {
    case authors, series, genres

    var title: String {
        switch self {
        case .authors: return String(localized: "Authors")
        case .series: return String(localized: "Series")
        case .genres: return String(localized: "Genres")
        }
    }

    var systemImage: String {
        switch self {
        case .authors: return "person.2.fill"
        case .series: return "books.vertical.fill"
        case .genres: return "theatermasks.fill"
        }
    }
}

/// Where a deck tile leads. The rule NAMES the destination, the view
/// performs it, because only the view owns the navigation path and the
/// scope binding. Without this the target of a tile lived inside a
/// closure that no test could reach.
nonisolated enum SearchDeckDestination: Hashable, Sendable {
    /// The page of the groups of one kind of the own library (authors,
    /// series, genres), the same page the books tab opens.
    case group(BookGroupKind)
    /// Drill into the artists of the music source. Needs the music scope,
    /// so it switches there first when it is called from the library scope.
    case artists
    /// Switch the scope bar. The library scope uses this for the entries
    /// that have a scope of their own.
    case scope(SearchScope)
    /// The music library pages.
    case albums, songs, playlists, genres
    /// What is on the device. The deck carried every other library entry
    /// point and not this one, while the tab had it.
    case downloaded
    /// One free music shelf, by its area.
    case shelf(ArchiveMusicArea)
}

/// One entry point of the browse deck.
nonisolated struct SearchDeckTile: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    /// nil hides the numeral, for a stock the deck does not hold cheaply.
    let count: Int?
    let destination: SearchDeckDestination
}

/// What the deck knows about the size of each entry point.
nonisolated struct SearchDeckCounts: Equatable, Sendable {
    var authors = 0
    var series = 0
    var genres = 0
    var shows = 0
    var albums = 0
    /// nil while the music source has not answered yet.
    var artists: Int?
    /// The music items on the device. Counted by the ONE rule
    /// (`MediaFamily.musicCount`), so the tab and the deck cannot disagree.
    var downloaded = 0
}

/// The entry points of the browse deck, per scope. A pure table: it decides
/// which tiles exist, what they are called, which stock they show and where
/// they lead. Podcasts and radio have none, because there a show and a
/// station ARE the unit and the raster below already lists them.
nonisolated enum SearchDeckTiles {
    static func tiles(scope: SearchScope, counts: SearchDeckCounts) -> [SearchDeckTile] {
        switch scope {
        case .audiobooks:
            return libraryTiles(counts: counts)
        case .music:
            return musicTiles(counts: counts)
        case .podcasts, .radio:
            return []
        case .library:
            // The mixed deck: the book entries, then one tile per other
            // scope. Those SWITCH the scope instead of navigating, so the
            // library scope stays an overview and never becomes a second
            // music tab.
            return libraryTiles(counts: counts) + [
                SearchDeckTile(id: "shows", title: String(localized: "Shows"),
                               systemImage: "mic.fill", count: counts.shows,
                               destination: .scope(.podcasts)),
                artistTile(counts: counts),
                SearchDeckTile(id: "albums", title: String(localized: "Albums"),
                               systemImage: "square.stack.fill", count: counts.albums,
                               destination: .scope(.music)),
            ]
        }
    }

    private static func libraryTiles(counts: SearchDeckCounts) -> [SearchDeckTile] {
        [(BookGroupKind.authors, counts.authors), (.series, counts.series), (.genres, counts.genres)].map { kind, count in
            SearchDeckTile(id: kind.rawValue, title: kind.title, systemImage: kind.systemImage,
                           count: count, destination: .group(kind))
        }
    }

    /// The music deck offers every library entry point as a tile. Counts
    /// render where the deck knows them; the pages themselves load fresh.
    private static func musicTiles(counts: SearchDeckCounts) -> [SearchDeckTile] {
        [
            artistTile(counts: counts),
            SearchDeckTile(id: "music-albums", title: String(localized: "Albums"),
                           systemImage: "square.stack.fill", count: counts.albums,
                           destination: .albums),
            SearchDeckTile(id: "music-songs", title: String(localized: "Songs"),
                           systemImage: "music.note", count: nil, destination: .songs),
            SearchDeckTile(id: "music-playlists", title: String(localized: "Playlists"),
                           systemImage: "music.note.list", count: nil, destination: .playlists),
            SearchDeckTile(id: "music-genres", title: String(localized: "Genres"),
                           systemImage: "guitars", count: nil, destination: .genres),
            // The sixth entry, and it belongs to the OWN library like the
            // five above it. The deck used to carry a single free shelf here
            // instead, one of ten and not the largest, while what is on the
            // device had no tile at all.
            SearchDeckTile(id: "music-downloaded", title: String(localized: "Downloaded"),
                           systemImage: "arrow.down.circle", count: counts.downloaded,
                           destination: .downloaded),
        ]
    }

    /// No numeral until the music source has answered. A 0 there is a
    /// number the deck does not know: while the source is offline or
    /// failing it never answers, and the tile would claim there are no
    /// artists. The music tab's list holds the same rule.
    private static func artistTile(counts: SearchDeckCounts) -> SearchDeckTile {
        SearchDeckTile(id: "artists", title: String(localized: "Artists"),
                       systemImage: "music.mic", count: counts.artists,
                       destination: .artists)
    }
}
