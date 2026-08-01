// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Musik-Tab-Neuordnung (30.07): the tab shows a library LIST (artists ·
/// albums · songs · playlists · downloaded — the Apple-Music pattern); these
/// are the three pages that had no own surface before. Albums reuses the
/// full MusicViewModel pipeline (staged pages, sort, shuffle) — the grid
/// moved here from the tab body unchanged.
struct MusicAlbumsPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    #if DEBUG
    @StateObject private var vm = MusicViewModel(source: .uitestOrLive)
    #else
    @StateObject private var vm = MusicViewModel()
    #endif
    @AppStorage(AppStorageKeys.musicSortOption) private var musicSort = MusicSortOption.nameAZ

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

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
                        HStack {
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
