// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog

/// Musik-Tab-Neuordnung (30.07): the tab shows a library LIST (artists ·
/// albums · songs · playlists · downloaded. The Apple-Music pattern); these
/// are the three pages that had no own surface before. Albums reuses the
/// full MusicViewModel pipeline (staged pages, sort, shuffle). The grid
/// moved here from the tab body unchanged.
/// THE music sort menu, at the surfaces it orders (albums + songs)
/// instead of in the shared toolbar. Content unchanged, including the honest
/// offline treatment: the sort is server-side (`search3` order), so offline it
/// is disabled WITH a reason rather than silently doing nothing. A local sort
/// over the loaded page would be a different order under the same name.
struct MusicSortMenu: View {
    @Binding var musicSort: MusicSortOption
    @Environment(\.isOnline) private var isOnline

    var body: some View {
        Picker("Sort By", selection: $musicSort) {
            ForEach(MusicSortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .disabled(!isOnline)
        if !isOnline {
            Text("Sorting needs a connection")
        }
    }
}

struct MusicAlbumsPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    #if DEBUG
    @StateObject private var vm = MusicViewModel(source: .uitestOrLive)
    #else
    @StateObject private var vm = MusicViewModel()
    #endif
    @AppStorage(AppStorageKeys.musicSortOption) private var musicSort = MusicSortOption.nameAZ

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    @ViewBuilder private var musicSortMenu: some View { MusicSortMenu(musicSort: $musicSort) }

    var body: some View {
        Group {
            if let error = vm.errorText, vm.albums.isEmpty {
                ContentUnavailableView {
                    Label("Music unavailable", systemImage: "music.note")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.reload() } }
                }
            } else if vm.albums.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if vm.albums.isEmpty {
                ContentUnavailableView("No music", systemImage: "music.note")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                        // The sort sits AT the grid it orders. It
                        // used to live in the shared tab toolbar, two screens
                        // away from what it changed.
                        HStack {
                            SectionSortControl(
                                activeLabel: SortIndicator.part(musicSort.label,
                                                                ifNot: musicSort == .nameAZ)
                            ) { musicSortMenu }
                            Spacer()
                            ShufflePlayButton(playerCoordinator: playerCoordinator, style: .icon) {
                                await AppSession.shared.musicProvider.shuffleLibrarySongItems()
                            }
                            .font(.title3)
                        }
                        .padding(.horizontal)
                        CoverGrid(columns: columns) {
                            ForEach(vm.albums) { album in
                                AlbumCell(item: album, playerCoordinator: playerCoordinator)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text("Albums"))
        .task {
            vm.sort = musicSort
            await vm.loadIfNeeded()
        }
        // Choice family: same key as MusicView. The double note is absorbed
        // by the equal-value guard.
        .onChange(of: musicSort) { _, newSort in
            UserChoiceCloudSync.shared.noteScalar(
                key: AppStorageKeys.musicSortOption, value: newSort.rawValue)
            Task { await vm.setSort(newSort) }
        }
    }
}

/// Alphabetical song list, paged from the server ("Titles" entry). Rows play
/// directly (single-track items, like top songs on the artist page).
struct MusicSongsPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var songs: [MusicTopSong] = []
    @State private var isLoading = false
    @State private var reachedEnd = false

    private let pageSize = 100

    var body: some View {
        Group {
            if songs.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if songs.isEmpty {
                ContentUnavailableView("No songs", systemImage: "music.note")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(songs) { entry in
                            MusicSongRow(entry: entry, playerCoordinator: playerCoordinator)
                                .onAppear {
                                    if entry.id == songs.last?.id { Task { await loadMore() } }
                                }
                        }
                        if isLoading && !songs.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text("Songs"))
        .task { if songs.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        // Best-effort: a failed page keeps what is there (stale beats empty);
        // dropping the error is fine here. The empty state carries the hint.
        let next = (try? await AppSession.shared.musicProvider
            .songPage(offset: songs.count, size: pageSize)) ?? []
        if next.isEmpty { reachedEnd = true; return }
        var seen = Set(songs.map(\.id))
        songs += next.filter { seen.insert($0.id).inserted }
        if next.count < pageSize { reachedEnd = true }
    }
}

/// One song row: cover, title, album line, plays on tap. Fixed vertical
/// metrics (reserved lines) per the lazy-cell convention.
struct MusicSongRow: View {
    @Environment(\.itemRouter) private var router
    let entry: MusicTopSong
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: entry.item) }
        } label: {
            HStack(spacing: 12) {
                // A 44 pt cell in a list. It needs the preview rather than
                // the full image, and the warm hit even more so.
                CachedAsyncImage(url: router.coverURL(entry.item.id),
                                 useThumbnail: true) { image, pixels in
                    CoverFitting(image: image, pixelSize: pixels, backdrop: .neutral)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.item.title)
                        .lineLimit(1, reservesSpace: true)
                    Text(entry.albumName ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1, reservesSpace: true)
                }
                Spacer()
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Songs are queueable from the Titles page. The ONE shared
        // music item menu (play/queue/add-to-playlist).
        .musicItemMenu(item: entry.item, playerCoordinator: playerCoordinator)
    }
}

/// Locally downloaded music ("Downloaded" entry): every downloaded item the
/// music provider owns, as album cells. Reads the download registry live.
struct MusicDownloadedPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var downloadManager = DownloadManager.shared

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    private var items: [LibraryItem] {
        let music = AppSession.shared.musicProvider
        return downloadManager.downloadedItemIds
            .filter { music.owns(itemId: $0) }
            .compactMap { music.libraryItem(forId: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No downloaded music", systemImage: "arrow.down.circle")
                } description: {
                    Text("Albums and playlists you download appear here for offline listening.")
                }
            } else {
                ScrollView {
                    CoverGrid(columns: columns) {
                        ForEach(items) { item in
                            AlbumCell(item: item, playerCoordinator: playerCoordinator)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text("Downloaded"))
    }
}

/// The genre page behind the "Genres" browse entry. The SEARCH deck's
/// chip grid (shared `CategoryTile`, one chip idiom), fed from the
/// server's genre list (Subsonic getGenres with counters; Jellyfin without.
/// Then the count numeral hides and the order is alphabetical, both via the
/// pure `MusicGenrePresentation`). Curated SF glyphs, `music.note` fallback.
struct MusicGenresPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @State private var genres: [MusicGenre] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    private static let columns = [GridItem(.flexible(), spacing: 12),
                                  GridItem(.flexible(), spacing: 12)]

    var body: some View {
        Group {
            if genres.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if genres.isEmpty {
                // Rule 3: a failed load is distinguishable from "none".
                if loadFailed {
                    ContentUnavailableView {
                        Label("Music unavailable", systemImage: "music.note")
                    } description: {
                        Text("Could not load genres. Check your connection and try again.")
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                    .accessibilityIdentifier("genres-error")
                } else {
                    ContentUnavailableView("No genres", systemImage: "music.note")
                        .accessibilityIdentifier("genres-empty")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: 12) {
                        ForEach(genres) { genre in
                            CategoryTile(title: genre.name,
                                         systemImage: MusicGenreGlyphs.symbol(for: genre.name),
                                         count: genre.albumCount ?? genre.songCount,
                                         accessibilityId: "genre-tile-\(genre.name)") {
                                pushRoute(.genre(genre))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text("Genres"))
        .task { if genres.isEmpty { await load() } }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            genres = MusicGenrePresentation.presented(try await AppSession.shared.musicProvider.genres())
            loadFailed = false
        } catch {
            guard !error.isCancellation else { return }
            loadFailed = true
        }
    }
}

/// One genre. Its albums (grid) with the genre's songs below (paged
/// list). Existing building blocks only: `CoverGrid`+`AlbumCell` and
/// `MusicSongRow`.
struct MusicGenreDetailPage: View {
    let genre: MusicGenre
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var albums: [LibraryItem] = []
    @State private var songs: [MusicTopSong] = []
    @State private var isLoading = true
    @State private var songsLoading = false
    @State private var songsEnd = false

    private let songPageSize = 50
    private let albumColumns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        Group {
            if albums.isEmpty && songs.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if albums.isEmpty && songs.isEmpty {
                ContentUnavailableView("No music", systemImage: "music.note")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                        if !albums.isEmpty {
                            RowHeading.plain("Albums")
                            CoverGrid(columns: albumColumns) {
                                ForEach(albums) { album in
                                    AlbumCell(item: album, playerCoordinator: playerCoordinator)
                                }
                            }
                            .padding(.horizontal)
                        }
                        if !songs.isEmpty {
                            RowHeading.plain("Songs")
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(songs) { entry in
                                    MusicSongRow(entry: entry, playerCoordinator: playerCoordinator)
                                        .onAppear {
                                            if entry.id == songs.last?.id { Task { await loadMoreSongs() } }
                                        }
                                }
                                if songsLoading && !songs.isEmpty {
                                    ProgressView().frame(maxWidth: .infinity).padding()
                                }
                            }
                        }
                    }
                    .padding(.top, TabContentLayout.topInset)
                    .bottomBarClearance()
                }
            }
        }
        .navigationTitle(Text(genre.name))
        .task {
            guard albums.isEmpty, songs.isEmpty else { return }
            isLoading = true
            defer { isLoading = false }
            // Best-effort pair. A failed half keeps the other (stale beats
            // empty); both empty shows the empty state.
            albums = (try? await AppSession.shared.musicProvider
                .genreAlbums(genre: genre.name, offset: 0, size: 100)) ?? []
            await loadMoreSongs()
        }
    }

    private func loadMoreSongs() async {
        guard !songsLoading, !songsEnd else { return }
        songsLoading = true
        defer { songsLoading = false }
        let next = (try? await AppSession.shared.musicProvider
            .genreSongs(genre: genre.name, offset: songs.count, size: songPageSize)) ?? []
        if next.isEmpty { songsEnd = true; return }
        var seen = Set(songs.map(\.id))
        songs += next.filter { seen.insert($0.id).inserted }
        if next.count < songPageSize { songsEnd = true }
    }
}


/// Welle 3 (DIE REGEL: every row has a page): ONE parameterised shelf page.
/// The full grid behind "Recently Played" and "Recently Added". Loads a wider
/// cut than the 20-item row source (the shelf API has no paging; 100 is the
/// honest upper request, the server may return less). Tap class stays
/// NACHSCHLAGEN (AlbumCell → album page), inherited from the row.
struct MusicShelfPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    let shelf: MusicShelf
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var isLoading = false

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    private var title: LocalizedStringKey {
        shelf == .recent ? "Recently Played" : "Recently Added"
    }

    var body: some View {
        ScrollView {
            if items.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if items.isEmpty {
                ContentUnavailableView("No music", systemImage: "music.note")
            } else {
                CoverGrid(columns: columns) {
                    ForEach(items) { album in
                        AlbumCell(item: album, playerCoordinator: playerCoordinator)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle(Text(title))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task {
            guard items.isEmpty else { return }
            isLoading = true
            defer { isLoading = false }
            items = (try? await AppSession.shared.musicProvider.albumShelf(shelf: shelf, size: 100)) ?? []
        }
    }
}

/// Welle 3: the free-music (Jamendo) page behind Home's row. Tile grid,
/// NACHSCHLAGEN tap (detail sheet carries the ToS-mandated attribution and
/// the prominent Play).
struct FreeJamendoPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var detailItem: LibraryItem?
    /// Server-loaded genre rows (shelf key → row items). Empty shelves
    /// hide themselves after the answer (G8: no empty shelf lies).
    @State private var shelfRows: [String: [LibraryItem]] = [:]

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        ScrollView {
            if items.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if items.isEmpty && loadFailed {
                // Same rule as the shelves: a failed load is not "no music".
                ContentUnavailableView {
                    Label("Free Music (Jamendo)", systemImage: "music.note")
                } description: {
                    Text("This could not be loaded. Check your connection.")
                } actions: {
                    Button("Retry") { Task { await loadAll() } }
                }
            } else if items.isEmpty {
                ContentUnavailableView("Free Music (Jamendo)", systemImage: "music.note")
            } else {
                // Genre shelf rows FIRST (blueprint form. Row +
                // entry chevron onto the server-paged shelf grid), the weekly
                // popularity trove below. Each row loads SERVER-side via the
                // tags parameter. No local filtering of a 200 pool.
                LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    ForEach(CatalogGenreAxis.musicShelves, id: \.key) { shelf in
                        if let rowItems = shelfRows[shelf.key], !rowItems.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                RowHeading.entry(verbatim: shelf.title,
                                                 destination: MusicRoute.jamendoShelf(shelf.key))
                                jamendoTileRow(rowItems)
                            }
                        }
                    }
                    RowHeading.plain("Popular This Week")
                    CoverGrid(columns: columns) {
                        ForEach(items) { item in
                            // Tap spielt (Musik), Kontextmenue zeigt Details.
                            FreeCatalogBookTile(
                                item: item,
                                placeholderSystemImage: "music.note",
                                onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: pushRoute)
                            }
                        })
                            .contextMenu {
                                Button {
                                    detailItem = item
                                } label: { Label("Details", systemImage: "info.circle") }
                        CatalogQueueButtons(itemId: item.id)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle(Text("Free Music (Jamendo)"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .task {
            guard items.isEmpty else { return }
            await loadAll()
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    private func loadAll() async {
            isLoading = true
            loadFailed = false
            defer { isLoading = false }
            let provider = FreeCatalogProvider.shared
            do {
                let tracks = try await JamendoClient.popularTracks(limit: 60)
                items = tracks.compactMap { provider.remember(track: $0) }
            } catch {
                guard !error.isCancellation else { return }
                Logger.library.error("JAMENDO trove FAILED: \(String(describing: error), privacy: .public)")
                loadFailed = true
            }
            // Shelf rows concurrently. A failing genre drops out instead
            // of taking the page down. Tracks (Sendable) cross the group
            // boundary; remember() runs afterwards on the main actor.
            //
            // The failure TRAVELS instead of being swallowed: with the
            // envelope check a throttle now throws, and a `try?` here was
            // the one place that turned the measurement back into a silent
            // empty shelf. The reason goes to the log per shelf; a shelf
            // that answered empty stays honestly absent.
            let shelfTracks = await withTaskGroup(of: (String, [JamendoTrack], String?).self) { group in
                for shelf in CatalogGenreAxis.musicShelves {
                    let key = shelf.key
                    group.addTask {
                        let tags = CatalogGenreAxis.musicTags(forShelf: key)
                        do {
                            return (key, try await JamendoClient.popularTracks(limit: 12, tags: tags), nil)
                        } catch {
                            return (key, [], error.isCancellation ? nil
                                    : (FreeCatalog.failureReason(error) ?? String(describing: type(of: error))))
                        }
                    }
                }
                var out: [(String, [JamendoTrack], String?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (key, tracks, reason) in shelfTracks {
                if let reason {
                    Logger.library.error("JAMENDO shelf=\(key, privacy: .public) FAILED: \(reason, privacy: .public)")
                    continue
                }
                shelfRows[key] = tracks.compactMap { provider.remember(track: $0) }
            }
    }

    private func jamendoTileRow(_ rowItems: [LibraryItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(rowItems) { item in
                    // Musik-Kachel. Tap spielt, Langdruck zeigt Details.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: pushRoute)
                            }
                        })
                    .cardRowSlot(spacing: 14)
                    .contextMenu {
                        Button {
                            Task { await playerCoordinator.open(item: item) }
                        } label: { Label("Play", systemImage: "play.fill") }
                        CatalogQueueButtons(itemId: item.id)
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }
}

/// One Jamendo genre shelf as a full grid. Pages SERVER-side over the
/// tags query (offset), same tile language as the trove.
struct JamendoShelfPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    let shelfKey: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var detailItem: LibraryItem?
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var loadFailed = false
    @State private var offset = 0
    /// The active choice of mood, tempo and instrumental.
    @State private var filter = JamendoFilter.none

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]
    private let pageSize = 40

    private var title: String {
        CatalogGenreAxis.musicShelves.first { $0.key == shelfKey }?.title ?? shelfKey
    }

    var body: some View {
        ScrollView {
            filterBar
                .padding(.top, TabContentLayout.topInset)
            CoverGrid(columns: columns) {
                ForEach(items) { item in
                    // Tap spielt (Musik), Kontextmenue zeigt Details.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: pushRoute)
                            }
                        })
                    .contextMenu {
                        Button {
                            detailItem = item
                        } label: { Label("Details", systemImage: "info.circle") }
                        CatalogQueueButtons(itemId: item.id)
                    }
                }
                if !reachedEnd && !loadFailed {
                    Color.clear.frame(height: 1)
                        .onAppear { Task { await load() } }
                }
            }
            .padding(.horizontal)
            // The archive shelves' pattern, reused: a page never goes black
            // without a word. Loading spins, a failed load says so WITH a way
            // back in, and a truly empty shelf says that instead.
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if items.isEmpty && !loadFailed && !isLoading && filter.isActive {
                // A filter that leads to zero hits SAYS so instead of
                // showing an empty surface, and it can be taken back from
                // here, so the row is not read as broken.
                ContentUnavailableView {
                    Label("No tracks with this filter", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text("The shelf has titles, this combination has none.")
                } actions: {
                    Button("Reset filter") { applyFilter(.none) }
                }
                .padding(.top, 40)
            } else if items.isEmpty && loadFailed {
                ContentUnavailableView {
                    Label { Text(verbatim: title) } icon: { Image(systemName: "music.note") }
                } description: {
                    Text("This shelf could not be loaded. Check your connection.")
                } actions: {
                    Button("Retry") { Task { await load(retry: true) } }
                }
                .padding(.top, 40)
            } else if items.isEmpty && reachedEnd {
                ContentUnavailableView("Nothing in this shelf right now.",
                                       systemImage: "music.note")
                    .padding(.top, 40)
            }
            Color.clear.frame(height: 1).bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    /// Mood and tempo as FILTERS on a shelf's full page, instrumental as a
    /// SWITCH. No rows of their own.
    ///
    /// Jamendo filters all three SERVER-side (probed at the endpoint), so the
    /// page throws nothing away afterwards.
    @ViewBuilder
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: String(localized: "Instrumental"),
                           selected: filter.instrumentalOnly) {
                    var neu = filter; neu.instrumentalOnly.toggle(); applyFilter(neu)
                }
                ForEach(JamendoFilter.Tempo.allCases, id: \.rawValue) { tempo in
                    filterChip(title: Self.tempoTitle(tempo), selected: filter.tempo == tempo) {
                        var neu = filter
                        neu.tempo = filter.tempo == tempo ? nil : tempo
                        applyFilter(neu)
                    }
                }
                ForEach(JamendoFilter.Mood.allCases, id: \.rawValue) { mood in
                    filterChip(title: Self.moodTitle(mood), selected: filter.mood == mood) {
                        var neu = filter
                        neu.mood = filter.mood == mood ? nil : mood
                        applyFilter(neu)
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    private func filterChip(title: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    private static func tempoTitle(_ tempo: JamendoFilter.Tempo) -> String {
        switch tempo {
        case .slow: String(localized: "Slow")
        case .medium: String(localized: "Medium")
        case .fast: String(localized: "Fast")
        }
    }

    private static func moodTitle(_ mood: JamendoFilter.Mood) -> String {
        switch mood {
        case .energetic: String(localized: "Energetic")
        case .happy: String(localized: "Happy")
        case .emotional: String(localized: "Emotional")
        case .romantic: String(localized: "Romantic")
        case .upbeat: String(localized: "Upbeat")
        }
    }

    /// Every change resets the page, otherwise filtered and unfiltered hits
    /// would mix in one grid.
    private func applyFilter(_ neu: JamendoFilter) {
        guard neu != filter else { return }
        filter = neu
        items = []
        offset = 0
        reachedEnd = false
        loadFailed = false
        Task { await load() }
    }

    private func load(retry: Bool = false) async {
        guard !isLoading, !reachedEnd else { return }
        if retry { loadFailed = false }
        guard !loadFailed else { return }
        isLoading = true
        defer { isLoading = false }
        let provider = FreeCatalogProvider.shared
        let tags = CatalogGenreAxis.musicTags(forShelf: shelfKey)
        do {
            let tracks = try await JamendoClient.popularTracks(limit: pageSize, tags: tags,
                                                               offset: offset, filter: filter)
            let new = tracks.compactMap { provider.remember(track: $0) }
            var seen = Set(items.map(\.id))
            items += new.filter { seen.insert($0.id).inserted }
            offset += pageSize
            // "There is no more" is an answer only a SUCCESSFUL fetch can
            // give. The failed first fetch used to set it too. The reload
            // anchor vanished and the page never tried again: a black grid
            // without a word.
            if tracks.count < pageSize { reachedEnd = true }
        } catch {
            guard !error.isCancellation else { return }
            Logger.library.error("JAMENDO shelf=\(shelfKey, privacy: .public) offset=\(offset) FAILED: \(String(describing: error), privacy: .public)")
            loadFailed = true
        }
    }
}

/// The small music-catalog page behind Start's "Entdecken ·
/// Musik" row. The I2 surface, earlier. One source row per ACTIVE catalog
/// (a gated-off source loads nothing, so its row is simply absent), each
/// heading an entry chevron onto the source's existing full page (DIE REGEL).
/// netlabels/78rpm/LMA grow into this block later (I2).
struct MusicCatalogAreaPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = FreeCatalogStore.shared
    @State private var detailItem: LibraryItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                if !store.rows.netlabels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeading.entry("Netlabels", destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.netlabels))
                            .catalogShuffle(area: ArchiveMusicCatalog.netlabels,
                                            coordinator: playerCoordinator)
                        tileRow(store.rows.netlabels)
                    }
                }
                // 🟡 Side note, measured: the section did not "fall
                // away for a reason". It vanished SILENTLY whenever the
                // rows were empty, although the service is switched on
                // (Jamendo needs a client key; without one the catalogue
                // answers nothing). An enabled service that shows nothing
                // has to say why (G8), otherwise the page reads as broken.
                if AppStorageKeys.jamendoActive {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeading.entry("Free Music (Jamendo)", destination: MusicRoute.freeJamendo)
                            .jamendoShuffle(coordinator: playerCoordinator)
                        if !store.rows.freeMusic.isEmpty {
                            tileRow(store.rows.freeMusic)
                        } else if let problem = store.rows.freeMusicProblem {
                            // The page said "add a client key under Network
                            // Services" while the same source
                            // loaded fine one level deeper. The key ships
                            // with the build. The row now carries the ONE
                            // state line the loader actually produced.
                            Text(problem)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }
                }
                // The SAME row as the music tab (shared component, not a
                // copy), so the two surfaces cannot drift apart.
                ShellacSection(playerCoordinator: playerCoordinator)
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Discover · Music"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    /// Same tile anatomy as the source rows (NACHSCHLAGEN, license capsule on
    /// the detail sheet; long-press keeps the Play shortcut).
    private func tileRow(_ items: [LibraryItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
                    // Tap spielt (Musik), Kontextmenue zeigt Details.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: pushRoute)
                            }
                        })
                    .cardRowSlot(spacing: 14)
                    .contextMenu {
                        Button {
                            detailItem = item
                        } label: { Label("Details", systemImage: "info.circle") }
                        CatalogQueueButtons(itemId: item.id)
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }
}

/// The page of one playlist. Deliberately plain: a list of ids, and every
/// row resolves itself when it is shown.
///
/// An entry THIS device cannot resolve (a server title without a connected
/// server, a file that never lay here) is **kept visibly, not removed**. It
/// says why it is not playable right now and is skipped during playback.
/// Resolvability is a property of the DEVICE, never of the entry; otherwise
/// device B would trim device A's list.
struct MaerPlaylistPage: View {
    let playlistId: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var store = MaerPlaylists.shared
    @State private var renaming = false
    @State private var newName = ""

    private var playlist: MaerPlaylists.Playlist? { store.playlist(id: playlistId) }

    var body: some View {
        List {
            if let playlist {
                if playlist.isRescue, let reason = playlist.rescueReason, !reason.isEmpty {
                    // A rescue copy says what it is, right where it is.
                    Section {
                        Label { Text(verbatim: reason) } icon: { Image(systemName: "doc.on.doc") }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(playlist.itemIds, id: \.self) { id in
                        row(id)
                    }
                    .onDelete { offsets in
                        for index in offsets { store.remove(itemId: playlist.itemIds[index], from: playlistId) }
                    }
                    .onMove { source, destination in
                        store.move(playlistId: playlistId, from: source, to: destination)
                    }
                } footer: {
                    // Explained once, calmly, not on every add.
                    Text("Playlists on your devices can mix everything: your server's music, free catalogs and local files. They stay on your devices, because a server cannot reference a catalog address.")
                }
            }
        }
        .navigationTitle(Text(verbatim: playlist?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newName = playlist?.name ?? ""
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) {
                        store.delete(playlistId: playlistId)
                    } label: { Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(playlistId: playlistId, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        // Entries added before the snapshots existed get theirs here, on the
        // device that can still resolve them.
        .task { store.backfillTitles(playlistId: playlistId) }
    }

    @ViewBuilder
    private func row(_ id: String) -> some View {
        // THE seam answers: a playable item (known here, or a catalogue id
        // named by its snapshot), or the reason it is not playable on this
        // device. The row never decides on its own what resolves.
        let carried = playlist?.carried(for: id)
        let resolution = playlist.map { store.resolution(of: id, in: $0) }
            ?? AppSession.shared.resolve(forId: id, carried: nil)
        let item = resolution.item
        let title = carried?.title ?? item?.media?.metadata?.title ?? item?.title ?? id
        // A STUB row (self-describing catalogue id, no snapshot yet) names
        // itself by fetching its detail; the won snapshot is written back
        // and travels with the list.
        let needsName = carried == nil && item?.media == nil
        Button {
            if let item { Task { await playerCoordinator.open(item: item) } }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .task(id: id) {
                        guard needsName else { return }
                        await store.fetchMissingTitles([id], playlistId: playlistId)
                    }
                    .font(.subheadline)
                    .foregroundStyle(item == nil ? .secondary : .primary)
                if let reason = resolution.reason {
                    // Visibly kept instead of silently removed, WITH the
                    // reason. Resolvability is a property of the DEVICE,
                    // never of the entry.
                    Text(Self.reasonText(reason))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let author = carried?.subtitle ?? item?.author {
                    Text(verbatim: author).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
    }

    /// The reason in the person's words. One place for the sentences.
    static func reasonText(_ reason: UnavailableReason) -> String {
        switch reason {
        case .sourceNotConfigured: return String(localized: "Not available on this device: the source is not set up here")
        case .notInLibrary: return String(localized: "Not available on this device: not in this device's library")
        case .fileNotOnDevice: return String(localized: "Not available on this device: the file is not on this device")
        case .showNotFollowed: return String(localized: "Not available on this device: the show is not followed here")
        case .unknownSource: return String(localized: "Not available on this device: unknown source")
        }
    }
}
