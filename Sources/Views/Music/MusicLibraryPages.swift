// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Musik-Tab-Neuordnung (30.07): the tab shows a library LIST (artists ·
/// albums · songs · playlists · downloaded — the Apple-Music pattern); these
/// are the three pages that had no own surface before. Albums reuses the
/// full MusicViewModel pipeline (staged pages, sort, shuffle) — the grid
/// moved here from the tab body unchanged.
/// fb21fbd: THE music sort menu, at the surfaces it orders (albums + songs)
/// instead of in the shared toolbar. Content unchanged, including the honest
/// offline treatment: the sort is server-side (`search3` order), so offline it
/// is disabled WITH a reason rather than silently doing nothing. A local sort
/// over the loaded page would be a different order under the same name.
struct MusicSortMenu: View {
    @Binding var musicSort: MusicSortOption
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        Picker("Sort By", selection: $musicSort) {
            ForEach(MusicSortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .disabled(!networkMonitor.isConnected)
        if !networkMonitor.isConnected {
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
                        // fb21fbd: the sort sits AT the grid it orders — it
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
        .onChange(of: musicSort) { _, newSort in
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
        // dropping the error is fine here — the empty state carries the hint.
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
    let entry: MusicTopSong
    @ObservedObject var playerCoordinator: PlayerCoordinator

    var body: some View {
        Button {
            Task { await playerCoordinator.open(item: entry.item) }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: AppSession.shared.coverURL(forItemId: entry.item.id)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
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
        // M2: songs are queueable from the Titles page — the ONE shared
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

/// M3: the genre page behind the "Genres" browse entry — the SEARCH deck's
/// chip grid (shared `CategoryTile`, Regel 2: one chip idiom), fed from the
/// server's genre list (Subsonic getGenres with counters; Jellyfin without —
/// then the count numeral hides and the order is alphabetical, both via the
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
            loadFailed = true
        }
    }
}

/// M3: one genre — its albums (grid) with the genre's songs below (paged
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
            // Best-effort pair — a failed half keeps the other (stale beats
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


/// Welle 3 (DIE REGEL: every row has a page): ONE parameterised shelf page —
/// the full grid behind "Recently Played" and "Recently Added". Loads a wider
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

/// Welle 3: the free-music (Jamendo) page behind Home's row — tile grid,
/// NACHSCHLAGEN tap (detail sheet carries the ToS-mandated attribution and
/// the prominent Play).
struct FreeJamendoPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var isLoading = false
    @State private var detailItem: LibraryItem?
    /// P8: server-loaded genre rows (shelf key → row items). Empty shelves
    /// hide themselves after the answer (G8: no empty shelf lies).
    @State private var shelfRows: [String: [LibraryItem]] = [:]

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    var body: some View {
        ScrollView {
            if items.isEmpty && isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if items.isEmpty {
                ContentUnavailableView("Free Music (Jamendo)", systemImage: "music.note")
            } else {
                // P8 (cde97a9): genre shelf rows FIRST (blueprint form — row +
                // entry chevron onto the server-paged shelf grid), the weekly
                // popularity trove below. Each row loads SERVER-side via the
                // tags parameter — no local filtering of a 200 pool.
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
                            // M1: Tap spielt (Musik), Kontextmenue zeigt Details.
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
            isLoading = true
            defer { isLoading = false }
            let provider = FreeCatalogProvider.shared
            let tracks = (try? await JamendoClient.popularTracks(limit: 60)) ?? []
            items = tracks.compactMap { provider.remember(track: $0) }
            // P8: shelf rows concurrently — a failing genre drops out instead
            // of taking the page down. Tracks (Sendable) cross the group
            // boundary; remember() runs afterwards on the main actor.
            let shelfTracks = await withTaskGroup(of: (String, [JamendoTrack]).self) { group in
                for shelf in CatalogGenreAxis.musicShelves {
                    let key = shelf.key
                    group.addTask {
                        let tags = CatalogGenreAxis.musicTags(forShelf: key)
                        return (key, (try? await JamendoClient.popularTracks(limit: 12, tags: tags)) ?? [])
                    }
                }
                var out: [(String, [JamendoTrack])] = []
                for await result in group { out.append(result) }
                return out
            }
            for (key, tracks) in shelfTracks {
                shelfRows[key] = tracks.compactMap { provider.remember(track: $0) }
            }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func jamendoTileRow(_ rowItems: [LibraryItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(rowItems) { item in
                    // M1: Musik-Kachel — Tap spielt, Langdruck zeigt Details.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: pushRoute)
                            }
                        })
                    .containerRelativeFrame(.horizontal,
                                            count: CardMetrics.recommendationColumns(regularWidth: false),
                                            spacing: 14)
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

/// P8: one Jamendo genre shelf as a full grid — pages SERVER-side over the
/// tags query (offset), same tile language as the trove.
struct JamendoShelfPage: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    let shelfKey: String
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []
    @State private var detailItem: LibraryItem?
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var offset = 0

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]
    private let pageSize = 40

    private var title: String {
        CatalogGenreAxis.musicShelves.first { $0.key == shelfKey }?.title ?? shelfKey
    }

    var body: some View {
        ScrollView {
            CoverGrid(columns: columns) {
                ForEach(items) { item in
                    // M1: Tap spielt (Musik), Kontextmenue zeigt Details.
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
                if !reachedEnd {
                    Color.clear.frame(height: 1)
                        .onAppear { Task { await load() } }
                }
            }
            .padding(.horizontal)
            .bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private func load() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let provider = FreeCatalogProvider.shared
        let tags = CatalogGenreAxis.musicTags(forShelf: shelfKey)
        let tracks = (try? await JamendoClient.popularTracks(limit: pageSize, tags: tags,
                                                             offset: offset)) ?? []
        let new = tracks.compactMap { provider.remember(track: $0) }
        var seen = Set(items.map(\.id))
        items += new.filter { seen.insert($0.id).inserted }
        offset += pageSize
        if tracks.count < pageSize { reachedEnd = true }
    }
}

/// Auftrag L1: the small music-catalog page behind Start's "Entdecken ·
/// Musik" row — the I2 surface, earlier. One source row per ACTIVE catalog
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
                if !store.rows.classical.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeading.entry("Free Classical", destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.classical))
                            .catalogShuffle(area: ArchiveMusicCatalog.classical,
                                            coordinator: playerCoordinator)
                        tileRow(store.rows.classical)
                    }
                }
                if !store.rows.netlabels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeading.entry("Netlabels", destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.netlabels))
                            .catalogShuffle(area: ArchiveMusicCatalog.netlabels,
                                            coordinator: playerCoordinator)
                        tileRow(store.rows.netlabels)
                    }
                }
                if !store.rows.freeMusic.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        RowHeading.entry("Free Music (Jamendo)", destination: MusicRoute.freeJamendo)
                            .jamendoShuffle(coordinator: playerCoordinator)
                        tileRow(store.rows.freeMusic)
                    }
                }
                // Auflage 1: the 78s are reachable only through their
                // shelves — the entry leads to the shelf list, never to an
                // undivided view of the collection.
                VStack(alignment: .leading, spacing: 10) {
                    RowHeading.entry("Old Records", destination: MusicRoute.shellacArea)
                    // GT-Befund 09.08.: die Reihe zeigt die FAECHER, nicht
                    // Titel — eine echte Vorschau ihrer Seite, und per
                    // Konstruktion nie eine ungegliederte Auswahl (Auflage 1).
                    // Kachelform = die Genre-Felder-Praezedenz (CategoryTile).
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(ArchiveMusicCatalog.shellacShelves) { shelf in
                                CategoryTile(title: shelf.title,
                                             systemImage: MusicGenreGlyphs.symbol(for: shelf.subject),
                                             count: nil,
                                             accessibilityId: "shellac-tile-\(shelf.key)") {
                                    pushRoute(MusicRoute.archiveMusic(shelf))
                                }
                                .frame(width: 200)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Discover · Music"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// Same tile anatomy as the source rows (NACHSCHLAGEN, license capsule on
    /// the detail sheet; long-press keeps the Play shortcut).
    private func tileRow(_ items: [LibraryItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
                    // M1: Tap spielt (Musik), Kontextmenue zeigt Details.
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: pushRoute)
                            }
                        })
                    .containerRelativeFrame(.horizontal,
                                            count: CardMetrics.recommendationColumns(regularWidth: false),
                                            spacing: 14)
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

/// Paket 1: die Seite einer Mär-Playlist. Bewusst schlicht — eine Liste von
/// Kennungen, jede Zeile löst sich beim Anzeigen selbst auf.
///
/// AUFLAGE 24132fa: Ein Eintrag, den DIESES Gerät nicht auflösen kann (ein
/// Server-Titel ohne verbundenen Server, eine Datei, die hier nie lag), wird
/// **sichtbar behalten, nicht entfernt** — er sagt, warum er gerade nicht
/// spielbar ist, und wird beim Abspielen übersprungen. Auflösbarkeit ist eine
/// Eigenschaft des GERÄTS, nie des Eintrags; sonst beschnitte Gerät B die
/// Liste von Gerät A.
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
                    // P3: einmal ruhig erklären, nicht bei jedem Hinzufügen.
                    Text("Playlists on your devices can mix everything — your server's music, free catalogs and local files. They stay on your devices, because a server cannot reference a catalog address.")
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
    }

    @ViewBuilder
    private func row(_ id: String) -> some View {
        let item = AppSession.shared.libraryItem(forId: id)
        Button {
            if let item { Task { await playerCoordinator.open(item: item) } }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item?.title ?? id)
                    .font(.subheadline)
                    .foregroundStyle(item == nil ? .secondary : .primary)
                if item == nil {
                    // Sichtbar behalten statt still entfernen.
                    Text("Not available on this device")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let author = item?.author {
                    Text(verbatim: author).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
    }
}
