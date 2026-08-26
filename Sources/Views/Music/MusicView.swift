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
    /// Which presentation hierarchy the row cards ask (root, here).
    @Environment(\.playlistHost) private var playlistHost

    /// Playlists newest-changed first (default sort).
    /// Master flip re-renders the browse deck live.
    @AppStorage(AppStorageKeys.freeCatalogsMasterEnabled) private var freeCatalogsMaster = true
    /// Same store rows as Home — no second fetch.
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
    private var jamendoArea: Bool { AppStorageKeys.jamendoActive }
    /// The catalogue titles started as album TRACKS — the same stock
    /// Home's "Listen Again" reads (`positionless`), never a second source.
    private var catalogTracks: [ContinueSources.Extra] {
        ContinueSources.positionless(in: UserDefaults.standard.dictionaryRepresentation(),
                                     serverKnows: [])
    }
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
            // Choice family: the album sort is a user statement (equal-value
            // guard absorbs the adoption echo and the sibling surface).
            .onChange(of: musicSort) { _, new in
                UserChoiceCloudSync.shared.noteScalar(
                    key: AppStorageKeys.musicSortOption, value: new.rawValue)
            }
            // Bind the Music tab to the shared BottomBarState like
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
        // "Sync Now" (settings) refreshed only the provider cache — a
        // MOUNTED tab (tabs stay alive once visited) never re-read it. The
        // sync signal re-runs the EXISTING load path into this live model.
        .onReceive(AppSession.shared.musicProvider.librarySynced) { _ in
            Task { await vm.reload() }
        }
        // Return promptly (stuck indicator otherwise) AND survive the
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

    /// Is any music SERVER configured? G8: the server section renders only
    /// when it has a source behind it — the tab is on by default, so a
    /// serverless user saw a sentence about "the connected music server"
    /// that had no referent, with a retry that could never succeed.
    private var serverConfigured: Bool { AppStorageKeys.musicServerActive }

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

            // The free-music row lives ONCE, further down next to the
            // other free areas — this spot used to carry a second one.

            // The server section decides for ITSELF — never for the tab.
            // And only WITH a server behind it — a section without a source
            // is omitted, not rendered with an excuse.
            // Every state has a way out: loading spins, an error
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
            // Catalogue titles started as album tracks are MUSIC — their
            // home is this tab, not only Home. The server shelf above cannot
            // carry them (it is fed by the server's history), and without a
            // music server it does not exist at all; this row is independent
            // of a server by construction. Same cell as Home, same
            // stock (`positionless`) — no second home, no second form.
            if !catalogTracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    RowHeading.plain("Listen Again")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(catalogTracks.prefix(RowPreview.limit), id: \.id) { extra in
                                CatalogTrackCell(itemId: extra.id, width: 128,
                                                 playerCoordinator: playerCoordinator)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .scrollClipDisabled()
                }
            }
            if serverConfigured, !vm.newest.isEmpty { shelf("Recently Added", vm.newest, page: .shelfPage(.newest)) }
            // The free-music areas are REACHABLE from the music
            // tab again (tab parity) — same store rows as Home, no second
            // fetch. I2: future free sources join THIS block.
            if netlabelsArea, !freeCatalogStore.rows.netlabels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        RowHeading.entry("Netlabels", destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.netlabels))
                            .catalogShuffle(area: ArchiveMusicCatalog.netlabels,
                                            coordinator: playerCoordinator)
                        freeTileRow(freeCatalogStore.rows.netlabels)
                    }
            }
            // The 78s are reachable ONLY through
            // their genre shelves — the entry leads to the shelf list, never
            // to an undivided view of the collection.
            if shellacArea {
                // The shelf tiles SELECT; the row below shows titles of the
                // selected shelf. Three levels, each with its own target —
                // the ROW head means the AREA (genre
                // overview), the capsules switch in place, and the shelf
                // LINE under them names the active shelf and leads counted
                // into its full page. There is deliberately no "all" state —
                // the safety of this area comes from its inclusion
                // criterion, so nothing may bypass a shelf.
                ShellacSection(playerCoordinator: playerCoordinator)
            }
            // THE free-music row — the chevron goes
            // straight to the Jamendo page (path and target share the name),
            // it carries the shuffle, and it now asks the AREA switch as well.
            // That switch is a privacy switch: off means no Jamendo request,
            // so a row that ignored it kept fetching what the user had turned
            // off. Reading `rows` starts the load, so the row no longer
            // depends on a visit to Home; enabled-but-empty says why.
            if jamendoArea && freeCatalogsMaster {
                let rows = freeCatalogStore.rows
                VStack(alignment: .leading, spacing: 8) {
                    RowHeading.entry("Free Music (Jamendo)", destination: MusicRoute.freeJamendo)
                        .jamendoShuffle(coordinator: playerCoordinator)
                    if !rows.freeMusic.isEmpty {
                        // Eigener Startwert je Flaeche —
                        // dieselbe Menge, aber nicht dieselbe Reihe wie auf
                        // Start (dort mischt sich Klassik dazwischen, hier
                        // steht die volle Liste).
                        freeTileRow(CatalogMix.ordered(rows.freeMusic, for: .musicTab))
                    } else if let problem = rows.freeMusicProblem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
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
            // Sixth entry — the genre chip grid.
            browseRow("Genres", systemImage: "guitars", route: .genres)
            Divider().padding(.leading, 52)
            // UMZUG (klassik-in-die-suche): the Free-Classical entry moved to
            // the music SEARCH deck — the browse list stays the personal
            // library (catalogue entries live in the discover context); the
            // Home teaser and both gates are untouched.
            browseRow("Downloaded", systemImage: "arrow.down.circle", route: .downloaded)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    /// Free-catalog tile row on the tab — NACHSCHLAGEN taps (detail
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
                    .cardRowSlot(spacing: 14)
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
                    // Music shelves ran UNCAPPED — every shelf built
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
        // Value-based push so a media-tab tap (which empties navigationPath)
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
            // TWO playlist kinds, visibly told apart — one has to know what
            // another client of the same server will see. The server lists
            // sync everywhere and carry server titles only; the device lists
            // live on the devices and may mix everything. The distinction is
            // mandatory, the wording is ours.
            if !sortedPlaylists.isEmpty {
                RowHeading.plain("Playlists · On your server")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(sortedPlaylists) {
                            PlaylistCard(source: .server($0), playerCoordinator: playerCoordinator)
                        }
                        NewPlaylistCard { askToCreate(.server) }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            } else {
                RowHeading.plain("Playlists")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        // Nothing to show yet: the ONE card leads into the one
                        // dialog, which asks WHERE — with no server behind it
                        // there is nothing to ask and it says so instead (G8).
                        NewPlaylistCard { askToCreate(serverConfigured ? .server : .device) }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
            maerPlaylistRow
        }
    }

    /// BOTH row cards lead into the ONE create dialog — the row they
    /// sit in only preselects the place, the choice and its two explaining
    /// lines stay visible there.
    private func askToCreate(_ place: PlaylistPlace) {
        PlaylistPresenter.shared.askToCreate(place: place, host: playlistHost)
    }

    /// The device lists — across sources, living on the devices.
    @ViewBuilder
    private var maerPlaylistRow: some View {
        let lists = maerPlaylists.playlists
        if !lists.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.plain("Playlists · On your devices")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        // The device lists render as THE
                        // shared card — mosaic, artist line, colour derivation
                        // and the height parity with the featured cards. The
                        // small box they used to get was the second version
                        // this row was never supposed to have.
                        ForEach(lists) { list in
                            PlaylistCard(source: .device(list), playerCoordinator: playerCoordinator)
                                .accessibilityIdentifier("maer-playlist-\(list.id)")
                        }
                        // The entry point sits WHERE one looks
                        // for it — at the playlist row itself. It existed for
                        // server playlists but not here, so device lists could
                        // only be created from a context menu somewhere else.
                        NewPlaylistCard { askToCreate(.device) }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }
}

/// A playlist as a vertical poster card — the 2×2 mosaic (coverOverride slot)
/// over the name and a metadata line "18 tracks · 1:12".
///
/// The card TAP PLAYS: that is the ONE card gesture. The detail page rides
/// the `CardDetailPill`, shuffle the corner badge.
/// The dashed "New Playlist" card at the end of the row → create flow.
private struct NewPlaylistCard: View {
    let onTap: () -> Void

    // The ghost card mirrors the playlist cards' EXACT
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
            // The face is a STROKED outline — a stroke has no interior, so
            // without this the middle of the card is not hit-testable and the
            // tap lands nowhere. Measured: the card looked and read like a
            // button and answered only on the dashed line and on its label.
            // The real cards carry the same shape for the same reason.
            .contentShape(Rectangle())
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
    /// Single-line titles truncate to fragments at accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Value-based push (MusicRoute) so the tab bar can switch library
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
                    // Dimming alone never carries the state.
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
    /// Context menu for a music album/song — mirrors the podcast/book
    /// menus. Play + Play Next/Last (global Up-Next queue) +
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

                // ONE action, both worlds. The two targets used to sit here
                // as two entries, and which one you got depended on the
                // surface you long-pressed — the sheet states the choice
                // instead, and leaves out what the entry cannot reach.
                AddToPlaylistButton(itemId: item.id,
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
    }
}
