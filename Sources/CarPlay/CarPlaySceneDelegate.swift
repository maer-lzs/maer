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
    /// The recently played albums of the rebuild that runs.
    private var recentAnswer: FetchAnswer<[LibraryItem]>?
    private var signals: Set<AnyCancellable> = []
    private var pendingRebuild: Task<Void, Never>?
    /// The first build after a connect, held so a disconnect ends it: a
    /// build that went on after the disconnect set the tab bar on a scene
    /// that was gone, and a reconnect on the same object found it set and
    /// set no root (an empty screen), its signals twice.
    private var connectTask: Task<Void, Never>?
    /// An Up Next list is being put together; a second tap waits for it.
    private var upNextPushing = false
    /// The Up Next list on top, if it is: a tap then pushes none over it.
    private weak var upNextList: CPListTemplate?
    /// The speed of the player that plays now; a new player replaces it.
    private var rateSignal: AnyCancellable?
    // The stores the car reads, held once.
    private let session = AppSession.shared
    private let queue = PlayQueue.shared
    private let playlistStore = MaerPlaylists.shared
    private let context = PlaybackContext.shared
    private let nowPlaying = CPNowPlayingTemplate.shared

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        nowPlaying.add(self)
        nowPlaying.upNextTitle = String(localized: "Up Next")
        connectTask?.cancel()
        connectTask = Task {
            await self.prepare()
            guard Self.isSame(self.interfaceController, interfaceController) else {
                Logger.player.notice("CARPLAY first build dropped: the scene disconnected while it prepared")
                return
            }
            await self.rebuild()
            guard Self.isSame(self.interfaceController, interfaceController) else { return }
            self.observe()
            self.updatePlayerExtras()
        }
    }

    /// Whether two references name the same object, none being no match:
    /// the build of a connect still serves the scene's controller, the
    /// list on top is the Up Next list.
    nonisolated static func isSame(_ one: AnyObject?, _ other: AnyObject?) -> Bool {
        guard let one, let other else { return false }
        return one === other
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        signals.removeAll()
        rateSignal = nil
        connectTask?.cancel()
        connectTask = nil
        pendingRebuild?.cancel()
        nowPlaying.remove(self)
        self.interfaceController = nil
        tabBar = nil
        roots = [:]
        shownTabs = []
    }

    /// Podcast subscriptions load asynchronously at app start. On a CarPlay
    /// cold start (car scene only, no UI) wait for them, or the podcast tab
    /// would silently be missing. Same for the download scan.
    private func prepare() async {
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
        let changes: [AnyPublisher<Void, Never>] = [
            ListeningRevision.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            queue.$ids.map { _ in () }.eraseToAnyPublisher(),
            playlistStore.$playlists.map { _ in () }.eraseToAnyPublisher(),
            PodcastSubscriptions.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            session.libraryViewModel.$continueListening.map { _ in () }.eraseToAnyPublisher(),
            session.$sourcesVersion.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] in self?.scheduleRebuild() }
            .store(in: &signals)
        // The player's extras follow the title, the orders, the rest of what was started, the player that
        // carries the title and that player's speed. The player arrives
        // after its title, so it is a signal of its own.
        session.playerCoordinator.$activeItem
            .combineLatest(queue.$ids, context.$ids, session.playerCoordinator.$viewModel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, model in
                self?.rateSignal = model?.$playbackRate
                    .removeDuplicates()
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.updatePlayerExtras() }
                self?.updatePlayerExtras()
            }
            .store(in: &signals)
    }

    /// A newer rebuild replaces one still running; the old one stops
    /// before it writes another tab.
    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        pendingRebuild = Task { [weak self] in await self?.rebuild() }
    }

    /// The tabs for the sources set up now, each filled anew. A tab that
    /// stays keeps its template, so the car does not jump back to the top.
    private func rebuild() async {
        guard interfaceController != nil else { return }
        recentAnswer = nil
        let musicSource = session.musicProvider
        let maximum = CPTabBarTemplate.maximumTabCount
        let layout = CarPlayLayout.tabs(
            audiobooks: MediaType.audiobooks.userMasterEnabled && !session.libraryViewModel.entries.isEmpty,
            podcasts: MediaType.podcasts.userMasterEnabled && !PodcastShowSources.active().isEmpty,
            music: MediaType.music.userMasterEnabled && musicSource.isAvailable && musicSource.mediaTypes.contains(.music),
            radio: MediaType.radio.userMasterEnabled
                && !(RadioStore.favorites().isEmpty && RadioStore.recents().isEmpty),
            maximumTabCount: maximum)
        Logger.player.notice("CARPLAY tabs max=\(maximum, privacy: .public) shown=\(layout.tabs.map(\.rawValue).joined(separator: ","), privacy: .public) radioOnStart=\(layout.radioOnStart, privacy: .public)")
        radioOnStart = layout.radioOnStart
        for tab in layout.tabs {
            let template = roots[tab] ?? rootTemplate(tab)
            roots[tab] = template
            let filled = await sections(for: tab)
            guard !Task.isCancelled else { return }
            template.updateSections(filled)
        }
        // A disconnect while the sections were read leaves nothing to set.
        guard interfaceController != nil, !Task.isCancelled else { return }
        let templates = layout.tabs.compactMap { roots[$0] }
        if let tabBar, shownTabs != layout.tabs {
            tabBar.updateTemplates(templates)
        } else if tabBar == nil {
            let bar = CPTabBarTemplate(templates: templates)
            tabBar = bar
            interfaceController?.setRootTemplate(bar, animated: true, completion: Self.settled("root"))
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

    /// Start's rows in Start's order, each a row of covers under its name:
    /// Continue across books and episodes, the routines and mixed lists of
    /// Start, Up Next, Listen Again, the latest episodes; and the radio
    /// favourites while Radio has no tab. A cover does what its tile does
    /// in the app, the row's name opens the whole list.
    private func startSections() async -> [CPListSection] {
        let session = self.session
        var rows: [CPListImageRowItem] = []
        let continuedIds = await SharedRows.continueIds(limit: 10)
        let continued = await tiles(continuedIds.compactMap { session.playableItem(forId: $0) })
        if !continued.isEmpty {
            rows.append(coverRow(String(localized: "Continue Listening"), continued) { [weak self] in
                let all = await SharedRows.continueIds(limit: Int(CPListTemplate.maximumItemCount))
                    .compactMap { session.playableItem(forId: $0) }
                await self?.pushList(String(localized: "Continue Listening"), all)
            })
        }
        let lists = SharedRows.playlists(at: .start)
        var listRows: [CPListItem] = []
        if !lists.isEmpty {
            if CarPlayLayout.coversCarryNames {
                rows.append(await listCovers(lists))
            } else {
                listRows = lists.prefix(CarPlayLayout.sectionLimit).map(playlistRow)
            }
        }
        let next = await tiles(upNextItems())
        if !next.isEmpty {
            rows.append(coverRow(String(localized: "Up Next"), next) { [weak self] in await self?.pushUpNext() })
        }
        let again = await listenAgainTiles(continued: Set(continuedIds))
        if !again.isEmpty { rows.append(coverRow(String(localized: "Listen Again"), again)) }
        let latest = await tiles(SharedRows.newEpisodeIds(limit: Int(CPMaximumNumberOfGridImages))
            .compactMap { session.playableItem(forId: $0) })
        if !latest.isEmpty {
            rows.append(coverRow(String(localized: "Latest Episodes"), latest) { [weak self] in
                let all = SharedRows.newEpisodeIds(limit: Int(CPListTemplate.maximumItemCount))
                    .compactMap { session.playableItem(forId: $0) }
                await self?.pushList(String(localized: "Latest Episodes"), all)
            })
        }
        var sections: [CPListSection] = rows.isEmpty ? [] : [CPListSection(items: rows)]
        if !listRows.isEmpty {
            let title = lists.allSatisfy(\.isRoutine) ? String(localized: "Routines") : String(localized: "Playlists")
            sections.append(CPListSection(items: listRows, header: title, sectionIndexTitle: nil))
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

    /// One cover of a cover row: its picture, its name and what a tap does.
    private struct Tile: Sendable {
        let image: UIImage
        let title: String
        let subtitle: String?
        let tap: @MainActor @Sendable () async -> Void
    }

    /// A row of covers under its name. A cover does its tap, the name opens
    /// the whole list where the row has one. Each cover carries its name
    /// where the system draws one.
    private func coverRow(_ name: String, _ tiles: [Tile],
                          all: (@MainActor @Sendable () async -> Void)? = nil) -> CPListImageRowItem {
        let shown = Array(tiles.prefix(Int(CPMaximumNumberOfGridImages)))
        let row: CPListImageRowItem
        if #available(iOS 26.0, *) {
            let elements = shown.map { CPListImageRowItemRowElement(image: $0.image, title: $0.title, subtitle: $0.subtitle) }
            row = CPListImageRowItem(text: name, elements: elements, allowsMultipleLines: false)
        } else {
            row = CPListImageRowItem(text: name, images: shown.map(\.image))
        }
        row.listImageRowHandler = { _, index, completion in
            Task { @MainActor in
                if shown.indices.contains(index) { await shown[index].tap() }
                completion()
            }
        }
        if let all {
            row.handler = { _, completion in
                Task { @MainActor in
                    await all()
                    completion()
                }
            }
        }
        return row
    }

    /// The covers of playable titles; a tap plays the title.
    private func tiles(_ items: [LibraryItem]) async -> [Tile] {
        var tiles: [Tile] = []
        for item in items.prefix(Int(CPMaximumNumberOfGridImages)) {
            tiles.append(Tile(image: await cover(forItemId: item.id) ?? Self.noCover, title: item.title,
                              subtitle: item.media?.metadata?.authorName) { [weak self] in
                await self?.openTitle(item)
            })
        }
        return tiles
    }

    /// The picture of a title without a cover: a square of a cover's size
    /// with a symbol in it, so the title keeps its place among covers.
    private static let noCover = square(symbol: "headphones")

    private static let coverSide: CGFloat = 200

    /// A square of a cover's size with a symbol in it.
    private static func square(symbol name: String) -> UIImage {
        let side = coverSide
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.systemGray4.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let symbol = UIImage(systemName: name,
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: side * 0.4, weight: .regular))?
                .withTintColor(.systemGray, renderingMode: .alwaysOriginal)
            guard let symbol else { return }
            symbol.draw(at: CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2))
        }
    }

    /// A list's picture from the covers of its titles, as its card shows
    /// them: four as a square of four, fewer as the first alone.
    private func mosaic(_ addresses: [URL]) async -> UIImage? {
        var covers: [UIImage] = []
        for address in addresses.prefix(4) {
            if let cover = await Artwork.thumbnail(for: address) { covers.append(cover) }
        }
        guard let first = covers.first else { return nil }
        guard covers.count == 4 else { return first }
        let side = Self.coverSide
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            for (index, cover) in covers.enumerated() {
                cover.draw(in: CGRect(x: CGFloat(index % 2) * side / 2, y: CGFloat(index / 2) * side / 2,
                                      width: side / 2, height: side / 2))
            }
        }
    }

    /// A station's picture as the app shows it: its logo by the one
    /// resolver, else the app's placeholder for that station.
    private func stationImage(_ station: RadioStation) async -> UIImage {
        guard let logo = await RadioArtwork.gatedImage(for: station.faviconURL.flatMap { URL(string: $0) },
                                                       stationID: station.id) else {
            return RadioArtwork.placeholderImage(stationID: station.id, name: RadioMapping.displayName(station.name),
                                                 side: Self.coverSide)
        }
        // A word mark is a line in a row of the car: the station's own
        // icon stands for it where it is closer to a square.
        if Self.isWide(logo), let icon = await artwork(station.faviconURL), !Self.isWide(icon) { return icon }
        return Self.squared(logo)
    }

    private static func isWide(_ image: UIImage) -> Bool {
        guard image.size.width > 0, image.size.height > 0 else { return false }
        return max(image.size.width, image.size.height) / min(image.size.width, image.size.height) > 1.2
    }

    /// A logo in a square of a cover's size: a wide word mark stands whole
    /// on a white ground instead of shrinking to a line beside the name.
    private static func squared(_ logo: UIImage) -> UIImage {
        let side = coverSide
        guard isWide(logo) else { return logo }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let room = side * 0.84
            let scale = min(room / logo.size.width, room / logo.size.height)
            let size = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
            logo.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                 width: size.width, height: size.height))
        }
    }

    /// The name the app gives a group of device lists: Routines when every
    /// one is a routine, Playlists otherwise.
    private static func listsName(_ lists: [MaerPlaylists.Playlist]) -> String {
        lists.allSatisfy(\.isRoutine) ? String(localized: "Routines") : String(localized: "Playlists")
    }

    /// Device lists as a row of covers: a cover plays its list, the row's
    /// name opens the lists, each with its entries.
    private func listCovers(_ lists: [MaerPlaylists.Playlist]) async -> CPListImageRowItem {
        var tiles: [Tile] = []
        for list in lists.prefix(Int(CPMaximumNumberOfGridImages)) { tiles.append(await listTile(list)) }
        let name = Self.listsName(lists)
        return coverRow(name, tiles) { [weak self] in self?.pushLists(name, lists) }
    }

    /// The device lists that stand at `home`, as a tab shows them: a row of
    /// covers where a cover carries its name, rows of text otherwise.
    private func listSections(at home: PlaylistHome) async -> [CPListSection] {
        let lists = SharedRows.playlists(at: home)
        guard !lists.isEmpty else { return [] }
        if CarPlayLayout.coversCarryNames { return [CPListSection(items: [await listCovers(lists)])] }
        return [CPListSection(items: lists.prefix(CarPlayLayout.sectionLimit).map(playlistRow),
                              header: Self.listsName(lists), sectionIndexTitle: nil)]
    }

    /// The page of a group of device lists: a list opens its entries.
    private func pushLists(_ name: String, _ lists: [MaerPlaylists.Playlist]) {
        let rows = lists.prefix(Int(CPListTemplate.maximumItemCount)).map { list in
            let row = CPListItem(text: list.name, detailText: nil, image: Self.listSymbol)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.pushDeviceList(list.id)
                    completion()
                }
            }
            return row
        }
        pushRows(name, Array(rows), failed: false)
    }

    /// A routine or a list as a cover, its picture from the covers of its
    /// entries: a tap plays it, as its card in the app.
    private func listTile(_ list: MaerPlaylists.Playlist) async -> Tile {
        let session = self.session
        let store = playlistStore
        let covers = list.itemIds.prefix(8).compactMap { session.coverURL(forItemId: $0) }
        let picture = await mosaic(Array(covers.prefix(4)))
            ?? Self.square(symbol: list.isRoutine ? "repeat" : "music.note.list")
        return Tile(image: picture, title: list.name, subtitle: nil) { [weak self] in
            await RoutinePlayback.start(list, in: store, on: session.playerCoordinator)
            self?.showNowPlaying()
        }
    }

    // MARK: - Pages

    /// A fixed page of a tab: its name, its symbol and what opens it.
    private struct Page: Sendable {
        let title: String
        let symbol: String
        let open: @MainActor @Sendable () async -> Void
    }

    /// The fixed pages of a tab, in their order.
    private func pages(for tab: CarPlayLayout.Tab) -> [Page] {
        switch tab {
        case .audiobooks:
            let library = session.libraryViewModel
            return [
                Page(title: String(localized: "Downloads list"), symbol: "arrow.down.circle") { [weak self] in
                    await self?.pushList(String(localized: "Downloads list"), library.downloadedEntries.map(\.item),
                                         emptyTitle: String(localized: "No books here yet."))
                },
                Page(title: String(localized: "All Books"), symbol: "books.vertical") { [weak self] in
                    await self?.pushList(String(localized: "All Books"), library.sortedEntries.map(\.item),
                                         emptyTitle: String(localized: "No books here yet."))
                },
            ]
        case .podcasts:
            return [Page(title: String(localized: "Shows"), symbol: "square.stack") { [weak self] in await self?.pushShows() }]
        case .music:
            let lists = CarPlayLayout.coversCarryNames ? [] : [
                Page(title: String(localized: "Playlists"), symbol: "music.note.list") { [weak self] in
                    await self?.pushPlaylists()
                },
            ]
            return lists + [
                Page(title: String(localized: "Albums"), symbol: "square.stack") { [weak self] in await self?.pushAlbums() },
                Page(title: String(localized: "Artists"), symbol: "music.mic") { [weak self] in await self?.pushArtists() },
            ]
        case .start, .radio:
            return []
        }
    }

    /// The pages as rows below a tab's content. The system's buttons on top
    /// of a list take a third of the screen's height, so the pages stay
    /// rows.
    private func pageSections(for tab: CarPlayLayout.Tab) -> [CPListSection] {
        let pages = pages(for: tab)
        guard !pages.isEmpty else { return [] }
        return [CPListSection(items: pages.map { pageRow($0.title, symbol: $0.symbol, open: $0.open) })]
    }

    /// Listen Again as Start merges it: an album opens its titles, a
    /// catalogue title plays, a station plays.
    private func listenAgainTiles(continued: Set<String>) async -> [Tile] {
        let session = self.session
        let recent = await recentAlbums().value ?? []
        let stations = RadioStore.recents()
        var tiles: [Tile] = []
        for entry in SharedRows.listenAgain(serverRecent: recent, continued: continued,
                                            limit: Int(CPMaximumNumberOfGridImages)) {
            switch entry {
            case .album(let id):
                guard let album = recent.first(where: { $0.id == id }) else { continue }
                tiles.append(Tile(image: await cover(forItemId: id) ?? Self.noCover, title: album.title,
                                  subtitle: album.media?.metadata?.authorName) { [weak self] in
                    await self?.pushTitles(of: album)
                })
            case .catalogTrack(let id):
                guard let title = await catalogTitle(id) else { continue }
                tiles.append(contentsOf: await self.tiles([title]))
            case .station(let id):
                guard let station = stations.first(where: { $0.id == id }) else { continue }
                tiles.append(Tile(image: await stationImage(station),
                                  title: RadioMapping.displayName(station.name), subtitle: nil) { [weak self] in
                    RadioPlay.play(station, playerCoordinator: session.playerCoordinator)
                    self?.showNowPlaying()
                })
            }
        }
        return tiles
    }

    // MARK: - Audiobooks

    private func audiobookSections() async -> [CPListSection] {
        let library = session.libraryViewModel
        var sections: [CPListSection] = []
        let continued = library.continueListening.map(\.item)
        if !continued.isEmpty {
            sections.append(await section(String(localized: "Continue Listening"),
                                          continued.prefix(CarPlayLayout.sectionLimit)))
        }
        sections += await listSections(at: .library)
        return sections + pageSections(for: .audiobooks)
    }

    // MARK: - Podcasts

    private func podcastSections() async -> [CPListSection] {
        var sections: [CPListSection] = []
        // Continue comes first, as in the app's tab: the episodes under way.
        let continued = await SharedRows.continueEpisodeIds(limit: CarPlayLayout.sectionLimit)
            .compactMap { session.playableItem(forId: $0) }
        if !continued.isEmpty {
            sections.append(await section(String(localized: "Continue Listening"), continued[...]))
        }
        sections += await listSections(at: .podcasts)
        let queue = upNextItems()
        if !queue.isEmpty {
            sections.append(await section(String(localized: "Up Next"), queue.prefix(CarPlayLayout.sectionLimit)))
        }
        let latest = SharedRows.newEpisodeIds(limit: CarPlayLayout.sectionLimit)
            .compactMap { session.playableItem(forId: $0) }
        if !latest.isEmpty {
            sections.append(await section(String(localized: "New Episodes"), latest[...]))
        }
        return sections + pageSections(for: .podcasts)
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

    /// The server's recently played albums, asked once per rebuild: Start
    /// and the music tab read the one answer.
    private func recentAlbums() async -> FetchAnswer<[LibraryItem]> {
        if let recentAnswer { return recentAnswer }
        guard AppStorageKeys.musicServerActive else { return .value([]) }
        let provider = session.musicProvider
        let answer = await FetchAnswer.of("carplay recent albums", logger: .music) {
            try await provider.albumShelf(shelf: .recent, size: 20)
        }
        recentAnswer = answer
        return answer
    }

    /// Recently Played as the music tab merges it, then the pages of
    /// playlists, albums and artists. A fetch that failed says so in a line
    /// of its own, apart from a library that holds nothing; every opening
    /// asks again.
    private func musicSections() async -> [CPListSection] {
        let answer = await recentAlbums()
        let recent = answer.value ?? []
        let recentFailed = answer.failed
        var played: [LibraryItem] = []
        for entry in SharedRows.musicRecentlyPlayed(serverRecent: recent)
        where played.count < CarPlayLayout.sectionLimit {
            switch entry {
            case .album(let id): if let album = recent.first(where: { $0.id == id }) { played.append(album) }
            case .catalogTrack(let id): if let title = await catalogTitle(id) { played.append(title) }
            case .station: break
            }
        }
        var sections: [CPListSection] = []
        // The tab's order: the playlists on top, then what was heard.
        var listsFailed = false
        if CarPlayLayout.coversCarryNames {
            let lists = await serverPlaylists()
            listsFailed = lists.failed
            let cards = await playlistTiles(SharedRows.musicPlaylists(server: lists.value ?? []))
            if !cards.isEmpty {
                sections.append(CPListSection(items: [
                    coverRow(String(localized: "Playlists"), cards) { [weak self] in await self?.pushPlaylists() },
                ]))
            }
        }
        if !played.isEmpty {
            sections.append(await section(String(localized: "Recently Played"),
                                          played.prefix(CarPlayLayout.sectionLimit)))
        }
        if CarPlayLayout.emptyNote(failed: recentFailed || listsFailed) == .noAnswer {
            sections.append(CPListSection(items: [noAnswerRow()]))
        }
        return sections + pageSections(for: .music)
    }

    /// A catalogue title by its name: what the device knows of it, else
    /// asked from its source, as the title's tile in the app does. Without
    /// a name it is left out of the row; the next rebuild asks again.
    private func catalogTitle(_ id: String) async -> LibraryItem? {
        if let known = session.libraryItem(forId: id), known.media != nil { return known }
        do {
            _ = try await LookupOccasion.automatic {
                try await ItemRouter.live.provider(id).fetchItemDetail(itemId: id)
            }
        } catch {
            guard let reason = FreeCatalog.logReason(error) else { return nil }
            Logger.library.error("CARPLAY catalogue title \(id, privacy: .public) FAILED: \(reason, privacy: .public)")
            return nil
        }
        guard let named = session.libraryItem(forId: id), named.media != nil else { return nil }
        return named
    }

    /// The music tab's one playlist row; a list opens its titles.
    /// The server's playlists, asked anew by every caller.
    private func serverPlaylists() async -> FetchAnswer<[MusicPlaylist]> {
        let provider = session.musicProvider
        guard AppStorageKeys.musicServerActive else { return .value([]) }
        return await FetchAnswer.of("carplay playlists", logger: .music) {
            try await provider.allPlaylists()
        }
    }

    /// The playlists as covers: a tap plays the list in its order, as the
    /// card's body does in the app.
    private func playlistTiles(_ sources: [PlaylistCardSource]) async -> [Tile] {
        let session = self.session
        let store = playlistStore
        var tiles: [Tile] = []
        for source in sources.prefix(Int(CPMaximumNumberOfGridImages)) {
            // The covers the card shows: stated by the list, else fetched
            // with its artists.
            let stated = source.covers?() ?? []
            let addresses = stated.isEmpty ? await source.mosaic().covers : stated
            let picture = await mosaic(addresses) ?? Self.listSymbol
            switch source.detailRoute {
            case .album(let item):
                tiles.append(Tile(image: picture, title: source.title,
                                  subtitle: nil) { [weak self] in
                    await SharedRows.playAlbum(item, fromTrackAt: 0, on: session.playerCoordinator)
                    self?.showNowPlaying()
                })
            case .maerPlaylist(let id):
                tiles.append(Tile(image: picture, title: source.title, subtitle: nil) { [weak self] in
                    guard let list = store.playlist(id: id) else { return }
                    await RoutinePlayback.start(list, in: store, on: session.playerCoordinator)
                    self?.showNowPlaying()
                })
            default: break
            }
        }
        return tiles
    }

    private static let listSymbol = square(symbol: "music.note.list")

    private func pushPlaylists() async {
        let answer = await serverPlaylists()
        let rows = SharedRows.musicPlaylists(server: answer.value ?? [])
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
        pushRows(String(localized: "Playlists"), Array(rows), failed: answer.failed)
    }

    /// A device list's entries; a tap plays the entry, as on its page.
    private func pushDeviceList(_ id: String) async {
        let store = playlistStore
        guard let list = store.playlist(id: id) else { return }
        let items = list.itemIds.compactMap { store.resolution(of: $0, in: list).item }
        await pushList(list.name, items)
    }

    private func pushAlbums() async {
        let provider = session.musicProvider
        let answer = await FetchAnswer.of("carplay albums", logger: .music) {
            try await provider.albumPage(sort: .nameAZ, offset: 0, size: Int(CPListTemplate.maximumItemCount))
        }
        var rows: [CPListItem] = []
        for album in answer.value ?? [] {
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
        pushRows(String(localized: "Albums"), rows, failed: answer.failed)
    }

    /// An album's or a server list's songs; a tap plays from that song, as
    /// on the album page.
    private func pushTitles(of item: LibraryItem) async {
        let session = self.session
        let answer = await FetchAnswer.of("carplay album titles", logger: .music) {
            try await ItemRouter.live.provider(item.id).fetchItemDetail(itemId: item.id)
        }
        let tracks = answer.value.map { MusicAlbumView.trackList(of: $0).chapters } ?? []
        let rows = tracks.prefix(Int(CPListTemplate.maximumItemCount)).map { track in
            let row = CPListItem(text: track.title, detailText: nil)
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await SharedRows.playAlbum(item, fromTrackAt: track.start,
                                               on: session.playerCoordinator)
                    self?.showNowPlaying()
                    completion()
                }
            }
            return row
        }
        pushRows(item.title, Array(rows), failed: answer.failed)
    }

    /// The artists; an artist opens its albums, an album plays.
    private func pushArtists() async {
        let session = self.session
        let provider = session.musicProvider
        let answer = await FetchAnswer.of("carplay artists", logger: .music) {
            try await provider.allArtists()
        }
        let rows = (answer.value ?? []).prefix(Int(CPListTemplate.maximumItemCount)).map { artist in
            let row = CPListItem(text: artist.name ?? "", detailText: nil)
            row.accessoryType = .disclosureIndicator
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    let music = session.musicProvider(for: artist.itemId)
                    let albums = await FetchAnswer.of("carplay artist albums", logger: .music) {
                        try await music.artistAlbums(artistId: artist.id)
                    }
                    await self?.pushList(artist.name ?? "", albums.value ?? [], failed: albums.failed)
                    completion()
                }
            }
            return row
        }
        pushRows(String(localized: "Artists"), Array(rows), failed: answer.failed)
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
        let session = self.session
        var rows: [CPListItem] = []
        for station in stations.prefix(Int(CPListTemplate.maximumItemCount)) {
            let image = await stationImage(station)
            let row = CPListItem(text: RadioMapping.displayName(station.name), detailText: nil, image: image)
            row.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    RadioPlay.play(station, playerCoordinator: session.playerCoordinator)
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
        queue.ids.compactMap { session.playableItem(forId: $0) }
    }

    private func section(_ title: String, _ items: ArraySlice<LibraryItem>) async -> CPListSection {
        var rows: [CPListItem] = []
        for item in items { rows.append(await playableItem(item)) }
        return CPListSection(items: rows, header: title, sectionIndexTitle: nil)
    }

    /// A routine or a mixed list: a tap plays it, as its card on Start.
    private func playlistRow(_ list: MaerPlaylists.Playlist) -> CPListItem {
        let session = self.session
        let store = playlistStore
        let row = CPListItem(text: list.name, detailText: nil, image: UIImage(systemName: "music.note.list"))
        row.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                await RoutinePlayback.start(list, in: store, on: session.playerCoordinator)
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
    private func pushList(_ title: String, _ items: [LibraryItem], failed: Bool = false,
                          emptyTitle: String? = nil) async {
        var rows: [CPListItem] = []
        for item in items.prefix(Int(CPListTemplate.maximumItemCount)) { rows.append(await playableItem(item)) }
        pushRows(title, rows, failed: failed, emptyTitle: emptyTitle)
    }

    /// A page of rows. A fetch that failed says so: alone on a page without
    /// rows, as a last line below rows from elsewhere. A page that only
    /// holds nothing says `emptyTitle`.
    private func pushRows(_ title: String, _ rows: [CPListItem], failed: Bool, emptyTitle: String? = nil) {
        let note = CarPlayLayout.emptyNote(failed: failed)
        let shown = note == .noAnswer && !rows.isEmpty ? rows + [noAnswerRow()] : rows
        let template = CPListTemplate(title: title, sections: shown.isEmpty ? [] : [CPListSection(items: shown)])
        switch note {
        case .noAnswer: template.emptyViewTitleVariants = [Self.noAnswer]
        case .nothing: if let emptyTitle { template.emptyViewTitleVariants = [emptyTitle] }
        }
        push(template)
    }

    private static var noAnswer: String { String(localized: "The source did not answer.") }

    /// The line of a fetch that failed, among rows; it does nothing on a tap.
    private func noAnswerRow() -> CPListItem {
        let row = CPListItem(text: Self.noAnswer, detailText: nil)
        row.isEnabled = false
        return row
    }

    /// Lays a list on the stack while the stack has room. A template the
    /// rule or the system refuses is not shown and leaves a log line.
    private func push(_ template: CPTemplate) {
        guard let interfaceController else { return }
        let depth = interfaceController.templates.count
        guard CarPlayLayout.mayPush(depth: depth) else {
            Logger.player.notice("CARPLAY push dropped, the stack is full depth=\(depth, privacy: .public)")
            return
        }
        interfaceController.pushTemplate(template, animated: true, completion: Self.settled("push"))
    }

    /// The closure every change of the stack ends in. Without one the
    /// system throws when it refuses the change; with it a refusal is a
    /// log line.
    private nonisolated static func settled(_ what: String) -> @Sendable (Bool, (any Error)?) -> Void {
        { done, error in
            guard !done || error != nil else { return }
            let reason = (error as NSError?).map { "\($0.domain) \($0.code)" } ?? "refused"
            Logger.player.error("CARPLAY \(what, privacy: .public) not done reason=\(reason, privacy: .public)")
        }
    }

    /// Playable row: tap starts the title via the coordinator.
    private func playableItem(_ item: LibraryItem) async -> CPListItem {
        // A title without a cover keeps the place of one, so every title of
        // a list starts at the same edge.
        let image = await cover(forItemId: item.id) ?? Self.noCover
        // The side line carries the server's name with two music servers:
        // "Artist · Navidrome". Episodes carry none.
        let detail = [item.media?.metadata?.authorName, session.musicSourceLabel(forItemId: item.id)]
            .compactMap { $0 }.joined(separator: " · ")
        let row = CPListItem(text: item.title, detailText: detail.isEmpty ? nil : detail, image: image)
        row.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                await self?.openTitle(item)
                completion()
            }
        }
        return row
    }

    /// Covers come from the ImageCache thumbnail tier (already decoded
    /// small, just right for the car).
    private func cover(forItemId id: String) async -> UIImage? {
        guard let url = session.coverURL(forItemId: id) else { return nil }
        return await Artwork.thumbnail(for: url)
    }

    private func artwork(_ address: String?) async -> UIImage? {
        guard let url = address.flatMap({ URL(string: $0) }) else { return nil }
        return await Artwork.thumbnail(for: url)
    }

    private func openTitle(_ item: LibraryItem) async {
        await session.playerCoordinator.open(item: item)
        showNowPlaying()
    }

    // MARK: - Player

    /// Up Next while something waits behind the title, the speed while a
    /// book or an episode plays.
    private func updatePlayerExtras() {
        let coordinator = session.playerCoordinator
        let form = coordinator.viewModel?.playingForm
        let spoken = CarPlayLayout.playerExtras(for: coordinator.activeItem?.id, markedForm: form)
        nowPlaying.isUpNextButtonEnabled = CarPlayLayout.offersUpNext(
            for: coordinator.activeItem?.id, markedForm: form, waiting: queue.ids.count + context.ids.count)
        guard spoken, let rate = coordinator.viewModel?.playbackRate else {
            nowPlaying.updateNowPlayingButtons([])
            return
        }
        nowPlaying.updateNowPlayingButtons([rateButton(showing: Double(rate))])
    }

    /// The speed button with the app's own label for the speed. The
    /// system's rate button reads no speed from the app and shows 0x.
    private func rateButton(showing rate: Double) -> CPNowPlayingButton {
        let label = SpeedMenu.label(rate) + "×"
        let size = CPNowPlayingButtonMaximumImageSize
        let font = UIFont.systemFont(ofSize: size.height * 0.62, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: UIColor.white])
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let fit = min(1, size.width / max(text.size().width, 1))
            let scaled = NSAttributedString(string: label, attributes: [
                .font: font.withSize(font.pointSize * fit), .foregroundColor: UIColor.white,
            ])
            let box = scaled.size()
            scaled.draw(at: CGPoint(x: (size.width - box.width) / 2, y: (size.height - box.height) / 2))
        }
        return CPNowPlayingImageButton(image: image.withRenderingMode(.alwaysTemplate)) { [weak self] _ in
            Task { @MainActor [weak self] in self?.stepRate() }
        }
    }

    /// The next of the app's speeds; the button then shows it.
    private func stepRate() {
        guard let model = session.playerCoordinator.viewModel else { return }
        let next = CarPlayLayout.nextRate(after: Double(model.playbackRate), rates: SpeedMenu.rates)
        model.setPlaybackRate(Float(next))
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { await pushUpNext() }
    }

    /// What plays after the title, as the app's queue page lists it: the
    /// orders first, then the rest of what was started, named by its source.
    private func pushUpNext() async {
        // A second tap on a short way while the first list is put together
        // lays no second list over it.
        guard !upNextPushing, !Self.isSame(interfaceController?.topTemplate, upNextList) else { return }
        upNextPushing = true
        defer { upNextPushing = false }
        var sections: [CPListSection] = []
        let orders = upNextItems()
        if !orders.isEmpty {
            sections.append(await section(String(localized: "Up Next"),
                                          orders.prefix(Int(CPListTemplate.maximumItemCount))))
        }
        let rest = context.ids.compactMap { session.playableItem(forId: $0) }
        if !rest.isEmpty {
            let header = context.sourceTitle.map { String(localized: "Continuing from \($0)") }
                ?? String(localized: "Continuing")
            sections.append(await section(header, rest.prefix(Int(CPListTemplate.maximumItemCount))))
        }
        let list = CPListTemplate(title: String(localized: "Up Next"), sections: sections)
        upNextList = list
        push(list)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

    /// Shows the player. It lies in the stack at most once: a tap in the
    /// list the player opened goes back to it.
    private func showNowPlaying() {
        guard let interfaceController else { return }
        let stack = interfaceController.templates
        let move = CarPlayLayout.playerMove(playerOnTop: interfaceController.topTemplate === nowPlaying,
                                            playerIndex: stack.firstIndex { $0 === nowPlaying },
                                            depth: stack.count)
        switch move {
        case .stay:
            break
        case .back:
            interfaceController.pop(to: nowPlaying, animated: true, completion: Self.settled("back to player"))
        case .push:
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: Self.settled("player"))
        case .full:
            Logger.player.notice("CARPLAY player not shown, the stack is full depth=\(stack.count, privacy: .public)")
        }
    }
}
