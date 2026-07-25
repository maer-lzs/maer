// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import Foundation

/// DEBUG-only UI-test seeding. Active ONLY when the process is launched with the
/// `-uitest` argument (the ABSPlayerUITests harness passes it) — the entire file
/// compiles out of Release builds (`#if DEBUG`). It bypasses the login gate and
/// injects deterministic fake content across the providers so read-only UI
/// journeys (mixed queue, Home, badges) run without a live server. It never
/// touches the network or a real account.
@MainActor
enum UITestSeed {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }
    /// Opt-in: also install a presentation-only active player (mini + full
    /// player). Off by default so multi-tab navigation journeys aren't disturbed
    /// by an ever-present, tappable mini player; only the full-player journey
    /// requests it.
    static var seedsActivePlayer: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-player") }
    /// F10 journey: force the SETUP screen (no login, no serverless flag) —
    /// independent of the seeded mode.
    static var forcesSetup: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-setup") }

    static func applySetupProbeIfRequested() {
        guard forcesSetup else { return }
        AppStorageKeys.serverlessModeValue = false
        AppSession.shared.apiClient.clearToken()
        AppSession.shared.authViewModel.isLoggedIn = false
    }

    /// F6: seeded "New Shows" catalog for the search journey — real directory
    /// requests would leave the harness. Active only in seed mode.
    static var catalogSearchOverride: (@MainActor (String) -> [SearchResult])? {
        guard isActive else { return nil }
        return { query in
            guard PodcastLocalSearch.matches("Seed Catalog Show", query) || query.count >= 2 else { return [] }
            return [SearchResult(id: "https://catalog.example/seed-feed",
                                 kind: .catalogShow,
                                 title: "Seed Catalog Show",
                                 subtitle: "Catalog Author")]
        }
    }

    static func applyIfRequested() {
        guard isActive else { return }
        let session = AppSession.shared
        session.authViewModel.isLoggedIn = true
        // F10: `isAvailable` is token-driven now — the harness needs one so
        // the audiobooks tab (and the ABS search path) stay seeded-visible.
        session.apiClient.updateToken("uitest-token")

        // Audiobooks — one with chapters, one without.
        let books = [
            bookEntry(id: "seed-book-1", title: "Seed Book One", author: "Ada Author",
                      chapters: [chapter(0, 0, 1800, "Chapter 1"), chapter(1, 1800, 3600, "Chapter 2")]),
            bookEntry(id: "seed-book-2", title: "Seed Book Two", author: "Ben Author", chapters: nil),
        ]
        // Scroll depth for collapse-threshold journeys (the two-book grid never
        // reaches the 60 pt raw offset): a page of filler books. Fillers do NOT
        // carry "Seed" in their names — the search journeys query "Seed" and
        // must keep finding the canonical seeds inside the capped sections.
        + (3...24).map {
            bookEntry(id: "seed-book-\($0)", title: "Filler Book \($0)", author: "Ada Author", chapters: nil)
        }
        session.libraryViewModel.entries = books
        session.libraryViewModel.recentlyAdded = books

        // Podcast show + episodes (RSS resolvable via the subscriptions index).
        let show = PodcastShow(
            id: "seed-show", title: "Seed Show", author: "Cara Host", artworkURL: nil,
            description: "A seeded podcast.", feedURL: "https://seed.example/feed",
            episodes: [
                episode(guid: "rss:seed:ep-1", title: "Seed Episode One"),
                episode(guid: "rss:seed:ep-2", title: "Seed Episode Two"),
            ]
            // Scroll depth for hitch/threshold journeys — every library must be
            // able to scroll well past the 60 pt collapse threshold.
            + (3...22).map { episode(guid: "rss:seed:ep-\($0)", title: "Filler Episode \($0)") } + [
            ])
        PodcastSubscriptions.shared._seedForUITest([show])

        // Music: make the tab AVAILABLE (fake config → a non-nil client) and
        // seed resolvable albums. MusicView's grid content comes from the seeded
        // MusicSource (see MusicSource.uitestSeed); these back the queue + resolver.
        AppStorageKeys.subsonicServerURLValue = "https://seed.example"
        AppStorageKeys.subsonicUsernameValue = "seed"
        AppStorageKeys.subsonicEnabledValue = true
        SubsonicProvider.shared.reloadConfig()
        SubsonicProvider.shared._seedForUITest(seedAlbums)

        // F5: radio fixtures — favorites + catalog stations, only when the
        // journey switches the source on (`-radioEnabled 1` launch arg).
        if AppStorageKeys.radioEnabledValue {
            for station in seedRadioStations where !RadioStore.isFavorite(station.id) {
                RadioStore.toggleFavorite(station)
            }
        }

        // Mixed Up-Next queue: a book, an album and an episode.
        let queue = PlayQueue.shared
        queue.clear()
        queue.playLast("seed-book-1")
        queue.playLast("sub:album:seed-1")
        queue.playLast("rss:seed:ep-1")

        // X14: a presentation-only active player (no audio) so the harness can
        // open the full player. A book with FALLBACK chapters ("Teil N von M") —
        // the exact case where the cleaned chapter names had hidden the work
        // title. Opt-in (`-uitest-player`) so it doesn't disturb navigation
        // journeys with an ever-present mini player. A distinct id keeps it out
        // of the queue seed above.
        guard seedsActivePlayer else { return }
        let npChapters = [
            chapter(0, 0, 600, "Teil 1 von 3"),
            chapter(1, 600, 1200, "Teil 2 von 3"),
            chapter(2, 1200, 1800, "Teil 3 von 3"),
        ]
        let npMedia = LibraryItemMedia(
            metadata: LibraryItemMetadata(title: "Now Playing Book", authorName: "Ada Author", narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 1800, chapters: npChapters, tracks: nil)
        session.playerCoordinator._seedActivePlayerForUITest(
            item: LibraryItem(id: "seed-nowplaying", media: npMedia, addedAt: 0),
            detail: LibraryItemDetail(id: "seed-nowplaying", media: npMedia, userMediaProgress: nil),
            chapters: npChapters, currentChapterIndex: 1, isFallback: true)
    }

    // MARK: - Fixtures

    /// Fake albums for the Music tab + queue/resolver. The first backs the mixed
    /// queue entry "sub:album:seed-1".
    static let seedAlbums: [LibraryItem] = [
        musicAlbum(id: "sub:album:seed-1", title: "Seed Album", artist: "The Seeds"),
        musicAlbum(id: "sub:album:seed-2", title: "Second Seed", artist: "Sprout"),
        musicAlbum(id: "sub:album:seed-3", title: "Third Seed", artist: "Bloom"),
        musicAlbum(id: "sub:album:seed-4", title: "Fourth Seed", artist: "Petal"),
    ]
    // Scroll depth (hitch/threshold journeys) — see the book fillers.
    + (5...24).map { musicAlbum(id: "sub:album:seed-\($0)", title: "Filler Album \($0)", artist: "Backing Band") }

    /// Fake artists/playlists so the Music tab shows the Artists/Playlists browse
    /// rows — the harness navigates through them to reach the artist page and
    /// verify the tab bar can switch library from there (X15).
    static let seedArtists: [SubsonicArtist] = [
        SubsonicArtist(id: "seed-artist-1", name: "Seed Artist", coverArt: nil, albumCount: 2, album: nil),
    ]
    static let seedPlaylists: [SubsonicPlaylist] = [
        SubsonicPlaylist(id: "seed-playlist-1", name: "Seed Playlist", songCount: 3,
                         duration: 600, coverArt: nil, owner: nil,
                         changed: "2026-07-19T10:00:00Z", entry: nil),
        SubsonicPlaylist(id: "seed-playlist-2", name: "Seed Playlist Two", songCount: 12,
                         duration: 4320, coverArt: nil, owner: nil,
                         changed: "2026-07-20T10:00:00Z", entry: nil),
    ]

    private static func bookEntry(id: String, title: String, author: String, chapters: [ABSChapter]?) -> LibraryEntry {
        LibraryEntry(item: LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: author, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 3600, chapters: chapters, tracks: nil),
            addedAt: 0), progress: nil)
    }

    private static func musicAlbum(id: String, title: String, artist: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: artist, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 2400, chapters: nil, tracks: nil), addedAt: 0)
    }

    /// F5: seeded stations (manual namespace — resolvable without a catalog).
    static let seedRadioStations = [
        RadioStation(id: "radio:manual:seed-1", name: "Seed Radio One",
                     streamURL: "https://seed.example/one.mp3"),
        RadioStation(id: "radio:manual:seed-2", name: "Seed Radio Two",
                     streamURL: "https://seed.example/two.mp3"),
    ]
    // Scroll depth (hitch/threshold journeys) — see the book fillers.
    + (3...14).map {
        RadioStation(id: "radio:manual:seed-\($0)", name: "Filler Radio \($0)",
                     streamURL: "https://seed.example/f\($0).mp3")
    }

    /// F4-discovery: stand-in catalog results — the browse sections and the
    /// genre drilldown use these under `-uitest` instead of hitting the real
    /// Radio Browser network, so the journey stays deterministic.
    static let seedRadioCatalog = [
        RadioStation(id: "radio:rb:seed-pop-1", name: "Seed Popular Station",
                     streamURL: "https://seed.example/pop.mp3", countryCode: "CH"),
        RadioStation(id: "radio:rb:seed-pop-2", name: "Seed Catalog Two",
                     streamURL: "https://seed.example/pop2.mp3", countryCode: "CH"),
    ]

    private static func chapter(_ id: Int, _ start: Double, _ end: Double, _ title: String) -> ABSChapter {
        ABSChapter(id: id, start: start, end: end, title: title)
    }

    private static func episode(guid: String, title: String) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: title, audioURL: "https://seed.example/\(guid).mp3",
                       pubDate: 1_700_000_000_000, duration: 1800, description: nil,
                       imageURL: nil, chaptersURL: nil)
    }
}
#endif
