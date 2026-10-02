// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// Home = cross-section aggregation tab. It is NOT a library. The media tabs
/// stay full libraries. Reuses ONLY existing components (PlayQueueRow,
/// AlbumCell) and ranks STRICTLY by timestamp via HomeSections. Sections are
/// computed from a snapshot in a `.task` (staged),
/// never in the body.
struct HomeView: View {
    @Environment(\.itemRouter) private var router
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var isActive: Bool = true
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject private var queue = PlayQueue.shared

    /// Recency-ordered ids of in-progress books + episodes. Resolved to the
    /// matching FeaturedCard (book vs podcast) in the view. The same cards
    /// as the library tabs, no Home-specific component.
    @State private var continueIds: [String] = []
    /// The row is a preview. Its PAGE needs the uncapped stock. Kept
    /// beside the row's list (not derived from it) because the row's own cap is
    /// a curation (max 2 music cards), which a full list must not inherit.
    @State private var continueIdsAll: [String] = []
    @State private var recentlyAddedAll: [LibraryItem] = []
    /// Progress per in-progress music playlist (id → progress), so a
    /// playlist continue card can show its bar and resume at the right spot.
    /// Store-backed (LateMusicValues): a late result publishes here instead
    /// of expiring; the view only reads.
    private var musicContinueProgress: [String: BookProgress] { lateMusic.progress }
    /// "Latest Episodes": newest episode of each recently-active show, shown
    /// as episode tiles in a 2-row adaptive grid.
    @State private var recentEpisodeItems: [LibraryItem] = []
    /// Radio on Home: recently played stations (RadioStore recents, loaded in
    /// the same compute pass as the other sections. No extra observer).
    @State private var radioRecents: [RadioStation] = []
    /// "Rediscover": daily-rotated local picks (paused / unheard / next
    /// volume). Empty hides the section.
    @State private var rediscoverPicks: [RediscoverSections.Pick] = []
    /// The full pool behind the daily row (page + counted chevron).
    @State private var rediscoverPool = RediscoverSections.Pool()
    /// ONE opt-out for both recommendation sections (Rediscover +
    /// Discover); the library-fact sections stay untouched.
    @AppStorage(AppStorageKeys.homeRecommendations) private var recommendationsEnabled = true
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @ObservedObject private var subs = PodcastSubscriptions.shared
    /// The one seam every listening row hangs on (see `ListeningRevision`).
    @ObservedObject private var revision = ListeningRevision.shared
    // The Home page does not observe DownloadManager/NetworkMonitor: a
    // download-progress tick would re-render the whole page and every
    // section, so each tile's availability lives in its own MediaAvailabilityScope.
    @Environment(\.pushPodcastRoute) private var pushRoute
    @Environment(\.pushBookDetail) private var pushBook
    /// "Recently Added": newly added books + albums, mixed by added time.
    /// Each rendered with its own tab's tile (BookGridCell / AlbumCell).
    @State private var recentlyAddedItems: [LibraryItem] = []
    /// Free-catalog row data. Loaded once per session in
    /// compute() (retry rides the recompute token like everything else).
    /// Shared store. The audiobooks tab row reads the same fill.
    @ObservedObject private var freeCatalogStore = FreeCatalogStore.shared
    /// Book detail via the ONE route (the mini sheet fell).
    @Environment(\.pushFreeAudiobooksRoute) private var pushFreeAudiobooksRoute
    @Environment(\.isOnline) private var isOnline
    @ObservedObject private var lateMusic = LateMusicValues.shared
    /// Row flips hide the Home surfaces live (loaded rows stay
    /// in the store; the render gate wins). Each row asks ITS switch.
    @AppStorage(AppStorageKeys.rowHomeDiscoverMusicVisible) private var discoverMusicRowVisible = true
    @AppStorage(AppStorageKeys.freeAudiobooksEnabled) private var discoverBooksRowVisible = true
    @AppStorage(AppStorageKeys.rowHomeRecentlyAddedVisible) private var recentlyAddedRowVisible = true

    /// Recently PLAYED music albums ("Zuletzt gehört (Musik)"). The
    /// provider's `.recent` shelf; empty (no music server / nothing played)
    /// hides the section.
    private var recentMusicItems: [LibraryItem] { lateMusic.recentAlbums }
    /// The Discover row's subscribed-Set + excluding-subscribed filter,
    /// computed off the body (only when subscriptions/recommendations change)
    /// instead of on every render.
    @State private var discoverShown: [PodcastSearchResult] = []
    @State private var ready = false
    /// Explicit height for the lazy "Recently Added" cells. The fixed
    /// 150 cover plus a Dynamic-Type-scaling text block, so every cell matches
    /// and none clips. (Device candidate: the text allowance.)
    @ScaledMetric(relativeTo: .caption) private var recentlyAddedTextHeight: CGFloat = 70
    private var recentlyAddedCellHeight: CGFloat { 150 + recentlyAddedTextHeight }

    /// Recompute the Discover row only when its inputs change.
    private var discoverToken: String {
        // The store's CONTENT version instead of the count, as on the podcast
        // tab: a same-size replacement would leave the Discover row stale.
        // The sibling inputs use content identity too, so a swapped
        // subscription at equal count still recomputes (ContentToken).
        //
        // SORTED set, not the list in show order: the token asks WHICH feeds
        // are subscribed, and a source that hands its shows back in a
        // different order used to change the token and force a pointless
        // recompute. A swap still changes the set, so the assurance above
        // holds. The sort is not decoration: a Set has no stable order, and
        // an unsorted one would make the token differ from itself.
        let feeds = ContentToken.of(PodcastShowMerge.normalizedFeeds(PodcastShowSources.ownedShows()).sorted())
        return "\(recommendationsEnabled)-\(recommendations.contentVersion)-\(feeds)"
    }

    private func recomputeDiscover() {
        guard recommendationsEnabled else { discoverShown = []; return }
        let subscribed = PodcastShowMerge.normalizedFeeds(PodcastShowSources.ownedShows())
        let fresh = PodcastRecommendationsStore.excludingSubscribed(
            recommendations.results, subscribedNormalizedFeeds: subscribed)
        // Layout-shift: the whole-section insert (2nd from top) routes through
        // the calm gate. Empty→filled IS the shift, so no immediate path here.
        ScrollCalm.run { discoverShown = fresh }
    }

    /// Hiding a MUSIC or EPISODE entry changes none of the counts
    /// below (they are book lists), so the token needs its own signal. Without
    /// it the card stayed on screen until the next unrelated recompute.
    @State private var hiddenRevision = 0
    /// Up-Next heading opens the queue sheet (RowHeading.action).
    @State private var showQueueSheet = false

    /// Content identity, never counts (`HomeRecomputeToken`): a subscription
    /// that arrives changes the episode rows, and the listening revision
    /// carries every store event.
    private var recomputeToken: String {
        HomeRecomputeToken.make(
            isActive: isActive,
            entryIds: libraryViewModel.entries.map(\.id),
            continueEntries: libraryViewModel.continueListening.map { ($0.id, $0.progress?.lastUpdate ?? 0) },
            recentlyAddedIds: libraryViewModel.recentlyAdded.map(\.id),
            queueIds: queue.ids,
            recommendationsEnabled: recommendationsEnabled,
            hiddenRevision: hiddenRevision,
            showFeeds: subs.shows.map(\.feedURL),
            revision: revision.value)
    }

    var body: some View {
        ScrollView {
            if ready {
                // Continue → Up Next → Recently Played → Discover →
                // Latest Episodes → Rediscover → Recently Added.
                LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    continueSection
                    // The user's own PLAN directly under the continue
                    // cards: own holdings before any shop window, the
                    // same line the whole start surface follows. The
                    // orders are the evening plan, and a plan below the
                    // fold was a plan nobody saw.
                    upNextSection
                    // The HEARING BLOCK. First what has a position, directly
                    // below what you start over. Discover/recommendation rows follow.
                    recentlyPlayedSection
                    if recommendationsEnabled { discoverSection }
                    // Free-catalog rows. Data loads in
                    // compute() (a lazy below-the-fold view never ran its
                    // own task reliably), rows render dumb.
                    if discoverMusicRowVisible {
                        // "Entdecken · Musik": one mixed row with an entry page.
                        FreeCatalogRows(playerCoordinator: playerCoordinator,
                                        freeMusic: freeCatalogStore.rows.freeMusic,
                                        classical: freeCatalogStore.rows.classical,
                                        freeMusicProblem: freeCatalogStore.rows.freeMusicProblem)
                    }
                    if discoverBooksRowVisible {
                        // The discover row for audiobooks and radio plays:
                        // the SAME mixed row and computation as the podcast
                        // tab, with an entry chevron onto the existing area
                        // page, built like the music row above.
                        discoverAudiobooksSection
                    }
                    latestEpisodesSection
                    if recommendationsEnabled { rediscoverSection }
                    if recentlyAddedRowVisible { recentlyAddedSection }
                    if isEmpty { emptyState }
                }
                .padding(.top, TabContentLayout.topInset)
                .bottomBarClearance()
                .transition(.opacity)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        // Home hangs on the SHARED bottom bar like every tab. Only the visible
        // one reports (active-gate). Transition/feedback edge untouched.
        .reportsBottomBarScroll(active: isActive)
        .onReceive(NotificationCenter.default.publisher(for: .continueHiddenChanged)) { _ in
            hiddenRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .coListenedChanged)) { _ in
            hiddenRevision += 1
        }
        // A finished episode leaves the mounted Continue row WITHOUT a
        // tab switch. The progress store bumps only on deliberate changes
        // (finish, mark, cloud adoption), never per playback tick.
        .onReceive(PodcastProgressStore.shared.objectWillChange
            .receive(on: RunLoop.main)) { _ in
            hiddenRevision += 1
        }
        // A Home row's page. Registered HERE, not on the stack root,
        // because the page needs Home's own state (the music progress map is
        // fetched in compute(). The root has no access to it and re-fetching
        // for a push would hit the network on a tap).
        .navigationDestination(for: MixedRowRoute.self) { route in
            if route == .rediscoverPool {
                // The pool page. Home hands over its computed pool.
                RediscoverPoolPage(pool: rediscoverPool,
                                   playerCoordinator: playerCoordinator,
                                   libraryViewModel: libraryViewModel)
            } else {
                MixedMediaPage(route: route,
                               continueIds: continueIdsAll, addedItems: recentlyAddedAll,
                               musicProgress: musicContinueProgress,
                               playerCoordinator: playerCoordinator,
                               libraryViewModel: libraryViewModel)
            }
        }
        .task(id: recomputeToken) {
            guard isActive else { return }
            await compute()
        }
        // The catalog loads MISS the first Start pass on a cold start.
        // NetworkMonitor answers false until NWPathMonitor's
        // first update, ensureLoaded()'s guard bailed, and with a cache-fed
        // library the recompute token never changed again (the row appeared
        // only after a tab switch flipped isActive). Same class and same cure
        // as the radio cold start: when connectivity arrives, kick the loads
        // once. The store publishes calm-gated, so the rows appear below the
        // visible area without a jolt.
        // `initial: true` keeps the first pass the subscription used to give:
        // the page must also kick the loads when it appears ALREADY online,
        // not only when the connection arrives later.
        .onChange(of: isOnline, initial: true) { _, connected in
            guard connected, isActive else { return }
            Task {
                // The loaders are REALLY kicked here rather than waited on,
                // and with a budget, so a dead server does not block the
                // return again.
                await SourceBudget.run { await freeCatalogStore.ensureLoaded() }
                await SourceBudget.run { await freeCatalogStore.ensureSourcesLoaded() }
            }
        }
        // Recompute the Discover filter only when its inputs change.
        .task(id: discoverToken) { recomputeDiscover() }
        .sheet(isPresented: $showQueueSheet) {
            PlayQueueSheet(playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    private var isEmpty: Bool {
        continueIds.isEmpty && queue.isEmpty && recentEpisodeItems.isEmpty && recentlyAddedItems.isEmpty
    }

    // MARK: - Sections (reused components only)

    /// "Continue": in-progress books + episodes as the SAME large FeaturedCards
    /// the library tabs use. BookFeaturedCard for books, PodcastFeaturedCard for
    /// episodes. Mixed in one horizontal carousel, ranked by last played. Cards
    /// mean "started"; the rows below (Up Next) mean "planned". No new component.

    @ViewBuilder
    private var continueSection: some View {
        if !continueIds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Chevron only when the page holds more than the row shows.
                // `shown` is the ACTUAL visible count. Home's own cap (10)
                // bites before RowPreview's (12), so deriving it is the only
                // way the rule stays true when either number changes.
                RowHeading(title: "Keep Listening", font: .title2,
                           total: continueIdsAll.count,
                           shown: RowPreview.cut(continueIds).count,
                           destination: MixedRowRoute.continueListening)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        // Preview cap. The row is not the shelf.
                        ForEach(RowPreview.cut(continueIds), id: \.self) { id in
                            continueCard(id)
                        }
                    }
                    .padding(.horizontal)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    /// Resolve a continue id to the matching card: a library book → the book
    /// card, anything else (a podcast episode) → the podcast card.
    @ViewBuilder
    private func continueCard(_ id: String) -> some View {
        // The card itself lives in MixedMediaPage.swift. Row and page share it.
        HomeContinueCard(id: id, musicProgress: musicContinueProgress[id],
                         playerCoordinator: playerCoordinator,
                         libraryViewModel: libraryViewModel)
    }

    /// "Up Next". The global PlayQueue, same row component as the queue page.
    @ViewBuilder
    private var upNextSection: some View {
        let items = queue.ids.compactMap { router.item($0) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
// The heading OPENS the queue sheet (the row's
                // existing home at the player). The action variant, born for
                // exactly this.
RowHeading<LibraryListRoute>.action("Up Next") { showQueueSheet = true }
                LazyVStack(spacing: 0) {
                    ForEach(items.prefix(5)) { item in
                        PlayQueueRow(item: item, playerCoordinator: playerCoordinator)
                            .padding(.horizontal)
                        Divider().padding(.leading, 88)
                    }
                }
            }
        }
    }

    /// "Recently Played". Albums and stations in ONE row, ordered by
    /// TIME (never a fair interleave: this is a truth row, see
    /// `RecentlyPlayedRow`). Same tiles as before, one heading; a tap plays
    /// in both classes. Albums with an open position stay in Continue. The
    /// boundary is position, not media type.
    /// ONE tile metric for the mixed row. The album size is Start's
    /// reference density; both classes take it, and `alignment: .top` gives
    /// the covers and their captions one baseline.
    private static let recentlyPlayedTileWidth: CGFloat = 150

    /// Catalogue titles started as album tracks. The third class of this row.
    /// Read from the ONE stock, where the play event left the form.
    private var catalogTracks: [ContinueSources.Extra] {
        ContinueSources.positionless(positions: ListeningStore.positions(),
                                     serverKnows: [],
                                     hiddenMarkers: ContinueHiddenStore.markers())
    }

    /// What the SOURCES carry (the row shows a preview of it).
    private var listenAgainTotal: Int {
        // Holdings display follows the HOLDINGS: a switched-off source
        // stops future traffic, never the view of what was already heard
        // (the radio effect line promises exactly that).
        let stations = RadioStore.recents().count
        return recentMusicItems.filter { !continueIds.contains($0.id) }.count
            + stations + catalogTracks.count
    }

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        let entries = RecentlyPlayedRow.merged(
            albums: recentMusicItems.map(\.id),
            albumTimes: RecentlyPlayedRow.albumTimes(musicContinueProgress),
            continued: Set(continueIds),
            stations: radioRecents.map(\.id),
            stationTimes: RadioStore.recentTimes(),
            catalog: catalogTracks.map(\.id),
            catalogTimes: RecentlyPlayedRow.catalogTimes(catalogTracks),
            limit: RowPreview.limit)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Now there IS a page. Counted chevron by the rule
                // (only when the sources carry more than the row shows).
                RowHeading(title: "Listen Again", font: .title2,
                           total: listenAgainTotal,
                           shown: entries.count,
                           destination: MixedRowRoute.listenAgain)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(entries, id: \.self) { entry in
                            switch entry {
                            case .album(let id):
                                if let item = recentMusicItems.first(where: { $0.id == id }) {
                                    AlbumCell(item: item, width: Self.recentlyPlayedTileWidth,
                                              playerCoordinator: playerCoordinator)
                                        .frame(width: Self.recentlyPlayedTileWidth,
                                               alignment: .top)
                                }
                            case .catalogTrack(let id):
                                CatalogTrackCell(itemId: id,
                                                 width: Self.recentlyPlayedTileWidth,
                                                 playerCoordinator: playerCoordinator)
                            case .station(let id):
                                if let station = radioRecents.first(where: { $0.id == id }) {
                                    // The ROW's metric, not the class's.
                                    // The album size is Start's density, and a
                                    // mixed row with two sizes reads as torn.
                                    // A TILE navigates, a CARD plays. The
                                    // line runs along the component shape,
                                    // not along the surface.
                                    RadioStationCard(station: station,
                                                     playerCoordinator: playerCoordinator,
                                                     width: Self.recentlyPlayedTileWidth,
                                                     onRemoveFromRecents: {
                                                         RadioStore.removeRecentNoting(station)
                                                     })
                                        .frame(width: Self.recentlyPlayedTileWidth,
                                               alignment: .top)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    /// "Latest Episodes". See `LatestEpisodesGrid` (shared with the
    /// podcast tab).
    @ViewBuilder
    private var latestEpisodesSection: some View {
        if !recentEpisodeItems.isEmpty {
            // The SHARED grid. Identical on the podcast tab.
            LatestEpisodesGrid(items: recentEpisodeItems, playerCoordinator: playerCoordinator)
        }
    }

    private func episodeProgress(_ item: LibraryItem) -> Double? {
        if case .inProgress(let fraction, _) = podcastPlayState(for: item) { return fraction }
        return nil
    }

    /// Teil 4 "Discover" (stage 1: podcast shows): one row from the existing
    /// RecommendationsStore (PodcastIndex/charts, same as the podcast tab),
    /// with an HONEST reason as the subtitle. Derived locally only. Already
    /// subscribed shows never appear (filtered again at render time, the pool
    /// may predate a subscription). The corner control is the SAME subscribe
    /// flow as the podcast tab's Discover grid; the tile tap opens that grid.
    @ViewBuilder
    private var discoverSection: some View {
        // The subscribed-Set + filter are computed off the body (discoverToken);
        // the section only reads the result.
        let shown = discoverShown
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
// Welle 3: Discover's page is the SAME recommendation pool
                // page as the podcast tab's. The book admixture is
                // Discover's curation, the pool is the stock.
                // The personal row gives the "Discover" name to the
                // catalog family. It is computed FROM the listener, so it says
                // so ("Empfohlen"; tab parity with the podcast tab). Reason
                // subtitles and the shared pool page stay unchanged.
                RowHeading(title: "Recommended",
                           total: recommendations.results.count,
                           shown: discoverShown.count,
                           destination: PodcastRoute.recommendations)
                // Horizontally scrollable, the FULL recommendation pool.
                // One shared tile with the podcast tab (RecommendationTile);
                // its tap opens the temporary show preview.
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        // LibriVox books mix in at a moderate share
                        // (pure discoverMix, cap 3) with the honest Discover-
                        // style reason line; tap opens the detail sheet.
                        let mixed = FreeCatalog.discoverMix(
                            recommendations: shown,
                            books: discoverBooksRowVisible ? freeCatalogStore.rows.discoverBooks : [])
                        ForEach(Array(mixed.enumerated()), id: \.offset) { _, slot in
                            Group {
                                if let result = slot.rec {
                                    RecommendationTile(
                                        result: result,
                                        subtitle: reasonText(recommendations.reason(for: result)))
                                        .recommendationHideMenu(result)
                                } else if let book = slot.book {
                                    // The SAME free-catalog tile
                                    // as the audiobook rows. Tap plays. It used
                                    // to open the detail sheet here and play
                                    // there, for the identical content; the
                                    // long-press menu keeps the detail path.
                                    // Tap = detail, long-press = Play
                                    // shortcut.
                                    FreeCatalogBookTile(
                                        item: book,
                                        onTap: { pushFreeAudiobooksRoute(.catalogBook(itemId: book.id)) })
                                    .contextMenu {
                                        Button {
                                            Task { await playerCoordinator.open(item: book) }
                                        } label: { Label("Play", systemImage: "play.fill") }
                                    }
                                }
                            }
                            // Screen-relative slots + peek.
                            .cardRowSlot()
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func reasonText(_ reason: PodcastRecommendationsStore.Reason) -> String {
        PodcastRecommendationsStore.reasonLine(reason)
    }

    /// Start's mixed free-audiobooks row. Tiles via the ONE shared
    /// computation (`CatalogMix.hoerspieleTiles`), row via the ONE shared
    /// `CatalogMixRow`. The store row loads in compute(). A lazy
    /// below-the-fold .task never ran reliably); until the catalogs land the
    /// mix shows the static feed curation, so the row is never empty.
    @ViewBuilder
    private var discoverAudiobooksSection: some View {
        let tiles = CatalogMix.tiles(for: .home, rows: freeCatalogStore.sourceRows)
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading.entry("Discover · Radio Plays & Audiobooks",
                                 destination: FreeAudiobooksRoute.area)
                    .accessibilityIdentifier("home-discover-audiobooks")
                CatalogMixRow(tiles: tiles, playerCoordinator: playerCoordinator)
            }
        }
    }

    /// "Rediscover": daily-rotated local picks, horizontally
    /// scrollable with the full candidate pool. Hidden without candidates.
    @ViewBuilder
    private var rediscoverSection: some View {
        if !rediscoverPicks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
RowHeading(title: "Rediscover",
                           total: rediscoverPool.count,
                           shown: RowPreview.cut(rediscoverPicks).count,
                           destination: MixedRowRoute.rediscoverPool)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(RowPreview.cut(rediscoverPicks), id: \.id) { pick in
                            rediscoverTile(pick)
                                // Screen-relative slots + peek instead of
                                // the fixed 140 pt.
                                .cardRowSlot()
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func rediscoverTile(_ pick: RediscoverSections.Pick) -> some View {
        // Shared with the pool page. One tile.
        RediscoverTile(pick: pick, playerCoordinator: playerCoordinator,
                       libraryViewModel: libraryViewModel)
    }

    /// "Recently Added": newly added books AND albums in one horizontal shelf,
    /// ranked by added time. Each tile is its own tab's component. BookGridCell
    /// for a book, AlbumCell for an album. At one shared width so the mixed row
    /// stays even. No Home-specific tile.
    @ViewBuilder
    private var recentlyAddedSection: some View {
        if !recentlyAddedItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading(title: "Recently Added",
                           total: recentlyAddedAll.count,
                           shown: RowPreview.cut(recentlyAddedItems).count,
                           destination: MixedRowRoute.recentlyAdded)
                ScrollView(.horizontal, showsIndicators: false) {
                    // LazyHStack (was eager). The lazy variant used to freeze
                    // the shelf height on the first cell and clip taller ones. An
                    // EXPLICIT per-cell height fixes that: the cover is a fixed 150,
                    // the text block scales with Dynamic Type, so every cell is the
                    // same height and none clips.
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(RowPreview.cut(recentlyAddedItems)) { item in
                            recentlyAddedTile(item)
                                .frame(width: 150, height: recentlyAddedCellHeight, alignment: .top)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }


    /// A recently-added id resolves to a library book → the book grid cell,
    /// otherwise (an album) → the album cell.
    @ViewBuilder
    private func recentlyAddedTile(_ item: LibraryItem) -> some View {
        HomeRecentlyAddedTile(item: item, playerCoordinator: playerCoordinator,
                              libraryViewModel: libraryViewModel)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing here yet",
            systemImage: "house",
            description: Text("Start listening. Your books, podcasts and music show up here.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Snapshot compute (off the body)

    private func compute() async {
        // 🟡 The sources no longer hold each other hostage. Every await
        // below used to sit in ONE serial chain in front of ONE apply, so a
        // hanging source (an unreachable homeserver!) kept the WHOLE start
        // page empty. "source instead of start", the hostage class one
        // level up from "section instead of tab". The refresh KICKS now and
        // is awaited with a budget: what is there appears, what is missing
        // is missing (the serverless principle holds for Start too), and a
        // late source lands in its own apply through the calm gate.
        // Sections land INDEPENDENTLY: what is local is there
        // NOW. The radio recents are a synchronous defaults read; making
        // them wait for the music server (which is what the single apply at
        // the end did) is exactly that hostage situation.
        // Holdings, not source: the stored stations resolve locally
        // (whole objects incl. stream URL), so the view of them never
        // hangs on the source switch.
        let localRadio = RadioStore.recents()
        if !localRadio.isEmpty, radioRecents.isEmpty {
            ScrollCalm.run {
                radioRecents = localRadio
                ready = true          // the page is usable with what it has
            }
        }
        // The independent sources start TOGETHER. Otherwise their budgets
        // add up (three dead music calls = three budgets before anything
        // renders). Started here, awaited where each result is needed: the
        // wait becomes the SLOWEST source, not their sum.
        let musicProvider = AppSession.shared.musicProvider
        // A LATE result does not expire. It applies itself through
        // the same calm gate, so the row fills up by itself instead of
        // waiting for a tab switch (the recompute token only changes there).
        async let musicProgressTask = SourceBudget.value(
            default: [String: BookProgress](),
            onLate: { late in await MainActor.run { LateMusicValues.shared.setProgress(late) } }
        ) {
            (try? await musicProvider.fetchAllProgress()) ?? [:]
        }
        async let newAlbumsTask = SourceBudget.value(
            default: [LibraryItem](),
            onLate: { late in await MainActor.run { LateMusicValues.shared.setNewAlbums(late) } }
        ) {
            (try? await musicProvider.albumShelf(shelf: .newest, size: 12)) ?? []
        }
        async let recentMusicTask = SourceBudget.value(
            default: [LibraryItem](),
            onLate: { late in await MainActor.run { LateMusicValues.shared.setRecentAlbums(late) } }
        ) {
            (try? await musicProvider.albumShelf(shelf: .recent, size: 12)) ?? []
        }
        async let freeRowsTask: Void = SourceBudget.run { await freeCatalogStore.ensureLoaded() }
        async let freeSourcesTask: Void = SourceBudget.run { await freeCatalogStore.ensureSourcesLoaded() }

        await SourceBudget.run { await PodcastSubscriptions.shared.ensureLoaded() }
        await SourceBudget.run { await ABSPodcastProvider.shared.refreshIfStale() }
        let shows = PodcastAutoContinue.allShows()
        let snapshot = PodcastSections.snapshot(shows: shows)
        let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)

        // Continue: in-progress books and episodes, by last played.
        let hidden = ContinueHiddenStore.markers()
        // Every source on ONE clock (ms), so the row ranks by the real
        // moment across books, episodes and albums.
        let books = libraryViewModel.continueListening.map {
            (id: $0.id, ts: HomeSections.lastPlayedMs(
                local: localTimestamp($0.id),
                server: $0.progress?.lastUpdate ?? 0,
                playingNowMs: PlayingNow.momentMs(forId: $0.id)))
        }
        // Rediscover's "paused" source needs exactly what Continue DROPPED, so
        // it reads the unfiltered list. Feeding it the filtered one (as it did
        // once) silently emptied that source: the age
        // cutoff removed the old entries from Continue, and Rediscover never
        // saw them either. The titles fell out of BOTH rows instead of moving
        // from one to the other.
        // Manually hidden titles stay out of Rediscover too: the user pushed
        // them away on purpose, and a suggestion row would hand them straight
        // back. What the AGE cutoff dropped is a different case. That is
        // exactly what Rediscover is for.
        let pausedCandidates = libraryViewModel.continueAll
            .filter { !ContinueHidden.isHidden(id: $0.id,
                                               lastUpdate: $0.progress?.lastUpdate ?? 0,
                                               markers: hidden) }
            // Rediscover asks for what PAUSED: the stands, never "playing".
            .map { (id: $0.id, ts: HomeSections.normalizedMs($0.progress?.lastUpdate ?? 0)) }
        // The same moment the episode card names (local or server stand,
        // whichever is newer), so the row cannot rank by one clock and
        // show another.
        let episodes = sections.nextUp.map {
            (id: $0.id, ts: HomeSections.lastPlayedMs(
                local: localTimestamp($0.id),
                server: ABSPodcastProvider.shared.episodeProgress[$0.id]?.lastUpdate ?? 0,
                // What plays IS the newest thing: its stand is written every
                // thirty seconds, and between two writes a stand arriving
                // from the other device used to push it down the row.
                playingNowMs: PlayingNow.momentMs(forId: $0.id)))
        }
        // Package 3: in-progress music playlists as a THIRD stream (no merge
        // rewrite. byRecency already takes N streams). Keep the progress map so
        // the playlist card can render its bar + resume.
        // The music server is the source that vanished with the Tiny. Its
        // absence must cost the start page nothing but the music rows.
        let musicProgress = await musicProgressTask
        // Music never stands in Continue: a started album or playlist goes
        // to "Listen Again" (with its position, the resume is unchanged; the
        // one form question, asked once here).
        let startedMusic = musicProgress
            .filter { key, value in
                let kind = AppSession.shared.musicProvider(for: key).kind(of: key)
                return (kind == .playlist || kind == .album) && value.isStarted
            }
            .map { (id: $0.key, ts: HomeSections.lastPlayedMs(
                local: 0, server: $0.value.lastUpdate,
                playingNowMs: PlayingNow.momentMs(forId: $0.key))) }
        let music = startedMusic.filter { HomeSections.continueAccepts($0.id) }
        let startedAlbumIds = Set(startedMusic.map(\.id)).subtracting(music.map(\.id))
        // Row limit 10 (landscape/iPad show 4–5 cards),
        // music share capped at 2 via the pure rule (exception inside).
        // The marker acts on the WHOLE mixed row, so
        // hiding works the same for a book, an episode and an album. Books are
        // already filtered in the view model; episodes and music are filtered
        // here, where their streams meet.
        let episodesShown = episodes.filter {
            !ContinueHidden.isHidden(id: $0.id, lastUpdate: $0.ts, markers: hidden)
        }
        let musicShown = music.filter {
            !ContinueHidden.isHidden(id: $0.id, lastUpdate: $0.ts, markers: hidden)
        }
        let musicIds = Set(musicShown.map(\.id))
        let rankedContinue = HomeSections.cappedShare(
            HomeSections.byRecency([books, episodesShown, musicShown], limit: 24),
            capped: musicIds, cap: HomeSections.continueMusicCap, limit: 10)
        // The same ranking WITHOUT the row's curation. The page shows
        // everything that is actually in progress, the row shows a preview of it.
        let allContinue = HomeSections.byRecency([books, episodesShown, musicShown], limit: 200)
        // The Continue row says why it is empty: without this line a missing
        // row is indistinguishable from a row whose every candidate was
        // filtered out. Per stream: what went IN and what was LEFT, plus what
        // each filter took.
        Logger.library.notice("""
            HOME continue row=\(rankedContinue.count, privacy: .public) \
            all=\(allContinue.count, privacy: .public) \
            books=\(books.count, privacy: .public) \
            eps=\(episodes.count, privacy: .public)/\(episodesShown.count, privacy: .public) \
            music=\(startedMusic.count, privacy: .public)/\(music.count, privacy: .public)/\(musicShown.count, privacy: .public) \
            toListenAgain=\(startedAlbumIds.count, privacy: .public) \
            hiddenMarks=\(hidden.count, privacy: .public)
            """)

        // Radio on Home: cheap sync read of the HOLDINGS. The source
        // switch stops future traffic only; what was heard keeps showing
        // (empty holdings hide the section, no placeholder).
        let radio = RadioStore.recents()

        // "Latest Episodes": the newest episode of each show, newest first.
        // The shared pure derivation, capped at 30 so the six-row expansion
        // has content (a cap of 8 starved it).
        let episodeIds = PodcastSections.newestPerShow(shows: shows + CoListenedShows.shows())

        // "Recently Added": newly added books + newly added albums (the
        // "newest" shelf, best-effort. Empty without a music server). Both inputs
        // are already recency-ordered; a FAIR interleave keeps both libraries
        // present (a pure time sort let the music library's fresher timestamps take
        // every slot, so books vanished).
        let bookItems = libraryViewModel.recentlyAdded.map(\.item)
        let newAlbums = await newAlbumsTask
        // Recently played music. The ONE provider access point again. The
        // started albums and playlists, which never stand in Continue, join
        // it here, so "Listen Again"
        // carries every album with a position too, ranked by that moment.
        let recentMusicShelf = await recentMusicTask
        let knownAlbumIds = Set(recentMusicShelf.map(\.id))
        // The ONE resolver of this pass, for the albums and the episodes.
        let resolveItem = router.item
        let startedAlbums = startedAlbumIds.subtracting(knownAlbumIds).sorted().compactMap(resolveItem)
        let recentMusic = recentMusicShelf + startedAlbums
        // Free-catalog rows load HERE (compute always runs). Once
        // per session, but retried while empty (a failed first pass heals on
        // the next recompute instead of deciding forever).
        // The fill lives in the shared store now.
        await freeRowsTask
        // The mixed audiobooks row needs the catalog SOURCE rows too.
        // Same rule as above (below-the-fold .task is unreliable, compute
        // always runs; idempotent, so a podcast-tab visit costs nothing).
        // This deliberately widens the old "not in the Home pass" line: the
        // row now RENDERS on Start, so Start owns a load kick.
        await freeSourcesTask
        let byId = Dictionary((bookItems + newAlbums).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mergedIds = HomeSections.interleave([bookItems.map(\.id), newAlbums.map(\.id)], limit: 12)
        // Uncapped counterpart for the page behind the row.
        let allAddedIds = HomeSections.interleave(
            [bookItems.map(\.id), newAlbums.map(\.id)], limit: 200)
        // Resolved through the SAME `byId` the row uses. One source, so the
        // page can never come up shorter than its own preview.
        let allAddedItems = allAddedIds.compactMap { byId[$0] }

        // Precompute the continue-card accents before they render.
        for id in rankedContinue {
            await CoverColorLoader.prewarm(url: router.coverURL(id))
        }
        let rediscover: [RediscoverSections.Pick]
        var pool = RediscoverSections.Pool()
        if recommendationsEnabled {
            (rediscover, pool) = computeRediscover(
                bookContinue: pausedCandidates, episodeContinue: episodesShown,
                visibleContinue: Set(rankedContinue))
            await SourceBudget.run { await recommendations.refreshIfNeeded() }
        } else {
            rediscover = []
        }
        let episodeItems = episodeIds.compactMap(resolveItem)
        let addedItems = mergedIds.compactMap { byId[$0] }
        let initialFill = !ready
        let apply: @MainActor () -> Void = {
            radioRecents = radio
            continueIds = rankedContinue
            continueIdsAll = allContinue
            recentlyAddedAll = allAddedItems
            LateMusicValues.shared.setProgress(musicProgress)
            recentEpisodeItems = episodeItems
            recentlyAddedItems = addedItems
            LateMusicValues.shared.setRecentAlbums(recentMusic)
            rediscoverPicks = rediscover
            rediscoverPool = pool
            withAnimation(initialFill ? .easeOut(duration: 0.25) : nil) { ready = true }
        }
        // Layout-shift fix: same calm gate as the other libraries. A landed
        // recompute never reshapes Home mid-scroll.
        if initialFill { apply() } else { ScrollCalm.run(apply) }
    }

    /// Teil 3: assemble the three candidate sources (mixed media types) and let
    /// the pure logic pick. Timestamps normalized to seconds.
    private func computeRediscover(
        bookContinue: [(id: String, ts: Double)],
        episodeContinue: [(id: String, ts: Double)],
        visibleContinue: Set<String>
    ) -> ([RediscoverSections.Pick], RediscoverSections.Pool) {
        // (a) paused: started books + episodes, EXCLUDING what the Continue
        // carousel already shows (no doubles on one page).
        let paused = (bookContinue + episodeContinue)
            .filter { !visibleContinue.contains($0.id) }
            .map { (id: $0.id, lastPlayed: Self.seconds($0.ts)) }
        // (b) unheard additions (books; albums have no reliable local addedAt).
        let unheard = libraryViewModel.entries
            .filter { !($0.progress?.isStarted ?? false) && !($0.progress?.countsAsFinished ?? false) }
            .compactMap { entry -> (id: String, addedAt: Double)? in
                guard let added = entry.item.addedAt else { return nil }
                return (entry.id, Self.seconds(added))
            }
        // (c) the next UNSTARTED volume after a finished predecessor.
        let seriesNext = libraryViewModel.entries
            .filter { $0.progress?.countsAsFinished ?? false }
            .compactMap { finished -> (id: String, volume: Int)? in
                guard let next = libraryViewModel.nextInSeries(after: finished.id),
                      !(next.progress?.isStarted ?? false) else { return nil }
                return (next.id, RediscoverSections.volume(fromSeriesName: next.item.media?.metadata?.seriesName) ?? 0)
            }
        // Subscribed shows LONG unheard that still hold unplayed
        // episodes. Last listen per feed from the local listen log (the same
        // "no profile leaves the device" base), threshold shared in picks().
        let log = PodcastListenLog.shared.entries
        // Only OBSERVED listens (stamped transitions) date a feed.
        // Backfill bookkeeping does not, otherwise every backfilled show
        // looks freshly heard for weeks.
        var lastByFeed: [String: Double] = [:]
        for entry in log.values where !entry.feedURL.isEmpty && entry.hasObservedTime {
            lastByFeed[entry.feedURL] = max(lastByFeed[entry.feedURL] ?? 0, entry.playedAt)
        }
        // The qualifying condition is UNPLAYED EPISODES, not the
        // presence of a log entry. A show never heard since the log exists
        // rides along with an unknown date instead of being dropped.
        let showsDormant = PodcastSubscriptions.shared.shows.compactMap { show -> (id: String, lastPlayed: Double?)? in
            guard show.episodes.contains(where: { log[$0.guid]?.isPlayed != true }) else { return nil }
            return (Self.showPickPrefix + show.feedURL, lastByFeed[show.feedURL].map(Self.seconds))
        }
        let now = Date()
        // Picks AND pool from the same inputs. The row shows the
        // daily rotation, the page shows the pool (one filter source).
        let picks = RediscoverSections.picks(
            paused: paused, unheard: unheard, seriesNext: seriesNext,
            showsDormant: showsDormant,
            now: now, daySeed: RediscoverSections.daySeed(for: now),
            limit: Self.rediscoverPoolLimit)
        let pool = RediscoverSections.pool(
            paused: paused, unheard: unheard, seriesNext: seriesNext,
            showsDormant: showsDormant, now: now)
        return (picks, pool)
    }

    /// Show picks ride the feed URL behind a marker prefix.
    static let showPickPrefix = "rediscover-show:"

    /// The horizontal row carries the full pool, capped so it stays a row.
    private static let rediscoverPoolLimit = 24

    /// ABS timestamps are milliseconds since 1970. Normalize to seconds.
    private static func seconds(_ ts: Double) -> Double {
        ts > 4_000_000_000 ? ts / 1000 : ts
    }

    /// Last-played timestamp of an item from the local position store (same
    /// source podcast auto-continue uses), 0 if none.
    private func localTimestamp(_ id: String) -> Double {
        ProgressMark.timestamp(ListeningStore.backup(id)) ?? 0
    }
}


/// THE Rediscover tile. Row AND pool page render it.
struct RediscoverTile: View {
    @Environment(\.itemRouter) private var router
    let pick: RediscoverSections.Pick
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel
    @Environment(\.pushPodcastRoute) private var pushRoute
    @Environment(\.pushBookDetail) private var pushBook

    var body: some View {
        // The shared scope is the ONE observer of download/network state;
        // show picks open the SHOW page.
        if pick.id.hasPrefix(HomeView.showPickPrefix) {
            let feedURL = String(pick.id.dropFirst(HomeView.showPickPrefix.count))
            if let show = PodcastSubscriptions.shared.shows.first(where: { $0.feedURL == feedURL }) {
                MediaTile(
                    title: show.title,
                    subtitle: Self.subtitle(pick.reason),
                    coverURL: show.artworkURL.flatMap { URL(string: $0) },
                    placeholderSystemImage: "mic",
                    onTap: { pushRoute(.show(feedURL: feedURL)) }
                )
            }
        } else if let entry = libraryViewModel.entry(id: pick.id) {
            MediaAvailabilityScope(itemId: entry.id) { unavailable in
                MediaTile(
                    title: entry.item.title,
                    subtitle: Self.subtitle(pick.reason),
                    coverURL: router.coverURL(entry.id),
                    placeholderSystemImage: "book.closed",
                    progress: (entry.progress?.isStarted ?? false) ? entry.progress?.fraction : nil,
                    unavailable: unavailable,
                    onTap: { pushBook(entry.id) }
                ) {
                    MediaTilePlayBadge { Task { await playerCoordinator.open(item: entry.item) } }
                }
            }
        } else if let item = router.item(pick.id) {
            MediaAvailabilityScope(itemId: item.id) { unavailable in
                MediaTile(
                    title: item.title,
                    subtitle: Self.subtitle(pick.reason),
                    coverURL: router.coverURL(item.id),
                    progress: {
                        if case .inProgress(let fraction, _) = podcastPlayState(for: item) { return fraction }
                        return nil
                    }(),
                    unavailable: unavailable,
                    onTap: { pushRoute(.episode(itemId: item.id)) }
                ) {
                    MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
                }
            }
        }
    }

    static func subtitle(_ reason: RediscoverSections.Reason) -> String {
        switch reason {
        case .paused(let weeks):
            return String(localized: "Paused for \(weeks) weeks")
        case .unheardSince(let added):
            return String(localized: "Unheard since \(added.formatted(.dateTime.month(.wide).year()))")
        case .nextInSeries(let volume):
            return volume > 0
                ? String(localized: "Volume \(volume) of your series")
                : String(localized: "Next volume of your series")
        case .showDormant(let weeks):
            return String(localized: "Not listened for \(weeks) weeks")
        case .showDormantUnknown:
            return String(localized: "Long unheard, new episodes waiting")
        }
    }
}

/// The pool IS the page: the FULL candidate pool, unshuffled,
/// grouped by source. The page turns "today for you" into browsable.
struct RediscoverPoolPage: View {
    let pool: RediscoverSections.Pool
    @ObservedObject var playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                section("Paused", picks: pool.paused)
                section("Lying unheard", picks: pool.unheard)
                section("Next in your series", picks: pool.seriesNext)
                section("Dormant shows", picks: pool.showsObserved + pool.showsUnknown)
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Rediscover"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, picks: [RediscoverSections.Pick]) -> some View {
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading.plain(title)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(picks, id: \.id) { pick in
                        RediscoverTile(pick: pick, playerCoordinator: playerCoordinator,
                                       libraryViewModel: libraryViewModel)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
