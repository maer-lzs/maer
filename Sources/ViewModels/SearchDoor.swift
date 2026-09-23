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
        // A hit is ONE item: its artist is asked at the server the hit came
        // from, never at the device's configured source.
        return SearchRouting.target(for: result, lookups: SearchLookups(
            item: { session.libraryItem(forId: $0) != nil },
            catalogHasParts: { FreeCatalogProvider.shared.hasPartsList(itemId: $0) },
            catalogKnows: { FreeCatalogProvider.shared.libraryItem(forId: $0) != nil },
            artistId: { session.musicProvider(for: $0).artistId(fromItemId: $0) },
            artistKnown: { itemId in
                let music = session.musicProvider(for: itemId)
                return music.artistId(fromItemId: itemId).map { music.artist(forId: $0) != nil } ?? false
            }))
    }

    // MARK: - The browse deck, behind the same door

    /// The whole browse deck for the current stock. The door knows which
    /// sources feed it (the own library, the subscribed shows, the cached
    /// albums); the view only renders what comes back. The artist count is
    /// NOT part of it, because it arrives on its own way from the music
    /// source: the caller carries it over so a rebuild cannot drop an
    /// answer that is already in.
    static func deck(entries: [LibraryEntry]) async -> SearchDeck {
        let shows = PodcastAutoContinue.allShows()
        let albums = cachedAlbums()
        // The build runs DETACHED on purpose: it must never appear as a
        // main-thread stall. The measurement that proved it is gone, its
        // question is answered.
        // detached because the deck build is CPU work off the MainActor
        return await Task.detached(priority: .userInitiated) {
            SearchDeck.build(entries: entries, shows: shows, albums: albums)
        }.value
    }

    /// Content identity of everything the deck derives from (never counts.
    /// Convention). A change here, and only here, rebuilds the deck.
    static func deckToken(entries: [LibraryEntry]) -> UInt64 {
        ContentToken.of(entries.map(\.id))
            ^ ContentToken.of(PodcastAutoContinue.allShows().map(\.feedURL))
            ^ ContentToken.of(cachedAlbums().map(\.id))
    }

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
        // The artist's own server caches it, so its resolver finds it.
        AppSession.shared.musicProvider(for: artist.itemId).cacheSearchedArtist(artist)
        let name = artist.name ?? String(localized: "Unknown Artist")
        return SearchResult(id: artist.itemId, kind: .artist, title: name)
    }

    // MARK: - What a row needs to know about a hit

    /// The scopes the bar may offer. Radio appears only while its source is
    /// on, re-asked per render like every other availability question.
    static func visibleScopes() -> [SearchScope] {
        SearchScope.allCases.filter { $0 != .radio || RadioProvider.shared.isAvailable }
    }

    /// Whether a show is mirrored on a podcast server, for the origin capsule.
    static func isMirrored(feedURL: String) -> Bool {
        PodcastSubscriptions.shared.isMirrored(feedURL: feedURL)
    }

    /// The cover address of an own item, for the deck's book rows.
    static func coverURL(forItemId id: String) -> URL? {
        AppSession.shared.coverURL(forItemId: id)
    }

    /// The top shows of one podcast genre (the genre tiles of the deck).
    static func topShows(genreId: Int, limit: Int = 30) async -> [PodcastSearchResult] {
        (try? await ITunesDirectory().topPodcasts(genreId: genreId, limit: limit)) ?? []
    }
}
