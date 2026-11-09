// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CarPlay
import Combine
import OSLog
import UIKit

/// CarPlay scene: the app's small sibling for every medium. Tabs for the
/// sources that are set up (`CarPlayLayout.tabs`): Start, Audiobooks,
/// Podcasts, Music and Radio while the system allows a fifth tab. Every
/// list asks the app's own rules (`SharedRows`, `PlayQueue`, `PlaylistHome`,
/// `RoutinePlayback`), never a copy, and follows every change while the car
/// is connected. A tap passes at most a list and its content before the
/// player; the player's content and buttons come from
/// MPNowPlayingInfoCenter/RemoteCommands, and books and episodes add Up Next
/// and the speed.
///
/// Works on a COLD START in the car (phone in the pocket): the library loads
/// here itself (falls back to the disk cache offline).
///
/// Explicitly @MainActor: CPInterfaceController is main-thread-only. The
/// `Task { @MainActor in }` hops inside the CPListItem handlers stay: the
/// handler property is a nonisolated block, so the hop is the type-safe way
/// back onto the actor.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    private var interfaceController: CPInterfaceController?
    private var tabBar: CPTabBarTemplate?
    private var roots: [CarPlayLayout.Tab: CPListTemplate] = [:]
    private var shownTabs: [CarPlayLayout.Tab] = []
    private var radioOnStart = false
    private var signals: Set<AnyCancellable> = []
    private var pendingRebuild: Task<Void, Never>?
    private let rateButton = CPNowPlayingPlaybackRateButton { _ in
        Task { @MainActor in CarPlaySceneDelegate.stepRate() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        CPNowPlayingTemplate.shared.add(self)
        CPNowPlayingTemplate.shared.upNextTitle = String(localized: "Up Next")
        Task {
            await self.prepare()
            await self.rebuild()
            self.observe()
            self.updatePlayerExtras()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        signals.removeAll()
        pendingRebuild?.cancel()
        CPNowPlayingTemplate.shared.remove(self)
        self.interfaceController = nil
        tabBar = nil
        roots = [:]
        shownTabs = []
    }

    /// Podcast subscriptions load asynchronously at app start. On a CarPlay
    /// cold start (car scene only, no UI) wait for them, or the podcast tab
    /// would silently be missing. Same for the download scan.
    private func prepare() async {
        let session = AppSession.shared
        await PodcastSubscriptions.shared.ensureLoaded()
        await DownloadManager.shared.ensureScanned()
        if session.libraryViewModel.entries.isEmpty {
            await session.libraryViewModel.loadLibrary()
        }
    }

    // MARK: - Following the app

    /// Every store a list reads: a change rebuilds the lists once, a moment
    /// later, so a burst of changes costs one rebuild.
    private func observe() {
        let session = AppSession.shared
        let changes: [AnyPublisher<Void, Never>] = [
            ListeningRevision.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            PlayQueue.shared.$ids.map { _ in () }.eraseToAnyPublisher(),
            MaerPlaylists.shared.$playlists.map { _ in () }.eraseToAnyPublisher(),
            PodcastSubscriptions.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.libraryViewModel.$continueListening.map { _ in () }.eraseToAnyPublisher(),
            session.$sourcesVersion.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.scheduleRebuild() }
            .store(in: &signals)
        session.playerCoordinator.$activeItem
            .combineLatest(PlayQueue.shared.$ids)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updatePlayerExtras() }
            .store(in: &signals)
    }

    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    /// The tabs for the sources set up now, each filled anew. A tab that
    /// stays keeps its template, so the car does not jump back to the top.
    private func rebuild() async {
        guard interfaceController != nil else { return }
        let session = AppSession.shared
        let music = session.musicProvider
        let maximum = CPTabBarTemplate.maximumTabCount
        let layout = CarPlayLayout.tabs(
            audiobooks: MediaType.audiobooks.userMasterEnabled && !session.libraryViewModel.entries.isEmpty,
            podcasts: MediaType.podcasts.userMasterEnabled && !PodcastShowSources.active().isEmpty,
            music: MediaType.music.userMasterEnabled && music.isAvailable && music.mediaTypes.contains(.music),
            radio: MediaType.radio.userMasterEnabled
                && !(RadioStore.favorites().isEmpty && RadioStore.recents().isEmpty),
            maximumTabCount: maximum)
        Logger.player.notice("CARPLAY tabs max=\(maximum, privacy: .public) shown=\(layout.tabs.map(\.rawValue).joined(separator: ","), privacy: .public) radioOnStart=\(layout.radioOnStart, privacy: .public)")
        radioOnStart = layout.radioOnStart
        for tab in layout.tabs {
            let template = roots[tab] ?? rootTemplate(tab)
            roots[tab] = template
            template.updateSections(await sections(for: tab))
        }
        let templates = layout.tabs.compactMap { roots[$0] }
        if let tabBar, shownTabs != layout.tabs {
            tabBar.updateTemplates(templates)
        } else if tabBar == nil {
            let bar = CPTabBarTemplate(templates: templates)
            tabBar = bar
            interfaceController?.setRootTemplate(bar, animated: true, completion: nil)
        }
        shownTabs = layout.tabs
    }

    private func rootTemplate(_ tab: CarPlayLayout.Tab) -> CPListTemplate {
        let (title, symbol): (String, String) = switch tab {
        case .start: (String(localized: "Home"), "house")
        case .audiobooks: (String(localized: "Audiobooks"), "books.vertical")
        case .podcasts: (String(localized: "Podcasts"), "mic")
        case .music: (String(localized: "Music"), "music.note")
        case .radio: (String(localized: "Radio"), "dot.radiowaves.left.and.right")
        }
        let template = CPListTemplate(title: title, sections: [])
        template.tabImage = UIImage(systemName: symbol)
        return template
    }

    private func sections(for tab: CarPlayLayout.Tab) async -> [CPListSection] {
        switch tab {
        case .start: return await startSections()
        case .audiobooks: return await audiobookSections()
        case .podcasts: return await podcastSections()
        case .music: return await musicSections()
        case .radio: return await radioSections()
        }
    }

    // MARK: - Start

    /// Continue across books and episodes as a row of covers, Up Next, the
    /// routines and mixed lists of Start, and the radio favourites while
    /// Radio has no tab.
    private func startSections() async -> [CPListSection] {
        let session = AppSession.shared
        var sections: [CPListSection] = []
        let continued = await SharedRows.continueIds(limit: 10).compactMap { session.playableItem(forId: $0) }
        if !continued.isEmpty {
            sections.append(CPListSection(items: [await coverRow(continued)]))
        }
        let queue = upNextItems()
        if !queue.isEmpty {
            sections.append(await section(String(localized: "Up Next"),
                                          queue.prefix(CarPlayLayout.sectionLimit)))
        }
        let lists = SharedRows.playlists(at: .start)
        if !lists.isEmpty {
            let title = lists.allSatisfy(\.isRoutine) ? String(localized: "Routines") : String(localized: "Playlists")
            let rows = lists.prefix(CarPlayLayout.sectionLimit).map(playlistRow)
            sections.append(CPListSection(items: rows, header: title, sectionIndexTitle: nil))
        }
        if radioOnStart {
            let favorites = RadioStore.favorites()
            if !favorites.isEmpty {
                sections.append(await stationSection(String(localized: "Favorites"),
                                                     Array(favorites.prefix(CarPlayLayout.sectionLimit))))
            }
        }
        return sections
    }

    /// The Continue row as covers; a cover plays its title, the row's name
    /// opens the whole list.
    private func coverRow(_ items: [LibraryItem]) async -> CPListImageRowItem {
        let shown = Array(items.prefix(Int(CPMaximumNumberOfGridImages)))
        var images: [UIImage] = []
        for item in shown {
            images.append(await cover(forItemId: item.id) ?? UIImage(systemName: "play.circle") ?? UIImage())
        }
        let row = CPListImageRowItem(text: String(localized: "Continue Listening"), images: images)
        row.listImageRowHandler = { [weak self] _, index, completion in
            Task { @MainActor [weak self] in
                if shown.indices.contains(index) { await self?.play(shown[index]) }
                completion()
            }
        }
        row.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                let all = await SharedRows.continueIds(limit: Int(CPListTemplate.maximumItemCount))
                    .compactMap { AppSession.shared.playableItem(forId: $0) }
                await self?.pushList(String(localized: "Continue Listening"), all)
                completion()
            }
        }
        return row
    }

    // MARK: - Audiobooks

    private func audiobookSections() async -> [CPListSection] {
        let library = AppSession.shared.libraryViewModel
        var sections: [CPListSection] = []
        let continued = library.continueListening.map(\.item)
        if !continued.isEmpty {
            sections.append(await section(String(localized: "Continue Listening"),
                                          continued.prefix(CarPlayLayout.sectionLimit)))
        }
        sections.append(CPListSection(items: [
            pageRow(String(localized: "Downloads list"), symbol: "arrow.down.circle") { [weak self] in
                await self?.pushList(String(localized: "Downloads list"), library.downloadedEntries.map(\.item),
                                     emptyTitle: String(localized: "No books here yet."))
            },
            pageRow(String(localized: "All Books"), symbol: "books.vertical") { [weak self] in
                await self?.pushList(String(localized: "All Books"), library.sortedFilteredEntries.map(\.item),
                                     emptyTitle: String(localized: "No books here yet."))
            },
        ]))
        return sections
    }

    // MARK: - Podcasts

    private func podcastSections() async -> [CPListSection] {
        let session = AppSession.shared
        var sections: [CPListSection] = []
        let queue = upNextItems()
        if !queue.isEmpty {
            sections.append(await section(String(localized: "Up Next"), queue.prefix(CarPlayLayout.sectionLimit)))
        }
        let latest = SharedRows.newEpisodeIds(limit: CarPlayLayout.sectionLimit)
            .compactMap { session.playableItem(forId: $0) }
        if !latest.isEmpty {
            sections.append(await section(String(localized: "New Episodes"), latest[...]))
        }
        sections.append(CPListSection(items: [
            pageRow(String(localized: "Shows"), symbol: "square.stack") { [weak self] in
                await self?.pushShows()
            },
        ]))
        return sections
    }

    private func pushShows() async {
        let shows = PodcastShowSources.active().prefix(Int(CPListTemplate.maximumItemCount))
        var rows: [CPListItem] = []
        for show in shows {
            let image = await artwork(show.artworkURL)
            let row = CPListItem(text: show.title, detailText: show.author, image: image)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.pushList(show.title, SharedRows.showEpisodes(show))
                    completion()
                }
            }
            rows.append(row)
        }
        push(CPListTemplate(title: String(localized: "Shows"), sections: [CPListSection(items: rows)]))
    }

    // MARK: - Music

    /// Recently Played as the music tab merges it, then the pages of
    /// playlists, albums and artists. The car has no place for a failure
    /// line: a list that failed is left out and the failure stands in the
    /// log (`FetchAnswer`).
    private func musicSections() async -> [CPListSection] {
        let session = AppSession.shared
        let provider = session.musicProvider
        var recent: [LibraryItem] = []
        if AppStorageKeys.musicServerActive {
            recent = await FetchAnswer.of("carplay recent albums", logger: .music) {
                try await provider.albumShelf(shelf: .recent, size: 20)
            }.value ?? []
        }
        let played: [LibraryItem] = SharedRows.musicRecentlyPlayed(serverRecent: recent).compactMap { entry in
            switch entry {
            case .album(let id): return recent.first { $0.id == id }
            case .catalogTrack(let id): return session.playableItem(forId: id)
            case .station: return nil
            }
        }
        var sections: [CPListSection] = []
        if !played.isEmpty {
            sections.append(await section(String(localized: "Recently Played"),
                                          played.prefix(CarPlayLayout.sectionLimit)))
        }
        sections.append(CPListSection(items: [
            pageRow(String(localized: "Playlists"), symbol: "music.note.list") { [weak self] in
                await self?.pushPlaylists()
            },
            pageRow(String(localized: "Albums"), symbol: "square.stack") { [weak self] in
                await self?.pushAlbums()
            },
            pageRow(String(localized: "Artists"), symbol: "music.mic") { [weak self] in
                await self?.pushArtists()
            },
        ]))
        return sections
    }

    /// The music tab's one playlist row; a list opens its titles.
    private func pushPlaylists() async {
        let provider = AppSession.shared.musicProvider
        let server = await FetchAnswer.of("carplay playlists", logger: .music) {
            try await provider.allPlaylists()
        }.value ?? []
        let rows = SharedRows.musicPlaylists(server: server)
            .prefix(Int(CPListTemplate.maximumItemCount))
            .map { source in
                let row = CPListItem(text: source.title, detailText: source.placeCapsule)
                row.accessoryType = .disclosureIndicator
                row.handler = { [weak self] _, completion in
                    Task { @MainActor [weak self] in
                        switch source.detailRoute {
                        case .album(let item): await self?.pushTitles(of: item)
                        case .maerPlaylist(let id): await self?.pushDeviceList(id)
                        default: break
                        }
                        completion()
                    }
                }
                return row
            }
        push(CPListTemplate(title: String(localized: "Playlists"), sections: [CPListSection(items: rows)]))
    }

    /// A device list's entries; a tap plays the entry, as on its page.
    private func pushDeviceList(_ id: String) async {
        let store = MaerPlaylists.shared
        guard let list = store.playlist(id: id) else { return }
        let items = list.itemIds.compactMap { store.resolution(of: $0, in: list).item }
        await pushList(list.name, items)
    }

    private func pushAlbums() async {
        let provider = AppSession.shared.musicProvider
        let albums = await FetchAnswer.of("carplay albums", logger: .music) {
            try await provider.albumPage(sort: .nameAZ, offset: 0, size: Int(CPListTemplate.maximumItemCount))
        }.value ?? []
        var rows: [CPListItem] = []
        for album in albums {
            let row = await playableItem(album)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.pushTitles(of: album)
                    completion()
                }
            }
            rows.append(row)
        }
        push(CPListTemplate(title: String(localized: "Albums"), sections: [CPListSection(items: rows)]))
    }

    /// An album's or a server list's songs; a tap plays from that song, as
    /// on the album page.
    private func pushTitles(of item: LibraryItem) async {
        let detail = await FetchAnswer.of("carplay album titles", logger: .music) {
            try await ItemRouter.live.provider(item.id).fetchItemDetail(itemId: item.id)
        }.value
        let tracks = detail.map { MusicAlbumView.trackList(of: $0).chapters } ?? []
        let rows = tracks.prefix(Int(CPListTemplate.maximumItemCount)).map { track in
            let row = CPListItem(text: track.title, detailText: nil)
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await SharedRows.playAlbum(item, fromTrackAt: track.start,
                                               on: AppSession.shared.playerCoordinator)
                    self?.showNowPlaying()
                    completion()
                }
            }
            return row
        }
        push(CPListTemplate(title: item.title, sections: [CPListSection(items: Array(rows))]))
    }

    /// The artists; an artist opens its albums, an album plays.
    private func pushArtists() async {
        let provider = AppSession.shared.musicProvider
        let artists = await FetchAnswer.of("carplay artists", logger: .music) {
            try await provider.allArtists()
        }.value ?? []
        let rows = artists.prefix(Int(CPListTemplate.maximumItemCount)).map { artist in
            let row = CPListItem(text: artist.name ?? "", detailText: nil)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    let music = AppSession.shared.musicProvider(for: artist.itemId)
                    let albums = await FetchAnswer.of("carplay artist albums", logger: .music) {
                        try await music.artistAlbums(artistId: artist.id)
                    }.value ?? []
                    await self?.pushList(artist.name ?? "", albums)
                    completion()
                }
            }
            return row
        }
        push(CPListTemplate(title: String(localized: "Artists"), sections: [CPListSection(items: Array(rows))]))
    }

    // MARK: - Radio

    private func radioSections() async -> [CPListSection] {
        var sections: [CPListSection] = []
        let favorites = RadioStore.favorites()
        if !favorites.isEmpty {
            sections.append(await stationSection(String(localized: "Favorites"), favorites))
        }
        let favoriteIds = Set(favorites.map(\.id))
        let recents = RadioStore.recents().filter { !favoriteIds.contains($0.id) }
        if !recents.isEmpty {
            sections.append(await stationSection(String(localized: "Recently Played"), recents))
        }
        return sections
    }

    private func stationSection(_ title: String, _ stations: [RadioStation]) async -> CPListSection {
        var rows: [CPListItem] = []
        for station in stations.prefix(Int(CPListTemplate.maximumItemCount)) {
            let image = await artwork(station.faviconURL)
            let row = CPListItem(text: station.name, detailText: nil, image: image)
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    RadioPlay.play(station, playerCoordinator: AppSession.shared.playerCoordinator)
                    self?.showNowPlaying()
                    completion()
                }
            }
            rows.append(row)
        }
        return CPListSection(items: rows, header: title, sectionIndexTitle: nil)
    }

    // MARK: - Rows

    /// Up Next: a cold catalogue entry stays IN the car's queue and plays on
    /// tap (open resolves it); until then it carries the placeholder title.
    private func upNextItems() -> [LibraryItem] {
        PlayQueue.shared.ids.compactMap { AppSession.shared.playableItem(forId: $0) }
    }

    private func section(_ title: String, _ items: ArraySlice<LibraryItem>) async -> CPListSection {
        var rows: [CPListItem] = []
        for item in items { rows.append(await playableItem(item)) }
        return CPListSection(items: rows, header: title, sectionIndexTitle: nil)
    }

    /// A routine or a mixed list: a tap plays it, as its card on Start.
    private func playlistRow(_ list: MaerPlaylists.Playlist) -> CPListItem {
        let row = CPListItem(text: list.name, detailText: nil, image: UIImage(systemName: "music.note.list"))
        row.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                await RoutinePlayback.start(list, in: MaerPlaylists.shared, on: AppSession.shared.playerCoordinator)
                self?.showNowPlaying()
                completion()
            }
        }
        return row
    }

    /// A row that opens a page.
    private func pageRow(_ title: String, symbol: String, open: @escaping @MainActor () async -> Void) -> CPListItem {
        let row = CPListItem(text: title, detailText: nil, image: UIImage(systemName: symbol))
        row.accessoryType = .disclosureIndicator
        row.handler = { _, completion in
            Task { @MainActor in
                await open()
                completion()
            }
        }
        return row
    }

    /// A page of playable titles.
    private func pushList(_ title: String, _ items: [LibraryItem], emptyTitle: String? = nil) async {
        let section = await section("", items.prefix(Int(CPListTemplate.maximumItemCount)))
        let template = CPListTemplate(title: title, sections: [CPListSection(items: section.items)])
        if let emptyTitle { template.emptyViewTitleVariants = [emptyTitle] }
        push(template)
    }

    private func push(_ template: CPTemplate) {
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// Playable row: tap starts the title via the coordinator.
    private func playableItem(_ item: LibraryItem) async -> CPListItem {
        let session = AppSession.shared
        let image = await cover(forItemId: item.id)
        // The side line carries the server's name with two music servers:
        // "Artist · Navidrome". Episodes carry none.
        let detail = [item.media?.metadata?.authorName, session.musicSourceLabel(forItemId: item.id)]
            .compactMap { $0 }.joined(separator: " · ")
        let row = CPListItem(text: item.title, detailText: detail.isEmpty ? nil : detail, image: image)
        row.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                await self?.play(item)
                completion()
            }
        }
        return row
    }

    /// Covers come from the ImageCache thumbnail tier (already decoded
    /// small, just right for the car).
    private func cover(forItemId id: String) async -> UIImage? {
        guard let url = AppSession.shared.coverURL(forItemId: id) else { return nil }
        return await Artwork.thumbnail(for: url)
    }

    private func artwork(_ address: String?) async -> UIImage? {
        guard let url = address.flatMap({ URL(string: $0) }) else { return nil }
        return await Artwork.thumbnail(for: url)
    }

    private func play(_ item: LibraryItem) async {
        await AppSession.shared.playerCoordinator.open(item: item)
        showNowPlaying()
    }

    // MARK: - Player

    /// Up Next and the speed while a book or an episode plays.
    private func updatePlayerExtras() {
        let coordinator = AppSession.shared.playerCoordinator
        let spoken = CarPlayLayout.playerExtras(for: coordinator.activeItem?.id,
                                                markedForm: coordinator.viewModel?.playingForm)
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = spoken && !PlayQueue.shared.isEmpty
        nowPlaying.updateNowPlayingButtons(spoken ? [rateButton] : [])
    }

    /// The next of the app's speeds.
    private static func stepRate() {
        guard let model = AppSession.shared.playerCoordinator.viewModel else { return }
        let next = CarPlayLayout.nextRate(after: Double(model.playbackRate), rates: SpeedMenu.rates)
        model.setPlaybackRate(Float(next))
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { await pushList(String(localized: "Up Next"), upNextItems()) }
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        // Don't push twice if Now Playing is already on top.
        if interfaceController.topTemplate != nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }
}
