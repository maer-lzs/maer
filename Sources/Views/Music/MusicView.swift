// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog
import Combine

/// Music tab (Subsonic/Navidrome/Jellyfin). Musik-Tab-Neuordnung (30.07):
/// playlist cards (shared card size) on top, then the grouped library list
/// (Artists · Albums · Songs · Playlists · Downloads. Apple-Music pattern;
/// the entries replace the old inline album grid), then two server shelves
/// (recently played / recently added). Playback runs through the shared player.
struct MusicView: View {
    @Environment(\.itemRouter) private var router
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
    /// Row flip re-renders the browse deck live.
    @AppStorage(AppStorageKeys.jamendoRowVisible) private var jamendoRowIsVisible = true
    /// Same store rows as Home. No second fetch.
    @ObservedObject private var freeCatalogStore = FreeCatalogStore.shared
    /// The old-records lane of the Browse row (`ShellacSection.rowTitles`).
    @State private var shellacTitles: [LibraryItem] = []

    /// The gate is ALREADY composed in `AppStorageKeys` (master > area toggle
    /// at the "Free Catalogs" area of the source map > archive.org service
    /// opt-out). These three used to re-compose it here and passed the
    /// finished answer as `feature:`. Harmless, because both sides are ANDed,
    /// but a second place that can drift, which is the exact defect the one
    /// accessor per source was built to end. They read it now.
    private var netlabelsArea: Bool { AppStorageKeys.netlabelsActive }
    private var jamendoArea: Bool { AppStorageKeys.jamendoActive }
    /// The one seam every listening row hangs on: a bump re-renders the
    /// tab, and the stock below is read again.
    @ObservedObject private var revision = ListeningRevision.shared
    /// The catalogue titles started as album TRACKS. The same stock
    /// Home's "Listen Again" reads (`positionless`), never a second source;
    /// here they stand in "Recently Played".
    private var catalogTracks: [ContinueSources.Extra] {
        _ = revision.value
        return ContinueSources.positionless(positions: ListeningStore.positions(),
                                            serverKnows: [],
                                            hiddenMarkers: ContinueHiddenStore.markers())
    }
    private var shellacArea: Bool { AppStorageKeys.shellacActive }

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
        // `bottomBarClearance()` must sit INSIDE the ScrollView (on
        // the content), like the podcast and audiobook tabs, so the scroll
        // stays full-bleed and the content scrolls UNDER the glass bar.
        ScrollView { content.bottomBarClearance() }
            // Choice family: the album sort is a user statement (equal-value
            // guard absorbs the adoption echo and the sibling surface).
            .onChange(of: musicSort) { _, new in
                UserChoiceCloudSync.shared.noteScalar(
                    key: AppStorageKeys.musicSortOption, value: new.rawValue)
            }
            // Bind the Music tab to the shared BottomBarState like
            // the other tabs. Without this its scroll never reported, so
            // the bar stayed expanded (heavy/opaque look) and never
            // collapsed. One binding, both symptoms.
            .reportsBottomBarScroll(active: isActive)
        .task {
            guard serverConfigured else { return }   // no source, no fetch
            vm.sort = musicSort   // honour the persisted sort on the first load
            await vm.loadIfNeeded()
        }
        .onChange(of: musicSort) { _, newSort in
            Task { await vm.setSort(newSort) }
        }
        // "Sync Now" (settings) refreshed only the provider cache. A
        // MOUNTED tab (tabs stay alive once visited) never re-read it. The
        // sync signal re-runs the EXISTING load path into this live model.
        .onMusicSourcesChange { Task { await vm.sourcesChanged() } }
        .onReceive(AppSession.shared.musicProvider.librarySynced) { _ in
            Task { await vm.reload() }
        }
        // Return promptly (stuck indicator otherwise) AND survive the
        // gesture's cancellation. The staged reload continues as a background
        // task and replaces content silently (stale beats empty).
        .refreshable {
            // Pull-to-refresh also pulls fresh artwork: a server-side re-tag
            // keeps the cover id (and thus the URL key) unchanged, so without
            // invalidation the cache would keep serving the old cover.
            for item in vm.albums + vm.newest + vm.frequent {
                if let url = router.coverURL(item.id) {
                    Artwork.invalidate(url)
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

    /// Is any music SERVER configured? The server section renders only
    /// when it has a source behind it. The tab is on by default, so a
    /// serverless user saw a sentence about "the connected music server"
    /// that had no referent, with a retry that could never succeed.
    private var serverConfigured: Bool { AppStorageKeys.musicServerActive }

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
            // The order of the tabs: the playlist cards on top
            // (shared card size), the notice when needed, what you heard,
            // the library deck, your newest, and the free catalogs as the
            // offer from outside. Empty shelves are omitted silently.
            playlistRow
            // Inline hint when a refresh failed but content is still shown.
            if serverConfigured, let error = vm.errorText {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            recentlyPlayedRow

            // The free-music row lives ONCE, further down next to the
            // other free areas. This spot used to carry a second one.

            // The server section decides for ITSELF. Never for the tab.
            // And only WITH a server behind it. A section without a source
            // is omitted, not rendered with an excuse.
            // Every state has a way out: loading spins, an error
            // names itself with retry, and an empty answer is a sentence with
            // retry instead of a dead end that survives until a hard restart.
            // Music is on (the switch travels between devices), the
            // server's access may not be: the shared body says so.
            if serverConfigured {
                MusicPageBody(state: .of(serverMissing: vm.serverMissingHere, asked: vm.hasAsked, isEmpty: vm.albums.isEmpty,
                                         isLoading: vm.isLoading, failure: vm.errorText),
                              emptyTitle: "No music on your server",
                              emptyDetail: "The connected music server reported an empty library.",
                              loadingHeight: 120,
                              retry: { Task { await vm.reload() } }) {
                    libraryList
                }
            }

            // Welle 3: shelves have their page now. Chevron per COUNTING
            // (the row source loads 20, shows 12; a 20-album library shows
            // no chevron on the page-sized cut, which is the rule working).
            if serverConfigured, !vm.newest.isEmpty { shelf("Recently Added", vm.newest, page: .shelfPage(.newest)) }
            // The offer from outside: with a server its rows fold into the
            // one Browse row under the library, without one they stand
            // under the own stock as the music sections of the Browse page.
            switch TabBrowse.form(hasServer: serverConfigured) {
            case .row: browseRow
            case .sections: catalogSections
            }
            // The songs heard on this device, as the last row of the tab
            // like in the podcast and audiobook tabs.
            ListeningHistoryRow(route: MusicRoute.history, accessibilityId: MusicRoute.history.accessibilityId)
        }
        .padding(.top, TabContentLayout.topInset)
    }

    /// The music lanes of the Browse page as one row. Same store rows as
    /// the sections; the old records come from the row's own query.
    @ViewBuilder
    private var browseRow: some View {
        let rows = freeCatalogStore.rows
        let tiles = BrowsePage.rowTiles(in: .music) { section in
            switch section {
            case .classical:
                AppStorageKeys.freeClassicalActive ? CatalogMix.ordered(rows.classical, for: .musicTab).map(BrowseTile.music) : []
            case .netlabels: netlabelsArea ? rows.netlabels.map(BrowseTile.music) : []
            case .oldRecords: shellacArea ? shellacTitles.map(BrowseTile.music) : []
            case .jamendo:
                jamendoArea && jamendoRowIsVisible
                    ? CatalogMix.ordered(rows.freeMusic, for: .musicTab).map(BrowseTile.music) : []
            default: []
            }
        }
        Group {
            if !tiles.isEmpty {
                BrowseRow(tiles: tiles, reason: { _ in "" }, playerCoordinator: playerCoordinator, area: .music)
            } else {
                // Something to hang the load on while every lane is empty.
                Color.clear.frame(height: 0)
            }
        }
        .task {
            guard shellacArea, shellacTitles.isEmpty, let titles = await ShellacSection.rowTitles() else { return }
            shellacTitles = titles
        }
    }

    /// The music sections of the Browse page, each with its tiles.
    @ViewBuilder
    private var catalogSections: some View {
        if netlabelsArea || shellacArea || (jamendoArea && jamendoRowIsVisible) {
            OpenCatalogsHeading()
        }
        // The free-music areas are REACHABLE from the music
        // tab again (tab parity). Same store rows as Home, no second
        // fetch. Future free sources join THIS block.
        if netlabelsArea, !freeCatalogStore.rows.netlabels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.entry("Netlabels", destination: MusicRoute.archiveMusic(ArchiveMusicCatalog.netlabels))
                    .catalogShuffle(area: ArchiveMusicCatalog.netlabels,
                                    coordinator: playerCoordinator)
                freeTileRow(freeCatalogStore.rows.netlabels)
            }
        }
        // An ordinary catalogue row like the two around it: heading with
        // a chevron, tiles below. The nine shelves stand on the surface
        // behind the chevron, under its own popular row.
        if shellacArea {
            ShellacSection(playerCoordinator: playerCoordinator)
        }
        // THE free-music row. The chevron goes
        // straight to the Jamendo page (path and target share the name),
        // it carries the shuffle, and it now asks the AREA switch as well.
        // That switch is a privacy switch: off means no Jamendo request,
        // so a row that ignored it kept fetching what the user had turned
        // off. Reading `rows` starts the load, so the row no longer
        // depends on a visit to Home; enabled-but-empty says why.
        if jamendoArea && jamendoRowIsVisible {
            let rows = freeCatalogStore.rows
            VStack(alignment: .leading, spacing: 8) {
                RowHeading.entry("Music (Jamendo)", destination: MusicRoute.freeJamendo)
                    .jamendoShuffle(coordinator: playerCoordinator)
                if !rows.freeMusic.isEmpty {
                    // Its own seed per surface: the same set, but not
                    // the same order as on the start surface, where
                    // classical mixes in while the full list stands
                    // here.
                    freeTileRow(CatalogMix.ordered(rows.freeMusic, for: .musicTab))
                } else if let problem = rows.freeMusicProblem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }
    }

    /// The library entries as the SAME deck of tiles the search page shows
    /// (decided product form), with a count where it is known cheaply. Always
    /// complete: an empty target shows its own empty state instead of
    /// hiding the entry. Counts: artists and albums from the loaded library
    /// (nil until loaded), playlists = server lists plus the lists on the
    /// devices, downloaded = the music items in the download stock; songs
    /// and genres carry none (the server names no total in one answer).
    private var libraryList: some View {
        MusicLibraryDeck(entries: libraryEntries(downloaded:))
    }

    private func libraryEntries(downloaded: Int) -> [CategoryDeckEntry] {
        let entries: [CategoryDeckEntry] = [
            deckEntry(String(localized: "Artists"), systemImage: "music.mic", count: vm.artists.isEmpty ? nil : vm.artists.count,
                      route: .artists(vm.artists)),
            deckEntry(String(localized: "Albums"), systemImage: "square.stack.fill", count: vm.albums.isEmpty ? nil : vm.albums.count,
                      route: .albums),
            deckEntry(String(localized: "Songs"), systemImage: "music.note", count: nil, route: .songs),
            deckEntry(String(localized: "Playlists"), systemImage: "music.note.list",
                      count: vm.playlists.count + maerPlaylists.playlists.count,
                      route: .playlists(sortedPlaylists)),
            deckEntry(String(localized: "Genres"), systemImage: "guitars", count: nil, route: .genres),
            deckEntry(String(localized: "Downloads list"), systemImage: "arrow.down.circle", count: downloaded, route: .downloaded),
        ]
        // No free shelf here: the deck is
        // the way into the OWN library, and one of ten Archive shelves sat
        // in it as a seventh entry. The shelves stay fully reachable through
        // the "Old Records" row above.
        return entries
    }

    private func deckEntry(_ title: String, systemImage: String, count: Int?,
                           route: MusicRoute) -> CategoryDeckEntry {
        CategoryDeckEntry(id: route.accessibilityId, title: title, systemImage: systemImage,
                          count: count, accessibilityId: route.accessibilityId) { pushRoute(route) }
    }

    /// Free-catalog tile row on the tab. NACHSCHLAGEN taps (detail
    /// sheet with attribution), same tiles as Home.
    private func freeTileRow(_ items: [LibraryItem]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(RowPreview.cut(items)) { item in
                    FreeCatalogBookTile(
                        item: item,
                        placeholderSystemImage: "music.note",
                        // Tab parity: the rows follow the same tap convention
                        // as the full pages. One track plays, several open the
                        // album page. They used to open a detail sheet instead.
                        onTap: {
                            Task {
                                await CatalogTap.open(item: item, coordinator: playerCoordinator,
                                                      pushMusicRoute: { pushRoute($0) })
                            }
                        })
                    .cardRowSlot(spacing: 14)
                    .contextMenu {
                        CollectionMenuItems.catalog(item, playerCoordinator: playerCoordinator)
                    }
                }
            }
            .padding(.horizontal)
        }
        .rowReachesUnderSideColumn()
    }

    /// ONE "Recently Played" row: the server's history and the
    /// catalogue titles started as album tracks, merged by time through the
    /// one rule. The catalogue titles are MUSIC and their home is this tab;
    /// they carry their moment (`positionless`, the stock Home reads). A
    /// server album carries the moment THIS device last heard it; one heard
    /// only elsewhere stays undated and keeps the server's order behind the
    /// dated ones. No stations: the radio has its own tab.
    private var recentlyPlayedEntries: [RecentlyPlayedRow.Entry] {
        let albums = serverConfigured ? vm.recent.map(\.id) : []
        let tracks = catalogTracks
        return RecentlyPlayedRow.merged(
            albums: albums,
            albumTimes: RecentlyPlayedRow.deviceTimes(albums, positions: ListeningStore.positions()),
            continued: [], stations: [], stationTimes: [:],
            catalog: tracks.map(\.id), catalogTimes: RecentlyPlayedRow.catalogTimes(tracks),
            limit: Int.max)
    }

    @ViewBuilder
    private var recentlyPlayedRow: some View {
        let entries = recentlyPlayedEntries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // The chevron opens the server's history, where there is
                // one; the catalogue titles have no page of their own.
                if serverConfigured, !vm.recent.isEmpty {
                    RowHeading(title: "Recently Played", total: entries.count,
                               shown: RowPreview.cut(entries).count,
                               destination: MusicRoute.shelfPage(.recent))
                } else {
                    RowHeading.plain("Recently Played")
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(RowPreview.cut(entries), id: \.self) { entry in
                            switch entry {
                            case .album(let id):
                                if let item = vm.recent.first(where: { $0.id == id }) {
                                    AlbumCell(item: item, width: 150, playerCoordinator: playerCoordinator)
                                }
                            case .catalogTrack(let id):
                                CatalogTrackCell(itemId: id, width: 150,
                                                 playerCoordinator: playerCoordinator)
                            case .station:
                                EmptyView()
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .rowReachesUnderSideColumn()
            }
        }
    }

    private func shelf(_ title: LocalizedStringKey, _ items: [LibraryItem],
                       page: MusicRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RowHeading(title: title, total: items.count,
                       shown: RowPreview.cut(items).count, destination: page)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    // Music shelves ran UNCAPPED. Every shelf built
                    // a cell per album of the library. A row is a preview.
                    ForEach(RowPreview.cut(items)) { item in
                        AlbumCell(item: item, width: 150, playerCoordinator: playerCoordinator)
                    }
                }
                .padding(.horizontal)
            }
        }
    }


    /// ONE row for both playlist worlds, newest change first. The server
    /// lists and the device lists share the card; the device lists carry
    /// the capsule "Mär" so one still knows what another client
    /// of the same server will see (server titles only) and what may mix
    /// everything. A second row per world was two rows for one question.
    private var playlistSources: [PlaylistCardSource] {
        let server = sortedPlaylists.map { PlaylistCardSource.server($0, sourceLabel: router.sourceLabel($0.itemId)) }
        let device = maerPlaylists.playlists.map { PlaylistCardSource.device($0, router: router) }
        return PlaylistPresentation.sortedByChanged(server + device) {
            $0.changedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
    }

    private var playlistRow: some View {
        // Device finding: CARDS, not tiles. The same
        // card format as the other libraries' card rows (featuredCardWidth,
        // text block on the card color), with the mosaic as the cover face.
        VStack(alignment: .leading, spacing: 8) {
            let sources = playlistSources
            if !sources.isEmpty {
                RowHeading.plain("Playlists")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(sources) { source in
                            // The card names ITSELF. A name set here
                            // landed on the container and swallowed the
                            // names of the buttons inside it.
                            PlaylistCard(source: source, playerCoordinator: playerCoordinator)
                        }
                        // The entry point ONCE, at the end of the one row; the
                        // dialog behind it asks where the list should live.
                        NewPlaylistCard { askToCreate(serverConfigured ? .server : .device) }
                    }
                    .padding(.horizontal)
                }
                .rowReachesUnderSideColumn()
            } else {
                // Nothing to show yet, in neither world: ONE compact entry
                // leads into the one dialog, which asks WHERE. A full-size
                // ghost card with nothing beside it was a card-sized hole
                // (measured on a device: the row was the card and a gap).
                RowHeading.plain("Playlists")
                Button {
                    askToCreate(serverConfigured ? .server : .device)
                } label: {
                    Label("New Playlist", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .accessibilityIdentifier("playlist-create-first")
            }
        }
    }

    /// The row card leads into the ONE create dialog. The row only
    /// preselects the place, the choice and its two explaining lines stay
    /// visible there.
    private func askToCreate(_ place: PlaylistPlace) {
        PlaylistPresenter.shared.askToCreate(place: place, host: playlistHost)
    }
}

/// A playlist as a vertical poster card. The 2×2 mosaic (coverOverride slot)
/// over the name and a metadata line "18 tracks · 1:12".
///
/// The card TAP PLAYS: that is the ONE card gesture. The detail page rides
/// the `CardDetailPill`, shuffle the corner badge.
/// The dashed "New Playlist" card at the end of the row → create flow.
private struct NewPlaylistCard: View {
    let onTap: () -> Void

    // The ghost card mirrors the playlist cards' EXACT
    // anatomy (square face + caption/title/sub reserves + pill reserve) so
    // the row has ONE height. Same scaled metrics as PlaylistCard.
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
            // The face is a STROKED outline. A stroke has no interior, so
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
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    var width: CGFloat? = nil
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Single-line titles truncate to fragments at accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The kind of this cell in a mixed row (`stackedKind`), nil elsewhere.
    @Environment(\.coverGlyphKind) private var kind
    /// The shorter side of the cover, measured; decides how many marks fit.
    @State private var coverSide: CGFloat?

    var body: some View {
        // Value-based push (MusicRoute) so the tab bar can switch library
        // from the album page. Plain destination links stayed on the stack.
        NavigationLink(value: MusicRoute.album(item)) {
            VStack(alignment: .leading, spacing: 6) {
                // The shared scope is the ONE observer of download/network
                // state for this cell. Only the cover re-renders on a tick.
                MediaAvailabilityScope(itemId: item.id) { unavailable in
                    CachedAsyncImage(
                        url: router.coverURL(item.id),
                        useThumbnail: true, thumbnailMaxPixel: 400
                    ) { image, pixels in
                        CoverFitting(image: image, pixelSize: pixels, backdrop: .neutral)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(unavailable ? 0.5 : 1)
                    .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) } action: { coverSide = $0 }
                    // Dimming alone never carries the state: the kind in a
                    // mixed row and not available offline stand in the one
                    // stack at the top right, the same corner as every tile.
                    .overlay(alignment: .topTrailing) {
                        StandardCoverMarks(kind: kind, availability: unavailable ? .offline : nil, coverSide: coverSide)
                    }
                    // With two music servers the cell says whose it is; with
                    // one, and for a catalogue title, nothing.
                    .overlay(alignment: .bottomLeading) {
                        if let source = router.sourceLabel(item.id) {
                            CoverCapsule(text: source)
                        }
                    }
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
        .musicItemMenu(item: item, playerCoordinator: playerCoordinator, isAlbum: true)
    }
}

/// The music library deck. Its one number from the download stock (the
/// "Downloads" tile, counted by the ONE rule shared with the search deck) is
/// why it observes the download manager, so a progress publish re-runs this
/// deck and not the whole music tab. The page builds the entries.
private struct MusicLibraryDeck: View {
    @ObservedObject private var downloadStock = DownloadManager.stock
    let entries: (_ downloaded: Int) -> [CategoryDeckEntry]

    var body: some View {
        CategoryDeckGrid(entries: entries(MediaFamily.musicCount(in: downloadStock.downloadedItemIds)))
    }
}

extension View {
    /// Context menu for a music album/song. Mirrors the podcast/book
    /// menus. Play + Play Next/Last (global Up-Next queue) +
    /// Add to Playlist + download/delete. An album (`isAlbum`) takes the
    /// collection entries (`CollectionMenuItems`).
    func musicItemMenu(item: LibraryItem, playerCoordinator: PlayerCoordinator,
                       isAlbum: Bool = false) -> some View {
        modifier(MusicItemMenu(item: item, playerCoordinator: playerCoordinator, isAlbum: isAlbum))
    }
}

/// THE long-press entries of an album or a playlist tile: Play, Play Next,
/// Play Last, Shuffle, Add to Playlist and Details, in this order wherever
/// such a tile stands (the album cell, the playlist card). The tile hands
/// in what each entry does in its world; the entries live here once.
struct CollectionMenuItems: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// The collection's id: the gate of the queue and playlist entries.
    let itemId: String
    /// Whether it can play now; adding and the details stay either way.
    var isPlayable = true
    let play: () async -> Void
    /// What the queue takes: an album as its one entry, a playlist as its
    /// songs.
    let queueIds: () async -> [String]
    /// The songs Shuffle draws from.
    let songs: () async -> ShufflePool
    /// The entries Add to Playlist adds; nil adds the collection itself
    /// under `knownTitles`.
    var addEntries: (() async -> (ids: [String], titles: [String: String]))? = nil
    var knownTitles: [String: String] = [:]
    /// A single song has nothing to shuffle.
    var offersShuffle = true
    /// Opens the collection's page, as its tile's tap does.
    var details: (@MainActor () -> Void)? = nil
    /// A catalogue title's id: Details is the one catalogue button
    /// (`CatalogDetailsButton`), which opens the title's page.
    var catalogDetails: String? = nil
    /// The global Up-Next queue both queue entries write to.
    private let queue = PlayQueue.shared

    var body: some View {
        if isPlayable {
            Button {
                Task { await play() }
            } label: { Label("Play", systemImage: "play.fill") }
            if PlayQueue.canEnqueue(itemId) {
                Button {
                    Task { for id in await queueIds().reversed() { queue.playNext(id) } }
                } label: { Label("Play Next", systemImage: "text.insert") }
                Button {
                    Task { for id in await queueIds() { queue.playLast(id) } }
                } label: { Label("Play Last", systemImage: "text.append") }
            }
            if offersShuffle {
                ShufflePlayButton(playerCoordinator: playerCoordinator, style: .menuItem, pool: songs)
            }
        }
        AddToPlaylistButton(itemId: itemId, knownTitles: knownTitles, resolve: addEntries)
        if let catalogDetails {
            CatalogDetailsButton(itemId: catalogDetails)
        } else if let details {
            Button {
                details()
            } label: { Label("Details", systemImage: "info.circle") }
        }
    }
}

extension CollectionMenuItems {
    /// The entries of a catalogue music tile: an archive album shuffles
    /// its songs, which its detail counts, or plays as its one title when
    /// no songs come, as a drawn title does (`CatalogShuffleSongs`);
    /// anything else (an archive track, a Jamendo title) offers no shuffle.
    /// The queue and the playlist take the title as its one entry, as for a
    /// server album; Details opens the title's page.
    static func catalog(_ item: LibraryItem, playerCoordinator: PlayerCoordinator,
                        albumSongs: @escaping CatalogShuffleSongs.AlbumSongs = {
                            await ArchiveMusicLoader.albumSongs(albumId: $0)
                        }) -> CollectionMenuItems {
        CollectionMenuItems(
            playerCoordinator: playerCoordinator, itemId: item.id,
            play: { await playerCoordinator.open(item: item) },
            queueIds: { [item.id] },
            songs: { .of(await CatalogShuffleSongs.songs(of: item, albumSongs: albumSongs)) },
            knownTitles: [item.id: item.title],
            offersShuffle: shuffles(catalog: item.id),
            catalogDetails: item.id)
    }

    /// Whether a catalogue title has songs to shuffle: an archive album.
    nonisolated static func shuffles(catalog id: String) -> Bool {
        id.hasPrefix(FreeCatalog.archivePrefix) && !CatalogSongID.isSong(id)
    }
}

/// The music item context menu as a modifier so it can own the add-to-playlist
/// sheet state (a `contextMenu` button can only flip a `@State`; the sheet is
/// attached to the view). One shared surface used by every music album/song cell.
private struct MusicItemMenu: ViewModifier {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let isAlbum: Bool
    private let downloads = DownloadManager.shared
    /// The global Up-Next queue both queue entries of a song write to.
    private let queue = PlayQueue.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @Environment(\.isOnline) private var isOnline
    @Environment(\.itemRouter) private var router
    @Environment(\.pushMusicRoute) private var pushRoute

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let isPlayable = MediaAvailability.canPlayNow(
                    isConnected: isOnline,
                    isDownloaded: downloads.isDownloaded(itemId: item.id))
                if isAlbum {
                    // An album is one multi-track item: the queue takes it
                    // as one entry that plays its songs as a group, Shuffle
                    // draws from its songs.
                    CollectionMenuItems(
                        playerCoordinator: playerCoordinator, itemId: item.id,
                        isPlayable: isPlayable,
                        play: { await playerCoordinator.open(item: item) },
                        queueIds: { [item.id] },
                        songs: { await CollectionSongs.serverPool(item.id) },
                        knownTitles: [item.id: item.title],
                        details: { pushRoute(.album(item)) })
                } else {
                    if isPlayable {
                        Button {
                            Task { await playerCoordinator.open(item: item) }
                        } label: { Label("Play", systemImage: "play.fill") }
                        // Global Up-Next queue (same actions as book/podcast).
                        Button {
                            queue.playNext(item.id)
                        } label: { Label("Play Next", systemImage: "text.insert") }
                        Button {
                            queue.playLast(item.id)
                        } label: { Label("Play Last", systemImage: "text.append") }
                    }
                    // ONE action, both worlds. The two targets used to sit here
                    // as two entries, and which one you got depended on the
                    // surface you long-pressed. The sheet states the choice
                    // instead, and leaves out what the entry cannot reach.
                    AddToPlaylistButton(itemId: item.id,
                                        knownTitles: [item.id: item.title])
                }
                // The "Listen Again" grip for a catalogue title: the marker
                // hides it until newer progress arrives, the position stays
                // (the same marker family the Continue cards use, travels).
                if ContinueSources.isLocallyTracked(item.id), ListeningStore.hasStand(item.id) {
                    Button(role: .destructive) {
                        ContinueHiddenStore.hide(
                            id: item.id,
                            lastUpdate: ProgressMark.timestamp(ListeningStore.backup(item.id)) ?? 0)
                    } label: { Label("Remove from Listen Again", systemImage: "minus.circle") }
                    .accessibilityIdentifier("remove-from-listen-again")
                }

                MusicDownloadMenuItems(itemId: item.id)
            }
    }
}

/// The download entries of a music long-press menu: delete when stored,
/// otherwise the offer while online and possible. One piece for the album
/// cells and the playlist cards. Its own observer, so a menu shows
/// the current state whenever it is built.
struct MusicDownloadMenuItems: View {
    let itemId: String
    private let downloads = DownloadManager.shared
    @ObservedObject private var downloadStock = DownloadManager.stock
    @Environment(\.isOnline) private var isOnline
    @Environment(\.itemRouter) private var router

    var body: some View {
        if downloads.isDeletableDownload(itemId: itemId) {
            Button(role: .destructive) {
                downloads.deleteDownload(itemId: itemId)
            } label: { Label("Delete Download", systemImage: "trash") }
        } else if isOnline,
                  MediaDownloadOffer.isPossible(router.provider(itemId).capabilities) {
            Button {
                Task { await downloads.startDownload(itemId: itemId, kind: .music) }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }
}

/// Music is on (the switch travels between devices), the server's access
/// does not: the one sentence for every music surface, with a way out that
/// asks again. The page also asks again by itself when the sources change.
struct MusicServerMissingHere: View {
    let retry: () -> Void

    var body: some View {
        EmptyStateView("No music server on this device", systemImage: "music.note",
                       description: Text("Music is on, but this device has no server address or account yet. Add them in Settings, behind the gear at the top.")) {
            RetryPill(action: retry)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("music-server-missing-here")
    }
}
