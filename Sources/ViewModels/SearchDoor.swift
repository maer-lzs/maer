// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// THE door of the search. Two questions and nothing else:
///
/// 1. **hits for a term and a scope**: `GlobalSearchModel` fans out over
///    the providers, the free catalogs and the directory and ranks what
///    comes back (`SearchRanking`).
/// 2. **the target of a hit**: `SearchRouting` answers where a tap leads.
///    The view PERFORMS the target; it owns the navigation path.
///
/// Behind the door also live the browse deck's own loads: the search view
/// used to reach for `AppSession.shared.musicProvider` and the podcast
/// directory itself, so a surface that is about FINDING knew which sources
/// exist and how to ask them. A fence keeps it out from here on.
@MainActor
enum SearchDoor {
    // MARK: - Question 1: hits

    /// The app-wide fan-out. The view observes it and renders sections.
    static func hits() -> GlobalSearchModel { .production() }

    // MARK: - Question 2: target

    /// Where does this hit lead? The decision, never the doing.
    static func target(for result: SearchResult) -> SearchTarget {
        let session = AppSession.shared
        let music = session.musicProvider
        return SearchRouting.target(for: result, lookups: SearchLookups(
            item: { session.libraryItem(forId: $0) != nil },
            catalogHasParts: { FreeCatalogProvider.shared.hasPartsList(itemId: $0) },
            catalogKnows: { FreeCatalogProvider.shared.libraryItem(forId: $0) != nil },
            artistId: { music.artistId(fromItemId: $0) },
            artistKnown: { music.artist(forId: $0) != nil }))
    }

    // MARK: - The browse deck, behind the same door

    /// How many artists the music source holds (the deck tile's count).
    static func artistCount() async -> Int? {
        (try? await AppSession.shared.musicProvider.allArtists())?.count
    }

    /// Every artist, for the deck's drill level.
    static func artists() async -> [MusicArtist] {
        (try? await AppSession.shared.musicProvider.allArtists()) ?? []
    }

    /// The real playlists (junk-cleaned like everywhere else).
    static func playlists() async -> [MusicPlaylist] {
        PlaylistPresentation.realPlaylists(
            (try? await AppSession.shared.musicProvider.allPlaylists()) ?? [])
    }

    /// The albums the music source has cached, for the deck's raster.
    static func cachedAlbums() -> [LibraryItem] {
        AppSession.shared.musicProvider.cachedAlbumItems
    }

    /// An artist of the deck AS a hit, so a tap there takes the same way
    /// as a tap on a server hit. Caching the artist is part of it: the
    /// shared resolver finds it afterwards, exactly as after a search.
    static func hit(forArtist artist: MusicArtist) -> SearchResult {
        let music = AppSession.shared.musicProvider
        music.cacheSearchedArtist(artist)
        let name = artist.name ?? String(localized: "Unknown Artist")
        return SearchResult(id: music.itemId(artistId: artist.id), kind: .artist, title: name)
    }

    /// The top shows of one podcast genre (the genre tiles of the deck).
    static func topShows(genreId: Int, limit: Int = 30) async -> [PodcastSearchResult] {
        (try? await ITunesDirectory().topPodcasts(genreId: genreId, limit: limit)) ?? []
    }
}
