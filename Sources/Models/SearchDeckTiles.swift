// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which groups of the own library the deck drills into.
nonisolated enum SearchDeckGroup: String, CaseIterable, Sendable {
    case authors, series, genres
}

/// Where a deck tile leads. The rule NAMES the destination, the view
/// performs it, because only the view owns the navigation path and the
/// scope binding. Without this the target of a tile lived inside a
/// closure that no test could reach.
nonisolated enum SearchDeckDestination: Hashable, Sendable {
    /// Drill into the grouped own library (authors, series, genres).
    case group(SearchDeckGroup)
    /// Drill into the artists of the music source. Needs the music scope,
    /// so it switches there first when it is called from the library scope.
    case artists
    /// Switch the scope bar. The library scope uses this for the entries
    /// that have a scope of their own.
    case scope(SearchScope)
    /// The music library pages.
    case albums, songs, playlists, genres
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
}

/// The entry points of the browse deck, per scope. A pure table: it decides
/// which tiles exist, what they are called, which stock they show and where
/// they lead. Podcasts and radio have none, because there a show and a
/// station ARE the unit and the raster below already lists them.
nonisolated enum SearchDeckTiles {
    static func tiles(scope: SearchScope, counts: SearchDeckCounts,
                      shellacActive: Bool) -> [SearchDeckTile] {
        switch scope {
        case .audiobooks:
            return libraryTiles(counts: counts)
        case .music:
            return musicTiles(counts: counts, shellacActive: shellacActive)
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
        [
            SearchDeckTile(id: "authors", title: String(localized: "Authors"),
                           systemImage: "person.2.fill", count: counts.authors,
                           destination: .group(.authors)),
            SearchDeckTile(id: "series", title: String(localized: "Series"),
                           systemImage: "books.vertical.fill", count: counts.series,
                           destination: .group(.series)),
            SearchDeckTile(id: "genres", title: String(localized: "Genres"),
                           systemImage: "theatermasks.fill", count: counts.genres,
                           destination: .group(.genres)),
        ]
    }

    /// The music deck offers every library entry point as a tile. Counts
    /// render where the deck knows them; the pages themselves load fresh.
    private static func musicTiles(counts: SearchDeckCounts,
                                   shellacActive: Bool) -> [SearchDeckTile] {
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
        ]
        // The free shelf lives in the DISCOVER context, the library list
        // stays personal. It follows the 78s: their row visible, their
        // source allowed. Two questions, no third level. The title comes
        // from the DATA, so the shelf cannot be called one thing in the row
        // and another in the deck.
        + (shellacActive
            ? [SearchDeckTile(id: "music-free-classical",
                              title: ArchiveMusicCatalog.classical.title,
                              systemImage: "music.quarternote.3", count: nil,
                              destination: .shelf(ArchiveMusicCatalog.classical))]
            : [])
    }

    private static func artistTile(counts: SearchDeckCounts) -> SearchDeckTile {
        SearchDeckTile(id: "artists", title: String(localized: "Artists"),
                       systemImage: "music.mic", count: counts.artists ?? 0,
                       destination: .artists)
    }
}
