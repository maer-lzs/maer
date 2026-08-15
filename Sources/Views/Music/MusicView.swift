// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog
import Combine

/// Music tab (Subsonic/Navidrome/Jellyfin). Musik-Tab-Neuordnung (30.07):
/// playlist cards (shared card size) on top, then the grouped library list
/// (Artists · Albums · Songs · Playlists · Downloaded — Apple-Music pattern;
/// the entries replace the old inline album grid), then two server shelves
/// (recently played / recently added). Playback runs through the shared player.
struct MusicView: View {
    @Environment(\.pushMusicRoute) private var pushRoute
    @ObservedObject private var maerPlaylists = MaerPlaylists.shared
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

    /// F5: playlists newest-changed first (default sort).
    /// 5034add: master flip re-renders the browse deck live.
    @AppStorage(AppStorageKeys.freeCatalogsMasterEnabled) private var freeCatalogsMaster = true
    /// I1: same store rows as Home — no second fetch (Regel 2).
    @ObservedObject private var freeCatalogStore = FreeCatalogStore.shared
    @State private var freeDetailItem: LibraryItem?
    /// Which 78rpm shelf the row below the tiles shows. Never empty — the
    /// area exists only as named shelves.

    /// The selected shelf, falling back to the first one — a missing key must
    /// resolve to a shelf, never to the undivided collection.


    /// The gate is ALREADY composed in `AppStorageKeys` (master > area toggle
    /// at the "Free Catalogs" area of the source map > archive.org service
    /// opt-out). These three used to re-compose it here and passed the
    /// finished answer as `feature:` — harmless, because both sides are ANDed,
    /// but a second place that can drift, which is the exact defect the one
    /// accessor per source was built to end. They read it now.
    private var netlabelsArea: Bool { AppStorageKeys.netlabelsActive }
    private var shellacArea: Bool { AppStorageKeys.shellacActive }
    private var freeClassicalArea: Bool { AppStorageKeys.freeClassicalActive }

    private var sortedPlaylists: [MusicPlaylist] {
        PlaylistPresentation.sortedByChanged(vm.playlists) {
            $0.changedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    var body: some View {
        // The tab is no longer hostage to the server albums: the state used to
        // be decided for the WHOLE tab, so an unreachable or empty server hid
        // the catalogues and the playlists with it. The scroll always renders;
        // the SERVER section carries its own three states inside `content`.
        // S17b: `bottomBarClearance()` must sit INSIDE the ScrollView (on
        // the content) — like the podcast + audiobook tabs — so the scroll
        // stays full-bleed and the content scrolls UNDER the glass bar.
        ScrollView { content.bottomBarClearance() }
            // S17: bind the Music tab to the shared BottomBarState like
            // the other tabs — without this its scroll never reported, so
            // the bar stayed expanded (heavy/opaque look) and never
            // collapsed. One binding, both symptoms.
            .reportsBottomBarScroll(active: isActive)
            .sheet(item: $freeDetailItem) { item in
                FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
            }
        .task {
            guard serverConfigured else { return }   // no source, no fetch
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

    /// Is any music SERVER configured? G8: the server section renders only
    /// when it has a source behind it — the tab is on by default, so a
    /// serverless user saw a sentence about "the connected music server"
    /// that had no referent, with a retry that could never succeed.
    private var serverConfigured: Bool {
        AppStorageKeys.subsonicActive || AppStorageKeys.jellyfinActive
    }

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
            // Inline hint when a refresh failed but content is still shown.
            if serverConfigured, let error = vm.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            // Musik-Tab-Neuordnung (30.07): playlist cards on top (shared card
            // size), then the library LIST (Apple-Music pattern — the five
            // entries replace the old inline album grid/artists row), then the
            // two server shelves. Empty shelves are omitted silently.
            playlistRow

            // Serverless (13ccc6c): the free-music collection is the tab's
            // core — the entry leads to the ONE collection page (Jamendo,
            // records, netlabels), and the Jamendo row renders here directly.
            if !serverConfigured && freeCatalogsMaster {
                VStack(alignment: .leading, spacing: 10) {
                    RowHeading.entry("Free Music", destination: MusicRoute.freeCatalogArea)
                    if !freeCatalogStore.rows.freeMusic.isEmpty {
                        freeTileRow(freeCatalogStore.rows.freeMusic)
                    }
                }
            }

            // The server section decides for ITSELF — never for the tab.
            // And only WITH a server behind it — a section without a source
            // is omitted, not rendered with an excuse.
            // Every state has a way out (Regel 3): loading spins, an error
            // names itself with retry, and an empty answer is a sentence with
            // retry instead of a dead end that survives until a hard restart.
            if !serverConfigured {
                EmptyView()
            } else if vm.albums.isEmpty && vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if let error = vm.errorText, vm.albums.isEmpty {
                ContentUnavailableView {
                    Label("Music unavailable", systemImage: "music.note")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.reload() } }
                }
                .frame(maxWidth: .infinity)
            } else if vm.albums.isEmpty {
                ContentUnavailableView {
                    Label("No music on your server", systemImage: "music.note")
                } description: {
                    Text("The connected music server reported an empty library.")
                } actions: {
                    Button("Retry") { Task { await vm.reload() } }
                }
                .frame(maxWidth: .infinity)
            } else {
                libraryList
            }

            // Welle 3: shelves have their page now — chevron per COUNTING
            // (the row source loads 20, shows 12; a 20-album library shows
            // no chevron on the page-sized cut, which is the rule working).
            if serverConfigured, !vm.recent.isEmpty { shelf("Recently Played", vm.recent, page: .shelfPage(.recent)) }
            if serverConfigured, !vm.newest.isEmpty { shelf("Recently Added", vm.newest, page: .shelfPage(.newest)) }
            // 40f21b3 I1: the free-music areas are REACHABLE from the music
            // tab again (tab parity) — same store rows as Home, no second
            // fetch (Regel 2). I2: future free sources join THIS block.
            if netlabelsArea, !freeCatalogStore.rows.netlabels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        RowHeading.entry("Netlabels", destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.netlabels))
                            .catalogShuffle(area: ArchiveMusicCatalog.netlabels,
                                            coordinator: playerCoordinator)
                        freeTileRow(freeCatalogStore.rows.netlabels)
                    }
            }
            // Auflage 1 (08.08.): the 78s are reachable ONLY through
            // their genre shelves — the entry leads to the shelf list, never
            // to an undivided view of the collection.
            if shellacArea {
                // The shelf tiles SELECT; the row below shows titles of the
                // selected shelf. a738dc4/284095b: three levels, each with
                // its own target — the ROW head means the AREA (genre
                // overview), the capsules switch in place, and the shelf
                // LINE under them names the active shelf and leads counted
                // into its full page. There is deliberately no "all" state —
                // the safety of this area comes from its inclusion
                // criterion, so nothing may bypass a shelf.
                ShellacSection(playerCoordinator: playerCoordinator)
            }
            if freeCatalogsMaster, !freeCatalogStore.rows.freeMusic.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        RowHeading.entry("Free Music (Jamendo)", destination: MusicRoute.freeJamendo)
                            .jamendoShuffle(coordinator: playerCoordinator)
                        freeTileRow(freeCatalogStore.rows.freeMusic)
                    }
            }
        }
        .padding(.top, TabContentLayout.topInset)
    }

    /// The five library entries as one grouped vertical list. Always complete —
    /// an empty target shows its own empty state instead of hiding the entry.
    private var libraryList: some View {
        VStack(spacing: 0) {
            browseRow("Artists", systemImage: "music.mic", route: .artists(vm.artists))
            Divider().padding(.leading, 52)
            browseRow("Albums", systemImage: "square.stack", route: .albums)
            Divider().padding(.leading, 52)
            browseRow("Songs", systemImage: "music.note", route: .songs)
            Divider().padding(.leading, 52)
            browseRow("Playlists", systemImage: "music.note.list", route: .playlists(sortedPlaylists))
            Divider().padding(.leading, 52)
            // M3: sixth entry — the genre chip grid.
            browseRow("Genres", systemImage: "guitars", route: .genres)
            Divider().padding(.leading, 52)
            // UMZUG (klassik-in-die-suche): the Free-Classical entry moved to
            // the music SEARCH deck — the browse list stays the personal
            // library (Katalog-Einstiege wohnen im Entdecken-Kontext); the
            // Home teaser and both gates are untouched.
            browseRow("Downloaded", systemImage: "arrow.down.circle", route: .downloaded)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    /// I1: free-catalog tile row on the tab — NACHSCHLAGEN taps (detail
    /// sheet with attribution), same tiles as Home.
    private func freeTileRow(_ items: [LibraryItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        // Tab parity: the rows follow the same tap convention
                        // as the full pages — one track plays, several open the
                        // album page. They used to open a detail sheet instead.
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: { pushRoute($0) })
                            }
                        })
                    .containerRelativeFrame(.horizontal,
                                            count: CardMetrics.recommendationColumns(regularWidth: false),
                                            spacing: 14)
                    .contextMenu {
                        Button {
                            Task { await playerCoordinator.open(item: item) }
                        } label: { Label("Play", systemImage: "play.fill") }
                    }
                }
            }
            .padding(.horizontal)
        }
        .scrollClipDisabled()
    }

    private func shelf(_ title: LocalizedStringKey, _ items: [LibraryItem],
                       page: MusicRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeading(title: title, total: items.count,
                       shown: RowPreview.cut(items).count, destination: page)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    // 6fcb301: music shelves ran UNCAPPED — every shelf built
                    // a cell per album of the library. A row is a preview.
                    ForEach(RowPreview.cut(items)) { item in
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


    private var playlistRow: some View {
        // Device finding: CARDS, not tiles — the same
        // card format as the other libraries' card rows (featuredCardWidth,
        // text block on the card color), with the mosaic as the cover face.
        VStack(alignment: .leading, spacing: 8) {
            // Paket 1: ZWEI Playlist-Typen, sichtbar unterschieden — ein
            // Nutzer muss wissen, was ein anderer Client sehen wird. Die
            // Server-Listen synchronisieren ueberallhin und tragen nur
            // Server-Titel; die Maer-Listen leben auf den Geraeten und duerfen
            // alles mischen. Die Unterscheidung ist Pflicht, die Wortwahl
            // unsere.
            if !sortedPlaylists.isEmpty {
                RowHeading.plain("Playlists · On your server")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(sortedPlaylists) {
                            PlaylistCard(playlist: $0, playerCoordinator: playerCoordinator)
                        }
                        NewPlaylistCard { showNewPlaylist = true }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            } else {
                RowHeading.plain("Playlists")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        NewPlaylistCard { showNewPlaylist = true }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
            maerPlaylistRow
        }
    }

    /// Paket 1: die Maer-Listen — quellenuebergreifend, auf den Geraeten.
    @ViewBuilder
    private var maerPlaylistRow: some View {
        let lists = maerPlaylists.playlists
        if !lists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.plain("Playlists · On your devices")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(lists) { list in
                            Button {
                                pushRoute(.maerPlaylist(list.id))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Image(systemName: "music.note.list")
                                        .font(.title2)
                                        .foregroundStyle(AppTheme.accent)
                                    Text(verbatim: list.name)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    Text("\(list.itemIds.count) entries")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 150, alignment: .leading)
                                .padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("maer-playlist-\(list.id)")
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// F5: a playlist as a vertical poster card — the 2×2 mosaic (Y58 coverOverride
/// slot) over the name and a metadata line "18 tracks · 1:12".
///
/// 8203d12: the doc comment claimed the OPPOSITE of what the code does — it
/// still carried the original F5 specification ("tap opens the detail page,
/// no direct playback"), while `1b16f2c` had already switched the card to
/// tap-to-play, which is the ONE
/// card gesture; the detail page rides the `CardDetailPill`, shuffle the
/// corner badge. Corrected here so the doc stops cementing a dead spec.
private struct PlaylistCard: View {
    let playlist: MusicPlaylist
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @Environment(\.pushMusicRoute) private var pushRoute
    @State private var coverURLs: [URL] = []
    /// 961a14e: the playlist's most frequent artists as ONE truncating line
    /// (empty = no data → blank, height reserved so the card never jiggles).
    @State private var artistNames: [String] = []
    /// b9898dd Fix 1: the mixed card color comes from the BOTTOM (big) mosaic
    /// cover — it borders the text block (color continuity). Cached per URL in
    /// CoverColorLoader; until extraction lands the deterministic tint shows,
    /// then ONE soft transition (no reload flicker).
    @StateObject private var colorLoader = CoverColorLoader()
    // b9898dd Fix 2: EXACT height parity with the Featured-card anatomy —
    // the same scaled line reserves and pill reserve as PodcastFeaturedCard.
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var metaMinHeight: CGFloat = 20

    /// Deterministic per-id tint as the instant fallback; the extracted
    /// bottom-cover color takes over once loaded.
    private var tint: Color {
        colorLoader.hasAccent
            ? colorLoader.accent
            : PlaylistArtwork.color(for: AppSession.shared.musicProvider.itemId(playlistId: playlist.id))
    }

    var body: some View {
        // Korrektur 01.08: the SAME card format as BookFeaturedCard /
        // PodcastFeaturedCard (featuredCardWidth, cover face on top, text
        // block on the card color below, radius 20) — mosaic as the cover.
        // 1b16f2c: the card TAP PLAYS the playlist in normal order (pill
        // left = detail, corner right = shuffle) — same tap-to-play the
        // Book/Podcast Featured cards use, so no deviation remains.
        Button {
            Task { await playerCoordinator.open(item: playlistLibraryItem(playlist)) }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                PlaylistArtwork(
                    playlistID: AppSession.shared.musicProvider.itemId(playlistId: playlist.id),
                    coverURLs: coverURLs, cornerRadius: 0)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, tint],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: CardMetrics.featuredCardWidth * 0.3)
                    }
                // b9898dd Fix 2: the PodcastFeaturedCard text-block anatomy —
                // caption line · headline with a 2-line reserve · sub line ·
                // pill reserve — so every card row across the tabs has the
                // SAME card height.
                VStack(alignment: .leading, spacing: 5) {
                    Text(changedText ?? " ")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(playlist.name ?? String(localized: "Playlist"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: titleMinHeight, alignment: .topLeading)
                    Text(metaLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: metaMinHeight, alignment: .topLeading)
                    // 961a14e: 2–3 most frequent artists, ONE line, native
                    // truncation — style of the Discover reason lines
                    // (secondary/small); blank keeps the reserve (jank rule).
                    Text(artistNames.isEmpty ? " " : artistNames.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(14)
                .padding(.bottom, pillReserve)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: CardMetrics.featuredCardWidth)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // ONE soft transition from the deterministic tint to the extracted
        // bottom-cover color (and none afterwards — the color is cached).
        .animation(.easeInOut(duration: 0.45), value: colorLoader.hasAccent)
        // 5219ea7: the SAME two card controls as the Featured cards, at the
        // SAME positions — Details pill bottom-left, corner button bottom-right
        // (shuffle instead of download; playlists only, albums untouched).
        .overlay(alignment: .bottomLeading) {
            CardDetailPill(value: MusicRoute.album(playlistLibraryItem(playlist)))
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            CardCornerButton(systemImage: "shuffle",
                             accessibilityLabel: Text("Shuffle"),
                             accessibilityId: "playlist-shuffle-badge") {
                Task {
                    let items = await shufflePool()
                    await playerCoordinator.shufflePlay(items: items)
                }
            }
            .padding(12)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // b9898dd Fix 1: extract the card color from the bottom (big) mosaic
        // cover — coverURLs[0] is the big bottom slot of PlaylistArtwork.
        .task(id: coverURLs.first) { await colorLoader.load(from: coverURLs.first) }
        // Playlist basics: rename/delete from the card row too; b9898dd Fix 3:
        // the shuffle action ALSO lives here (consistency slot).
        .contextMenu {
            ShufflePlayButton(playerCoordinator: playerCoordinator,
                              style: .menuItem, pool: shufflePool)
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
            let itemId = music.itemId(playlistId: playlist.id)
            let ids = await music.playlistMosaicCoverIDs(forItemId: itemId)
            coverURLs = ids.compactMap { music.coverURL(coverArtId: $0) }
            // 961a14e: same fetch family (cached with the mosaic), pure ranking.
            artistNames = PlaylistPresentation.topArtists(
                await music.playlistArtistNames(forItemId: itemId))
        }
    }

    /// The playlist's songs as the shuffle pool (shared shufflePlay path).
    private func shufflePool() async -> [LibraryItem] {
        await AppSession.shared.musicProvider
            .songItems(forItemId: AppSession.shared.musicProvider.itemId(playlistId: playlist.id))
    }

    /// Caption line: when the playlist last changed (the row sorts by this) —
    /// same time-info slot as the other Featured cards' caption.
    private var changedText: String? {
        guard let ts = playlist.changedAt else { return nil }
        return Date(timeIntervalSince1970: ts / 1000).formatted(.relative(presentation: .named))
    }

    private var metaLine: String {
        let count = playlist.songCount ?? 0
        let duration = PlaylistPresentation.durationText(seconds: Int(playlist.duration ?? 0))
        // 24a220e: "tracks" (klein) ist KEINE Casing-Dublette zu "Tracks" —
        // dieses hier steht MITTEN im Satz ("18 tracks · 1:12"), jenes ist
        // der Sheet-Titel. Zusammenziehen wuerde im Englischen sichtbar
        // falsch grossschreiben; die beiden Keys bleiben getrennt.
        return "\(count) \(String(localized: "tracks")) · \(duration)"
    }
}

/// F5: the dashed "New Playlist" card at the end of the row → create flow.
private struct NewPlaylistCard: View {
    let onTap: () -> Void

    // b9898dd Fix 2: the ghost card mirrors the playlist cards' EXACT
    // anatomy (square face + caption/title/sub reserves + pill reserve) so
    // the row has ONE height — same scaled metrics as PlaylistCard.
    @ScaledMetric(relativeTo: .subheadline) private var pillReserve: CGFloat = 40
    @ScaledMetric(relativeTo: .headline) private var titleMinHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .subheadline) private var metaMinHeight: CGFloat = 20

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(.secondary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(Image(systemName: "plus").font(.title).foregroundStyle(.secondary))
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: " ").font(.caption).lineLimit(1)
                    Text("New Playlist")
                        .font(.headline)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: titleMinHeight, alignment: .topLeading)
                    Text(verbatim: " ").font(.subheadline).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: metaMinHeight, alignment: .topLeading)
                    Text(verbatim: " ").font(.caption2).lineLimit(1)
                }
                .padding(14)
                .padding(.bottom, pillReserve)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: CardMetrics.featuredCardWidth)
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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

                // Paket 1: ZWEI Ziele, sichtbar getrennt. Die Server-Liste
                // gibt es nur fuer Titel, die dem Server gehoeren — das Gate
                // bleibt, es ist keine Willkuer, sondern die Natur der Sache
                // (Navidrome kann keine Katalog-Adresse referenzieren). Die
                // Maer-Liste gibt es fuer alles, was auch in die Warteschlange
                // darf. Nichts scheitert still: wo das eine fehlt, steht das
                // andere mit Grund.
                if AppSession.shared.musicProvider.owns(itemId: item.id) {
                    Button {
                        addTarget = AddToPlaylistTarget(itemId: item.id)
                    } label: { Label("Add to Server Playlist", systemImage: "text.badge.plus") }
                }
                MaerPlaylistMenu(itemId: item.id,
                                 knownTitles: [item.id: item.title])

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
