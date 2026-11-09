// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The rows the app's tabs and the car both show, each asked in one place:
/// a tab and the car never answer the same question from two copies.
@MainActor
enum SharedRows {
    /// Last-played moment of an item from the local position store, 0 if
    /// none.
    static func localTimestamp(_ id: String) -> Double {
        ProgressMark.timestamp(ListeningStore.backup(id)) ?? 0
    }

    /// The two streams of Continue, books and episodes, each on one clock
    /// (ms) by last played; `episodesShown` without the hidden ones. Books
    /// come filtered from the view model.
    static func continueStreams(books: [LibraryEntry], episodes: [LibraryItem],
                                hidden: [String: Double])
        -> (books: [(id: String, ts: Double)], episodes: [(id: String, ts: Double)],
            episodesShown: [(id: String, ts: Double)]) {
        let bookStream = books.map {
            (id: $0.id, ts: HomeSections.lastPlayedMs(
                local: localTimestamp($0.id),
                server: $0.progress?.lastUpdate ?? 0,
                playingNowMs: PlayingNow.momentMs(forId: $0.id)))
        }
        // The same moment the episode card names (local or server stand,
        // whichever is newer), so the row cannot rank by one clock and
        // show another.
        let episodeProgress = ABSPodcastProvider.shared.episodeProgress
        let episodeStream = episodes.map {
            (id: $0.id, ts: HomeSections.lastPlayedMs(
                local: localTimestamp($0.id),
                server: episodeProgress[$0.id]?.lastUpdate ?? 0,
                // What plays IS the newest thing: its stand is written every
                // thirty seconds, and between two writes a stand arriving
                // from the other device used to push it down the row.
                playingNowMs: PlayingNow.momentMs(forId: $0.id)))
        }
        // The marker acts on the whole mixed row, so hiding works the same
        // for a book and an episode; episodes are filtered here, where the
        // streams meet.
        let shown = episodeStream.filter {
            !ContinueHidden.isHidden(id: $0.id, lastUpdate: $0.ts, markers: hidden)
        }
        return (bookStream, episodeStream, shown)
    }

    /// Continue across books and episodes, ranked by last played, as ids.
    static func continueIds(limit: Int) async -> [String] {
        let shows = PodcastAutoContinue.allShows()
        let sections = await PodcastSections.computeDetached(
            shows: shows, snapshot: PodcastSections.snapshot(shows: shows))
        let streams = continueStreams(books: AppSession.shared.libraryViewModel.continueListening,
                                      episodes: sections.nextUp,
                                      hidden: ContinueHiddenStore.markers())
        return HomeSections.byRecency([streams.books, streams.episodesShown], limit: limit)
    }

    /// Continue in the podcast tab: the episodes under way, the most
    /// recently played first, without what the person hid from Continue.
    static func continueEpisodeIds(limit: Int) async -> [String] {
        let shows = PodcastAutoContinue.allShows()
        let sections = await PodcastSections.computeDetached(
            shows: shows, snapshot: PodcastSections.snapshot(shows: shows))
        let streams = continueStreams(books: [], episodes: sections.nextUp,
                                      hidden: ContinueHiddenStore.markers())
        return HomeSections.byRecency([streams.episodesShown], limit: limit)
    }

    /// The newest episode of every show, own and listened along.
    static func newEpisodeIds(limit: Int = 30) -> [String] {
        PodcastSections.newestPerShow(shows: PodcastShowSources.active() + CoListenedShows.shows(),
                                      limit: limit)
    }

    /// A show's episodes in the order its page shows them, by its stored
    /// sort.
    static func showEpisodes(_ show: PodcastShow) -> [LibraryItem] {
        let preferences = PodcastShowPreferences.load(showId: show.id, mode: .subscribed)
        return PodcastShowView.ordered(show, newestFirst: preferences.newestFirst)
    }

    /// The music tab's "Recently Played": the server's history and the
    /// catalogue titles started as album tracks, merged by time.
    static func musicRecentlyPlayed(serverRecent: [LibraryItem]) -> [RecentlyPlayedRow.Entry] {
        let albums = AppStorageKeys.musicServerActive ? serverRecent.map(\.id) : []
        let tracks = ContinueSources.positionless(positions: ListeningStore.positions(),
                                                  serverKnows: [],
                                                  hiddenMarkers: ContinueHiddenStore.markers())
        return RecentlyPlayedRow.merged(
            albums: albums,
            albumTimes: RecentlyPlayedRow.deviceTimes(albums, positions: ListeningStore.positions()),
            continued: [], stations: [], stationTimes: [:],
            catalog: tracks.map(\.id), catalogTimes: RecentlyPlayedRow.catalogTimes(tracks),
            limit: Int.max)
    }

    /// Start's "Listen Again" for a surface that holds none of Start's own
    /// state: the server's recently played albums, the stations and the
    /// catalogue titles heard before, merged by time, without what
    /// Continue already shows.
    static func listenAgain(serverRecent: [LibraryItem], continued: Set<String>,
                            limit: Int) -> [RecentlyPlayedRow.Entry] {
        let albums = AppStorageKeys.musicServerActive ? serverRecent.map(\.id) : []
        let positions = ListeningStore.positions()
        let tracks = ContinueSources.positionless(positions: positions, serverKnows: [],
                                                  hiddenMarkers: ContinueHiddenStore.markers())
        return RecentlyPlayedRow.merged(
            albums: albums,
            albumTimes: RecentlyPlayedRow.deviceTimes(albums, positions: positions),
            continued: continued,
            stations: RadioStore.recents().map(\.id), stationTimes: RadioStore.recentTimes(),
            catalog: tracks.map(\.id), catalogTimes: RecentlyPlayedRow.catalogTimes(tracks),
            limit: limit)
    }

    /// The device lists that stand at `home`, the most recently changed
    /// first.
    static func playlists(at home: PlaylistHome) -> [MaerPlaylists.Playlist] {
        PlaylistPresentation.sortedByChanged(MaerPlaylists.shared.playlists.filter { $0.home == home }) {
            Date(timeIntervalSince1970: $0.updatedAt)
        }
    }

    /// The music tab's one playlist row: the server's lists and the device
    /// lists whose home is music, newest change first.
    static func musicPlaylists(server: [MusicPlaylist], router: ItemRouter = .live) -> [PlaylistCardSource] {
        let serverSources = server.map { PlaylistCardSource.server($0, sourceLabel: router.sourceLabel($0.itemId)) }
        let device = playlists(at: .music).map { PlaylistCardSource.device($0, router: router) }
        return PlaylistPresentation.sortedByChanged(serverSources + device) {
            $0.changedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    /// Plays an album or a server list from the song at `start` (its
    /// chapter offset).
    static func playAlbum(_ item: LibraryItem, fromTrackAt start: Double, on coordinator: PlayerCoordinator) async {
        await coordinator.open(item: item)
        await coordinator.viewModel?.seek(to: start)
    }
}
