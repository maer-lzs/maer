import SwiftUI

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

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

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
        .onReceive(SubsonicProvider.shared.librarySynced) { _ in
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
            if !vm.newest.isEmpty { shelf("Recently Added", vm.newest) }
            if !vm.frequent.isEmpty { shelf("Most Played", vm.frequent) }

            if !vm.artists.isEmpty || !vm.playlists.isEmpty {
                VStack(spacing: 0) {
                    if !vm.artists.isEmpty {
                        browseRow("Artists", systemImage: "music.mic", route: .artists(vm.artists))
                    }
                    if !vm.playlists.isEmpty {
                        Divider().padding(.leading, 52)
                        browseRow("Playlists", systemImage: "music.note.list", route: .playlists(vm.playlists))
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            Text("Albums").font(.title3).bold().padding(.horizontal)
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

                Text(item.title).font(.subheadline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if let artist = item.author {
                    Text(artist).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
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
    /// download/delete.
    func musicItemMenu(item: LibraryItem, playerCoordinator: PlayerCoordinator) -> some View {
        contextMenu {
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
    }
}
