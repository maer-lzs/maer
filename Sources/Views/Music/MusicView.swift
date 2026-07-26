// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine

/// Music tab (Subsonic/Navidrome). Media-type-specific layout, deliberately not
/// the audiobook grid: shelves on top (recently added, most played), browse rows
/// for artists/playlists, then the full album grid. Tapping an album opens its
/// track list; playback runs through the shared player.
struct MusicView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Only the visible tab reports scroll to the shared BottomBarState; hidden-
    /// but-mounted tabs must stay silent (see reportsBottomBarScroll(active:)).
    var isActive: Bool = true
    #if DEBUG
    @StateObject private var vm = MusicViewModel(source: .uitestOrLive)
    #else
    @StateObject private var vm = MusicViewModel()
    #endif
    // Teil 2: server-side album sort, persisted; shared with the toolbar menu in
    // LibraryView via the same AppStorage key.
    @AppStorage(AppStorageKeys.musicSortOption) private var musicSort = MusicSortOption.nameAZ
    // F5: create-playlist flow.
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    /// F5: playlists newest-changed first (default sort).
    private var sortedPlaylists: [MusicPlaylist] {
        PlaylistPresentation.sortedByChanged(vm.playlists) {
            $0.changedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    var body: some View {
        Group {
            // Full-screen error ONLY when there is nothing to show — a failed
            // refresh must never displace the already-loaded library (stale
            // beats empty, like the book library).
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
                // S17b: `bottomBarClearance()` must sit INSIDE the ScrollView (on
                // the content) — like the podcast + audiobook tabs — so the scroll
                // stays full-bleed and the content scrolls UNDER the glass bar.
                // Applied OUTSIDE it inset the ScrollView, exposing the dark
                // background behind the bar (the "residual background").
                ScrollView { content.bottomBarClearance() }
                    // S17: bind the Music tab to the shared BottomBarState like
                    // the other tabs — without this its scroll never reported, so
                    // the bar stayed expanded (heavy/opaque look) and never
                    // collapsed. One binding, both symptoms.
                    .reportsBottomBarScroll(active: isActive)
            }
        }
        .task {
            vm.sort = musicSort   // honour the persisted sort on the first load
            await vm.loadIfNeeded()
        }
        .onChange(of: musicSort) { _, newSort in
            Task { await vm.setSort(newSort) }
        }
        // Y35: "Sync Now" (settings) refreshed only the provider cache — a
        // MOUNTED tab (tabs stay alive once visited) never re-read it. The
        // sync signal re-runs the EXISTING load path into this live model.
        .onReceive(AppSession.shared.musicProvider.librarySynced) { _ in
            Task { await vm.reload() }
        }
        // A5: return promptly (stuck indicator otherwise) AND survive the
        // gesture's cancellation — the staged reload continues as a background
        // task and replaces content silently (stale beats empty).
        .refreshable {
            // Pull-to-refresh also pulls fresh artwork: a server-side re-tag
            // keeps the cover id (and thus the URL key) unchanged, so without
            // invalidation the cache would keep serving the old cover.
            for item in vm.albums + vm.newest + vm.frequent {
                if let url = AppSession.shared.coverURL(forItemId: item.id) {
                    ImageCache.shared.invalidate(url: url)
                }
            }
            let work = Task { await vm.reload() }
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = work
        }
        .overlay(alignment: .top) {
            if vm.isLoading && !vm.albums.isEmpty { RefreshActivityPill() }
        }
        // F5: create a server playlist (songs are added later via the song
        // context menu). The server is the source of truth.
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    _ = try? await AppSession.shared.musicProvider.createPlaylist(name: name)
                    await vm.reload()
                }
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("Create an empty playlist on your music server.")
        }
    }

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
            // Inline hint when a refresh failed but content is still shown.
            if let error = vm.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            // F5: playlist card row on top. Recently-Added / Most-Played shelves
            // are intentionally gone here — the Home tab owns those; the music
            // tab is playlists (top) + album grid (backbone) + artists browse.
            playlistRow

            if !vm.artists.isEmpty {
                VStack(spacing: 0) {
                    browseRow("Artists", systemImage: "music.mic", route: .artists(vm.artists))
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            // "Albums" header carries the whole-library shuffle (same component
            // as the album/playlist detail) — on the existing header row so it
            // adds no vertical shift to the grid below.
            HStack {
                Text("Albums").font(.title3).bold()
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
    }

    private func shelf(_ title: LocalizedStringKey, _ items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        AlbumCell(item: item, width: 150, playerCoordinator: playerCoordinator)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func browseRow(
        _ title: LocalizedStringKey, systemImage: String, route: MusicRoute
    ) -> some View {
        // X15: value-based push so a media-tab tap (which empties navigationPath)
        // pops the artist/playlist list back to the library.
        NavigationLink(value: route) {
            Label(title, systemImage: systemImage)
                .padding(.vertical, 12)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(route.accessibilityId)
    }

    /// F5: the playlist card row — vertical poster cards (2×2 mosaic + name +
    /// metadata) plus the "New Playlist" card at the end. Always shown so a
    /// playlist can be created even before any exist.
    /// Kachel-Auftrag: column count of the playlist row per width class.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var playlistRow: some View {
        let columns = CardMetrics.playlistColumns(regularWidth: horizontalSizeClass == .regular)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Playlists").font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(sortedPlaylists) {
                        PlaylistCard(playlist: $0)
                            // Screen-relative slots + peek instead of fixed 135 pt.
                            .containerRelativeFrame(.horizontal, count: columns, span: 1, spacing: 16)
                    }
                    NewPlaylistCard { showNewPlaylist = true }
                        .containerRelativeFrame(.horizontal, count: columns, span: 1, spacing: 16)
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }
}

/// F5: a playlist as a vertical poster card — the 2×2 mosaic (Y58 coverOverride
/// slot) over the name and a metadata line "18 tracks · 1:12". Tapping opens the
/// detail page (no direct playback).
private struct PlaylistCard: View {
    let playlist: MusicPlaylist
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @Environment(\.pushMusicRoute) private var pushRoute
    @State private var coverURLs: [URL] = []

    var body: some View {
        // Text IN the card on a gradient (owner Ergänzung) — the same
        // text-on-scrim idiom as the Featured/Continue cards, so the card is
        // a closed portrait rectangle and row baselines can't diverge.
        Button {
            pushRoute(.album(playlistLibraryItem(playlist)))
        } label: {
            PlaylistArtwork(
                playlistID: AppSession.shared.musicProvider.itemId(playlistId: playlist.id),
                coverURLs: coverURLs)
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name ?? String(localized: "Playlist"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1, reservesSpace: true)
                        Text(metaLine)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1, reservesSpace: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                       startPoint: .top, endPoint: .bottom))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Playlist basics: rename/delete from the card row too.
        .contextMenu {
            Button {
                renameText = playlist.name ?? ""
                showRename = true
            } label: { Label("Rename Playlist", systemImage: "pencil") }
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("Delete Playlist", systemImage: "trash")
            }
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                Task {
                    try? await AppSession.shared.musicProvider
                        .renamePlaylist(itemId: AppSession.shared.musicProvider.itemId(playlistId: playlist.id),
                                        newName: renameText)
                    AppSession.shared.musicProvider.librarySynced.send()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this playlist?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    try? await AppSession.shared.musicProvider
                        .deletePlaylist(itemId: AppSession.shared.musicProvider.itemId(playlistId: playlist.id))
                    AppSession.shared.musicProvider.librarySynced.send()
                }
            }
        }
        // Kachel-Auftrag: fills its containerRelativeFrame slot (MediaTile is
        // maxWidth + aspectRatio already) — no fixed width anymore.
        .task(id: playlist.id) {
            let music = AppSession.shared.musicProvider
            let ids = await music.playlistMosaicCoverIDs(forItemId: music.itemId(playlistId: playlist.id))
            coverURLs = ids.compactMap { music.coverURL(coverArtId: $0) }
        }
    }

    private var metaLine: String {
        let count = playlist.songCount ?? 0
        let duration = PlaylistPresentation.durationText(seconds: Int(playlist.duration ?? 0))
        return "\(count) \(String(localized: "tracks")) · \(duration)"
    }
}

/// F5: the dashed "New Playlist" card at the end of the row → create flow.
private struct NewPlaylistCard: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(.secondary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(Image(systemName: "plus").font(.title).foregroundStyle(.secondary))
                Text("New Playlist")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("new-playlist-card")
    }
}

/// Square album tile → album detail. Reused by shelves and the grid.
struct AlbumCell: View {
    let item: LibraryItem
    var width: CGFloat? = nil
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// D4/B3: single-line titles truncate to fragments at accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // X15: value-based push (MusicRoute) so the tab bar can switch library
        // from the album page — plain destination links stayed on the stack.
        NavigationLink(value: MusicRoute.album(item)) {
            VStack(alignment: .leading, spacing: 6) {
                // TF4/E1: the shared scope is the ONE observer of download/network
                // state for this cell — only the cover re-renders on a tick.
                MediaAvailabilityScope(itemId: item.id) { unavailable in
                    CachedAsyncImage(
                        url: AppSession.shared.coverURL(forItemId: item.id),
                        useThumbnail: true, thumbnailMaxPixel: 400
                    ) { image in
                        image.resizable().aspectRatio(1, contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    // A3: dimming alone never carries the state.
                    .offlineUnavailableBadge(unavailable)
                }

                // Layout-shift: reserved lines + an always-present artist line
                // keep every cell in a grid row equally tall (variable heights
                // jump while scrolling).
                Text(item.title).font(.subheadline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
                Text(item.author ?? " ").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .musicItemMenu(item: item, playerCoordinator: playerCoordinator)
    }
}

extension View {
    /// S18: context menu for a music album/song — mirrors the podcast/book
    /// menus (Regel 2). Play + Play Next/Last (global Up-Next queue) +
    /// Add to Playlist + download/delete.
    func musicItemMenu(item: LibraryItem, playerCoordinator: PlayerCoordinator) -> some View {
        modifier(MusicItemMenu(item: item, playerCoordinator: playerCoordinator))
    }
}

/// The music item context menu as a modifier so it can own the add-to-playlist
/// sheet state (a `contextMenu` button can only flip a `@State`; the sheet is
/// attached to the view). One shared surface used by every music album/song cell.
private struct MusicItemMenu: ViewModifier {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var addTarget: AddToPlaylistTarget?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let isPlayable = NetworkMonitor.shared.isConnected
                    || DownloadManager.shared.isDownloaded(itemId: item.id)
                if isPlayable {
                    Button {
                        Task { await playerCoordinator.open(item: item) }
                    } label: { Label("Play", systemImage: "play.fill") }
                    // Global Up-Next queue. An album is one multi-track item, so
                    // queuing it enqueues the whole album as a single entry that
                    // plays its songs as a group (same actions as book/podcast).
                    Button {
                        PlayQueue.shared.playNext(item.id)
                    } label: { Label("Play Next", systemImage: "text.insert") }
                    Button {
                        PlayQueue.shared.playLast(item.id)
                    } label: { Label("Play Last", systemImage: "text.append") }
                }

                // Add to Playlist — only meaningful for Subsonic music items.
                if AppSession.shared.musicProvider.owns(itemId: item.id) {
                    Button {
                        addTarget = AddToPlaylistTarget(itemId: item.id)
                    } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
                }

                if DownloadManager.shared.isDownloaded(itemId: item.id) {
                    Button(role: .destructive) {
                        DownloadManager.shared.deleteDownload(itemId: item.id)
                    } label: { Label("Delete Download", systemImage: "trash") }
                } else if NetworkMonitor.shared.isConnected {
                    Button {
                        Task {
                            let p = AppSession.shared.provider(for: item.id)
                            if let d = try? await p.fetchItemDetail(itemId: item.id) {
                                await DownloadManager.shared.download(item: d, provider: p)
                            }
                        }
                    } label: { Label("Download", systemImage: "arrow.down.circle") }
                }
            }
            .addToPlaylistSheet(target: $addTarget)
    }
}
