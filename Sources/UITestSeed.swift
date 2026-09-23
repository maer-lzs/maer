// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if DEBUG
import Foundation

/// DEBUG-only UI-test seeding. Active ONLY when the process is launched with the
/// `-uitest` argument (the MaerUITests harness passes it). The entire file
/// compiles out of Release builds (`#if DEBUG`). It bypasses the login gate and
/// injects deterministic fake content across the providers so read-only UI
/// journeys (mixed queue, Home, badges) run without a live server. It never
/// touches the network or a real account.
@MainActor
enum UITestSeed {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    /// Any start by the UI harness, seeded or bare: every launch site of
    /// the UI tests passes an argument with this prefix (a source fence
    /// keeps it so). The cloud families read THIS, so a bare start (null
    /// start measurement, onboarding) is as silent as a seeded one.
    /// `nonisolated`: it reads the process arguments and nothing else, and
    /// the sources that must ask it do not all live on the main actor (the
    /// radio logo chain is its own actor).
    nonisolated static var isHarness: Bool { ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-uitest") } }

    /// Seeded recommendations. The harness must never reach the
    /// directory. Otherwise the row's HEIGHT depends on network latency and
    /// a journey's precondition becomes a coin toss. Seeded rather than
    /// empty, so the start page keeps its realistic geometry.
    static let recommendations: [PodcastSearchResult] = [
        PodcastSearchResult(title: "Seed Recommendation One", author: "Seed Author",
                            artworkURL: nil, feedURL: "https://seed.example/rec1.xml"),
        PodcastSearchResult(title: "Seed Recommendation Two", author: "Seed Author",
                            artworkURL: nil, feedURL: "https://seed.example/rec2.xml"),
        PodcastSearchResult(title: "Seed Recommendation Three", author: "Seed Author",
                            artworkURL: nil, feedURL: "https://seed.example/rec3.xml"),
    ]
    /// Opt-in: also install a presentation-only active player (mini + full
    /// player). Off by default so multi-tab navigation journeys aren't disturbed
    /// by an ever-present, tappable mini player; only the full-player journey
    /// requests it.
    static var seedsActivePlayer: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-player") }
    /// A listening entry that arrives from OUTSIDE a few seconds after
    /// launch (the shape of a takeover or a pot adoption): the journeys
    /// prove that the rows follow it without a tab switch or a pull.
    static var seedsLateEntry: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-late-entry") }

    /// The started episode lands in Continue; the finished one drops the
    /// show tile's unplayed count by one.
    static let lateEntryEpisodeID = "rss:seed:ep-2"
    static let lateFinishedEpisodeID = "rss:seed:ep-3"

    private static func scheduleLateEntry() {
        // Listening entries survive a reinstall between journeys; the
        // proof starts from none.
        ListeningStore.clearBackup(lateEntryEpisodeID)
        ListeningStore.clearBackup(lateFinishedEpisodeID)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            let now = Date().timeIntervalSince1970 * 1000
            ListeningStore.store(lateEntryEpisodeID,
                                 entry: ProgressMark.entry(position: 600, duration: 3600, nowMs: now))
            ListeningStore.store(lateFinishedEpisodeID,
                                 entry: ProgressMark.entry(position: 1800, duration: 1800, nowMs: now))
            // The same door a pot adoption uses.
            PodcastProgressStore.shared.reload()
        }
    }
    /// A foreign library already read, so the import preview opens on the
    /// podcast source page without a file picker. One state names the
    /// seeded episode by enclosure, one names nothing and must stay
    /// visible as unmatched. No feeds, so Apply touches no network.
    static var foreignImportLibrary: ForeignLibrary? {
        guard isActive, ProcessInfo.processInfo.arguments.contains("-uitest-foreign-import") else { return nil }
        return ForeignLibrary(feedURLs: [], states: [
            ForeignListeningState(feedURL: "https://seed.example/feed", episodeGUID: nil,
                                  enclosureURL: "https://seed.example/rss:seed:ep-1.mp3",
                                  episodeLink: nil, episodeTitle: "Seed Episode One",
                                  position: 600, finished: false, stampedAt: 1_700_000_000_000),
            ForeignListeningState(feedURL: "https://seed.example/feed", episodeGUID: nil,
                                  enclosureURL: "https://seed.example/nowhere.mp3",
                                  episodeLink: nil, episodeTitle: "Nowhere Episode",
                                  position: 300, finished: false, stampedAt: 1_700_000_000_000),
        ])
    }
    /// Force the SETUP screen (no login, no serverless flag).
    /// Independent of the seeded mode.
    static var forcesSetup: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-setup") }

    static func applySetupProbeIfRequested() {
        guard forcesSetup else { return }
        AppStorageKeys.serverlessModeValue = false
        AppSession.shared.apiClient.clearToken()
        AppSession.shared.authViewModel.isLoggedIn = false
    }

    /// Seeded "New Shows" catalog for the search journey. Real directory
    /// requests would leave the harness. Active only in seed mode.
    static var catalogSearchOverride: (@MainActor (String) -> [SearchResult])? {
        guard isActive else { return nil }
        return { query in
            guard PodcastLocalSearch.matches("Seed Catalog Show", query)
                    || PodcastLocalSearch.matches("Seed Catalog Book", query)
                    || query.count >= 2 else { return [] }
            // BOTH kinds are seeded. The book scope filters to
            // `.catalogBook`, the podcast scope to `.catalogShow`, so the
            // journey proves the WIRING of each scope, not just that some
            // result arrives.
            return [SearchResult(id: "https://catalog.example/seed-feed",
                                 kind: .catalogShow,
                                 title: "Seed Catalog Show",
                                 subtitle: "Catalog Author"),
                    SearchResult(id: "lv:seed-book",
                                 kind: .catalogBook,
                                 title: "Seed Catalog Book",
                                 subtitle: "Seed Reader",
                                 sourceLabel: "LibriVox")]
        }
    }

    static func applyIfRequested() {
        guard isActive else { return }
        // The Continue-hide markers are PERSISTED by design (the
        // decision must survive restarts). In the harness that turns into
        // cross-journey pollution. One journey hides the seeded card and the
        // next no longer finds it. Every seeded launch therefore starts with
        // an empty marker set.
        AppStorageKeys.remove(AppStorageKeys.continueHiddenMarkers)
        let session = AppSession.shared
        session.authViewModel.isLoggedIn = true
        // `isAvailable` is token-driven now. The harness needs one so
        // the audiobooks tab (and the ABS search path) stay seeded-visible.
        session.apiClient.updateToken("uitest-token")

        // Audiobooks. One with chapters, one without.
        let books = [
            bookEntry(id: "seed-book-1", title: "Seed Book One", author: "Ada Author",
                      chapters: [chapter(0, 0, 1800, "Chapter 1"), chapter(1, 1800, 3600, "Chapter 2")]),
            bookEntry(id: "seed-book-2", title: "Seed Book Two", author: "Ben Author", chapters: nil),
            // A STALE start (five weeks back). The journey zaun
            // that Continue never grows an age cutoff again.
            bookEntry(id: "seed-book-old", title: "Seed Book Old", author: "Cora Author", chapters: nil,
                      progress: BookProgress(
                          fraction: 0.4, isFinished: false,
                          lastUpdate: Date().timeIntervalSince1970 - 35 * 24 * 3600)),
        ]
        // Scroll depth for collapse-threshold journeys (the two-book grid never
        // reaches the 60 pt raw offset): a page of filler books. Fillers do NOT
        // carry "Seed" in their names. The search journeys query "Seed" and
        // must keep finding the canonical seeds inside the capped sections.
        + (3...24).map {
            bookEntry(id: "seed-book-\($0)", title: "Filler Book \($0)", author: "Ada Author", chapters: nil)
        }
        // Through the library's one harness door: the books become the
        // server copy and the lists (Continue, Recently Added) come out of
        // the same rule as a load. Setting `entries` directly was a facade:
        // the first rebuild from a listening event or a source change put
        // the (empty) server copy back and every seed book was gone
        // (measured 17.09.2026: rebuild items=0 before=25, no seed book on
        // any tab). The rows get the books too, so a load that falls back
        // to the rows finds them; a real library is saved there on every
        // load, so that is the harness's gap, not the app's.
        session.libraryViewModel._seedForUITest(books)
        session.libraryViewModel._testPersistCache()

        // Podcast show + episodes (RSS resolvable via the subscriptions index).
        let show = PodcastShow(
            id: "seed-show", title: "Seed Show", author: "Cara Host", artworkURL: nil,
            description: "A seeded podcast.", feedURL: "https://seed.example/feed",
            episodes: [
                episode(guid: "rss:seed:ep-1", title: "Seed Episode One"),
                episode(guid: "rss:seed:ep-2", title: "Seed Episode Two"),
            ]
            // Scroll depth for hitch/threshold journeys. Every library must be
            // able to scroll well past the 60 pt collapse threshold.
            + (3...22).map { episode(guid: "rss:seed:ep-\($0)", title: "Filler Episode \($0)") } + [
            ],
            // A website link on the seed show, so the journey can prove
            // that tapping it leaves the subscription alone.
            link: "https://seed.example/site")
        // Such-Freeze probe: device-sized podcast stock (30 shows × 60
        // episodes) so the first-query scan is measurable on the sim.
        PodcastSubscriptions.shared._seedForUITest([show])
        if seedsLateEntry { scheduleLateEntry() }

        // Music: make the tab AVAILABLE (fake config → a non-nil client) and
        // seed resolvable albums. MusicView's grid content comes from the seeded
        // MusicSource (see MusicSource.uitestSeed); these back the queue + resolver.
        AppStorageKeys.subsonicServerURLValue = "https://seed.example"
        AppStorageKeys.subsonicUsernameValue = "seed"
        AppStorageKeys.subsonicEnabledValue = true
        SubsonicProvider.shared.reloadConfig()
        SubsonicProvider.shared._seedForUITest(seedAlbums + [seedSong, seedContinuePlaylist])

        // Radio fixtures. Favorites + catalog stations, only when the
        // journey switches the source on (`-radioEnabled 1` launch arg).
        if AppStorageKeys.radioEnabledValue {
            for station in seedRadioStations where !RadioStore.isFavorite(station.id) {
                RadioStore.toggleFavorite(station)
            }
        }

        // Journey: catalog rows arrive LATE (2 s) through the real
        // calm-gated store path. The Entdecken row must appear on the first
        // Start stay without a tab switch.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            func classic(_ n: Int) -> LibraryItem {
                LibraryItem(id: "lva:seed-classic-\(n)",
                            media: LibraryItemMedia(
                                metadata: LibraryItemMetadata(
                                    title: "Seed Classical \(n)", authorName: "Seed Orchestra",
                                    narratorName: nil, seriesName: nil, genres: nil,
                                    publishedYear: nil, description: nil),
                                duration: 600, chapters: nil, tracks: nil),
                            addedAt: nil)
            }
            FreeCatalogStore.shared._seedForUITest(
                classical: (1...4).map(classic), freeMusic: [])
        }

        // Mixed Up-Next queue: a book, an album and an episode.
        let queue = PlayQueue.shared
        queue.clear()
        queue.playLast("seed-book-1")
        queue.playLast("sub:album:seed-1")
        queue.playLast("rss:seed:ep-1")

        // A presentation-only active player (no audio) so the harness can
        // open the full player. A book with FALLBACK chapters ("Teil N von M").
        // The exact case where the cleaned chapter names had hidden the work
        // title. Opt-in (`-uitest-player`) so it doesn't disturb navigation
        // journeys with an ever-present mini player. A distinct id keeps it out
        // of the queue seed above.
        guard seedsActivePlayer else { return }
        // The same presentation-only player with an EPISODE as its title,
        // for the controls whose behaviour differs by media type. The id
        // decides the type; the media shape is shared with the book.
        let npId = "seed-nowplaying"
        let npTitle = "Now Playing Book"
        let npChapters = [
            chapter(0, 0, 600, "Teil 1 von 3"),
            chapter(1, 600, 1200, "Teil 2 von 3"),
            chapter(2, 1200, 1800, "Teil 3 von 3"),
        ]
        let npMedia = LibraryItemMedia(
            metadata: LibraryItemMetadata(title: npTitle, authorName: "Ada Author", narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 1800, chapters: npChapters, tracks: nil)
        session.playerCoordinator._seedActivePlayerForUITest(
            item: LibraryItem(id: npId, media: npMedia, addedAt: 0),
            detail: LibraryItemDetail(id: npId, media: npMedia, userMediaProgress: nil),
            chapters: npChapters, currentChapterIndex: 1, isFallback: true, openedHere: true)
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
    // Scroll depth (hitch/threshold journeys). See the book fillers.
    + (5...24).map { musicAlbum(id: "sub:album:seed-\($0)", title: "Filler Album \($0)", artist: "Backing Band") }

    /// In-progress music for the Home Continue row. The mixed-row
    /// journey (book + episode + music in ONE card format) needs it.
    ///
    /// The PLAYLIST is the entry that carries the row. Since E100 a started
    /// ALBUM belongs in "Listen Again" and deliberately leaves Continue
    /// (`HomeSections.continueAccepts`), so an album here can never produce
    /// a continue card and the two journeys that asked for one were asking
    /// for something the app had stopped doing. The album STAYS, because
    /// the queue journey resolves it and because "Listen Again" is the
    /// other half of that same decision.
    static let seedMusicContinue: [String: BookProgress] = [
        "sub:playlist:seed-playlist-1": BookmarkProgressMath.progress(
            currentTime: 300, duration: 600, lastUpdate: 1_784_541_600_000),
        "sub:album:seed-1": BookmarkProgressMath.progress(
            currentTime: 900, duration: 3600, lastUpdate: 1_784_541_600_000),
    ]

    /// The playlist behind the continue card. `MixedMediaPage` renders the
    /// card only for an id the session can resolve to an item, and the
    /// playlist fixture (`seedPlaylists`) is a `MusicPlaylist`, not a
    /// library item, so without this entry the card had no title to show.
    static let seedContinuePlaylist: LibraryItem =
        musicAlbum(id: "sub:playlist:seed-playlist-1", title: "Seed Playlist", artist: "The Seeds")

    /// M5-Nachbesserung: one seeded SONG so the search journey can assert the
    /// Titles section (offlineSearch keys the kind off the sub:song: prefix).
    static let seedSong: LibraryItem = musicAlbum(id: "sub:song:seed-song-1",
                                                  title: "Seed Song", artist: "The Seeds")

    /// Fake artists/playlists so the Music tab shows the Artists/Playlists browse
    /// rows. The harness navigates through them to reach the artist page and
    /// verify the tab bar can switch library from there (X15).
    static let seedArtists: [MusicArtist] = [
        // No namespace in the seed ids: the door answers the device source.
        MusicArtist(id: "seed-artist-1", itemId: "seed-artist-1", name: "Seed Artist", albumCount: 2),
    ]
    static let seedPlaylists: [MusicPlaylist] = [
        MusicPlaylist(id: "seed-playlist-1", itemId: "seed-playlist-1", name: "Seed Playlist", songCount: 3,
                      duration: 600, changedAt: 1_784_455_200_000),
        MusicPlaylist(id: "seed-playlist-2", itemId: "seed-playlist-2", name: "Seed Playlist Two", songCount: 12,
                      duration: 4320, changedAt: 1_784_541_600_000),
    ]

    private static func bookEntry(id: String, title: String, author: String, chapters: [ABSChapter]?,
                                  progress: BookProgress? = nil) -> LibraryEntry {
        LibraryEntry(item: LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: author, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 3600, chapters: chapters, tracks: nil),
            addedAt: 0), progress: progress)
    }

    private static func musicAlbum(id: String, title: String, artist: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: artist, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 2400, chapters: nil, tracks: nil), addedAt: 0)
    }

    /// The ONE writer of the harness fixtures. Two files, one write site:
    /// the fence past the storage seam counts writers, and a second one
    /// here would be a second reason to explain (it caught exactly this).
    private static func silenceFixture(named name: String, seconds: Double) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? SilentAudio.wav(seconds: seconds).write(to: url, options: .atomic)
        }
        return url.absoluteString
    }

    /// The audio of every seed STATION: five minutes of silence, longer
    /// than any journey. A station must not end. The seeded stations
    /// played the three second file below, so three seconds after the tap
    /// the item ENDED, playback stopped, the mini bar went away and the
    /// full player closed under the journey's hands (measured 07.09.2026:
    /// `PLAYER open item=radio:manual:seed-1` followed by `PLAYER stopped
    /// from=item ended … at=3`). An episode may end; a stream may not.
    static let endlessAudioURL = silenceFixture(named: "maer-uitest-stream.wav", seconds: 300)

    /// The audio of every seed EPISODE: a local file of a few seconds of
    /// silence, written once per process. No network, no
    /// sound, no coin toss on a stream (the seed host never resolved, so a
    /// seeded play used to be a start that could not begin).
    static let silentAudioURL = silenceFixture(named: "maer-uitest-silence.wav", seconds: 3)

    /// Seeded stations (manual namespace. Resolvable without a catalog).
    static let seedRadioStations = [
        RadioStation(id: "radio:manual:seed-1", name: "Seed Radio One",
                     streamURL: endlessAudioURL),
        RadioStation(id: "radio:manual:seed-2", name: "Seed Radio Two",
                     streamURL: endlessAudioURL),
    ]
    // Scroll depth (hitch/threshold journeys). See the book fillers.
    + (3...14).map {
        RadioStation(id: "radio:manual:seed-\($0)", name: "Filler Radio \($0)",
                     streamURL: endlessAudioURL)
    }

    /// F4-discovery: stand-in catalog results. The browse sections and the
    /// genre drilldown use these under `-uitest` instead of hitting the real
    /// Radio Browser network, so the journey stays deterministic.
    static let seedRadioCatalog = [
        RadioStation(id: "radio:rb:seed-pop-1", name: "Seed Popular Station",
                     streamURL: endlessAudioURL, countryCode: "CH"),
        RadioStation(id: "radio:rb:seed-pop-2", name: "Seed Catalog Two",
                     streamURL: endlessAudioURL, countryCode: "CH"),
    ]

    private static func chapter(_ id: Int, _ start: Double, _ end: Double, _ title: String) -> ABSChapter {
        ABSChapter(id: id, start: start, end: end, title: title)
    }

    /// The seed episodes share one date, which keeps every journey's
    /// order exactly as it was; the journey that wanted a day between them
    /// left with B3.
    private static func episode(guid: String, title: String) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: title, audioURL: silentAudioURL,
                       pubDate: 1_700_000_000_000, duration: 1800, description: nil,
                       imageURL: nil, chaptersURL: nil)
    }
}
#endif
