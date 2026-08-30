// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit
import OSLog

struct LibraryView: View {
    // Process-wide instances (AppSession) instead of own @StateObjects. The
    // CarPlay scene shares the player and library with the UI.
    @ObservedObject private var viewModel: LibraryViewModel
    @ObservedObject private var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    /// Observe subscriptions so the podcast tab appears/disappears immediately.
    @ObservedObject private var podcastSubs = PodcastSubscriptions.shared
    /// Observe the source configuration. `availableMediaTypes` reads
    /// `isAvailable` per render, so the tab bar follows every toggle live
    /// (Subsonic reloadConfig, ABS-podcast probe) in BOTH directions.
    @ObservedObject private var session = AppSession.shared
    @State private var isShowingSearch = false
    /// The search field lives in the BOTTOM bar; bar and search page
    /// share this model (the page renders, the bar types).
    @StateObject private var searchModel = GlobalSearchModel.production()
    @FocusState private var searchFieldFocused: Bool
    /// Single-select scope of the search page. Starts at the opening
    /// tab's scope (Y13 successor).
    @State private var searchScope: SearchScope = .library
    @State private var navigationPath = NavigationPath()
    @State private var isShowingFullPlayer = false
    @State private var showDeleteAllDownloads = false
    /// Up-Next queue sheet (mini-player long-press entry).
    @State private var showQueueSheet = false
    /// Scroll-driven collapsing of the bottom zone (Apple-Music-like): scrolling
    /// in the library turns it into a compact row.
    @Namespace private var barNS
    /// Native glass-morph namespace (24.07): the bottom-bar `.glass` surfaces live
    /// in ONE `GlassEffectContainer` (shared sampling region) and morph via
    /// `glassEffectID` in this namespace. Media pill ↔ home button, magnifier ↔
    /// search field. Instead of cross-fading independent glass surfaces.
    @Namespace private var bottomGlassNS
    // Drive mode: rare-flip state (enter/exit only, never during a gesture).
    // Observing it here does NOT violate the leaf convention, and the
    // fullScreenCover trigger needs the re-render. While active, the library
    // is covered anyway.
    @ObservedObject private var driveMode = DriveModeController.shared
    // HITCH ROOT (26.07): LibraryView must NOT observe BottomBarState. It
    // hosts all five tab trees, and every collapse flip re-evaluated them all
    // (the bump that survived every bisect part-effect switch). Only the
    // small `BottomBarCollapseReader` leaves observe `collapsed`; state
    // mutations go through method calls on the shared instance.
    /// Lag applied to the bottom bar's collapse spring so it follows the top
    /// icons out of frame instead of vanishing in the same frame (24.07 decouple).
    private static let barCollapseLag: TimeInterval = 0.12
    /// Vertical drag offset of the full player while dismissing downward
    /// (0 at rest).
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    /// Fixed-width carousel tiles get extra text lines at accessibility
    /// sizes instead of truncating titles to fragments.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Cover accent of the ACTIVE book. Shared with every glass element in
    /// the bottom bar (mini player, search button, pill) via environment.
    // The bar accent persists across sessions. It only ever changes
    // cover-to-cover (see the environment wiring below).
    @StateObject private var bottomColorLoader = CoverColorLoader(persistenceKey: AppStorageKeys.bottomBarAccent)
    /// Book-switch swap animation of the mini player (pushed below the
    /// screen while the new accent loads, then springs back up).
    @State private var miniPlayerSwapOffset: CGFloat = 0
    @State private var lastBottomAccentItemId: String?
    // ARCHITECTURE (25.07): the bottom clearance is the CONSTANT
    // `BottomBarReserve`. The whole live-measurement path (GeometryReader,
    // bottomBarHeight state, settle-debounce, fire-time re-validation) is
    // GONE; the bar cannot perturb scroll geometry by construction.
    /// Settings as a modal sheet (NOT pushed onto the library stack). Otherwise
    /// the mini-player overlay lies over it and its media pills trigger a jump
    /// back to the library from within the settings.
    @State private var showSettings = false
    /// Active content-type tab. Today audiobooks only; the bottom tab bar only
    /// appears when a second source brings a different type.
    @State private var selectedMediaType: MediaType = .home
    // Teil 2: per-tab sort/filter, shared with the tab content via the same
    // AppStorage keys (audiobooks keep using LibraryViewModel's own state).
    // The podcast/music sort state no longer lives here. It moved to
    // the surfaces that own it (PodcastsView, MusicAlbumsPage). LibraryView
    // used to hold it only because the toolbar button sat here. Persistence and
    // the keys are unchanged, so the stored preference survives the move.
    /// Downloaded shelf expanded past its capped count (F6/G19).
    @State private var downloadedExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Tabs that have been shown at least once. They stay mounted (hidden)
    /// afterwards so their state/tasks survive switching. Never-visited tabs
    /// aren't mounted at all (no startup cost for the podcast/music chain).
    @State private var mountedTabs: Set<MediaType> = [.home]
    /// DAMPING (an interim, NOT a root fix. Repeated title state
    /// transitions on a live bar permanently drop the large title on
    /// iOS 26). The displayed bar title is decoupled from the
    /// tab flip: it retargets one runloop tick AFTER `selectedMediaType`
    /// changes, so the title transition never lands inside the bar's tab
    /// transition. Root fix is the per-tab NavigationStack structure
    /// (compat-sprint item 9). Constant titles remove the bug condition.
    @State private var barTitle: String = LibraryView.title(for: .home)

    private static func title(for type: MediaType) -> String {
        type == .audiobooks ? String(localized: "Library") : type.label
    }

    private func isTabMounted(_ type: MediaType) -> Bool {
        mountedTabs.contains(type) || selectedMediaType == type
    }

    /// Which tabs exist. POSITIVE and in ONE place: every tab the
    /// USER has on is there. Whether a server answers is a section's question,
    /// never the tab's. Coupling tabs to provider availability made the app
    /// look empty to exactly the people the free catalogs are for. Serverless,
    /// every tab opens and shows its free core.
    private var availableMediaTypes: [MediaType] {
        // Home is an aggregation tab (no source). Always first.
        [.home] + MediaType.allCases.filter { $0 != .home && $0.userMasterEnabled }
    }

    let provider: any AudioProvider
    let onLogout: () -> Void

    init(provider: any AudioProvider, onLogout: @escaping () -> Void) {
        self.provider = provider
        self.onLogout = onLogout
        _viewModel = ObservedObject(wrappedValue: AppSession.shared.libraryViewModel)
        _playerCoordinator = ObservedObject(wrappedValue: AppSession.shared.playerCoordinator)
        // Letzter-Tab (01.08): start on the last selected tab. But only when
        // its MASTER toggle is still on (availability is irrelevant here, the
        // A transiently unreachable tab shows its own state).
        // Seeded journeys keep the deterministic Home start (every journey
        // would otherwise inherit the previous one's tab) unless they opt in.
        let args = ProcessInfo.processInfo.arguments
        let restoreBlocked = args.contains("-uitest") && !args.contains("-uitest-keeptab")
        if !restoreBlocked, let raw = AppStorageKeys.lastSelectedTabValue,
           let restored = MediaType(rawValue: raw), restored.userMasterEnabled {
            _selectedMediaType = State(initialValue: restored)
            _mountedTabs = State(initialValue: [.home, restored])
            _barTitle = State(initialValue: LibraryView.title(for: restored))
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                if viewModel.isShowingOfflineCache {
                    offlineBanner
                }

                // Content by tab. Once visited, a tab stays MOUNTED (hidden via
                // opacity) instead of being torn down by a `switch`. A branch
                // change used to destroy all @State/@StateObject/.task of the
                // old tab, so every return re-ran the tab's full load chain
                // (that was the tab-switch sluggishness).
                ZStack {
                    // Damping stage (a): ONE hidden probe captures the
                    // stack's UINavigationController for the post-flip nudge.
                    NavigationBarNudge.Probe()
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                    Group {
                        if isTabMounted(.home) {
                            HomeView(playerCoordinator: playerCoordinator,
                                     isActive: selectedMediaType == .home,
                                     libraryViewModel: viewModel)
                                .tabVisibility(selectedMediaType == .home)
                        }
                        if isTabMounted(.audiobooks) {
                            audiobooksContent
                                .tabVisibility(selectedMediaType == .audiobooks)
                        }
                        if isTabMounted(.podcasts) {
                            PodcastsView(playerCoordinator: playerCoordinator,
                                         isActive: selectedMediaType == .podcasts)
                                .tabVisibility(selectedMediaType == .podcasts)
                        }
                        if isTabMounted(.music) {
                            MusicView(playerCoordinator: playerCoordinator,
                                      isActive: selectedMediaType == .music)
                                .tabVisibility(selectedMediaType == .music)
                        }
                        if isTabMounted(.radio) {
                            RadioView(playerCoordinator: playerCoordinator,
                                      isActive: selectedMediaType == .radio)
                                .tabVisibility(selectedMediaType == .radio)
                        }
                    }
                    // The search page fully covers the active
                    // tab. Covered content must not stay reachable for
                    // VoiceOver behind the page.
                    .accessibilityHidden(isShowingSearch)
                    // Search mode is a FULL PAGE over the tab content
                    // (inside the stack. The deck's grid cells push value
                    // routes onto the same navigationPath).
                    if isShowingSearch {
                        SearchScreen(
                            libraryViewModel: viewModel,
                            model: searchModel,
                            playerCoordinator: playerCoordinator,
                            scope: $searchScope,
                            onOpen: { result in
                                closeSearch()
                                openSearchResult(result)
                            },
                            onOpenMusicRoute: { route in
                                closeSearch()
                                selectedMediaType = .music
                                navigationPath.append(route)
                            }
                        )
                        .background(Color(.systemBackground).ignoresSafeArea())
                        .transition(.opacity)
                    }
                }
                .onChange(of: selectedMediaType) { _, newValue in
                    mountedTabs.insert(newValue)
                    // Letzter-Tab: remember the choice across launches.
                    AppStorageKeys.lastSelectedTabValue = newValue.rawValue
                    // Retarget the title OUTSIDE the flip's
                    // transaction (next main-actor tick), see `barTitle`.
                    // Stage (a): afterwards verify the bar actually shows the
                    // title and force a large-title rebuild if not. The tick
                    // alone proved flaky in long suite runs.
                    Task { @MainActor in
                        let title = Self.title(for: newValue)
                        barTitle = title
                        NavigationBarNudge.nudgeIfTitleMissing(expectedTitle: title)
                    }
                }
                // Fall back to Home ONLY on a real user
                // deactivation (master toggle). Transient availability
                // (server unreachable, probe pending, async subscription
                // load) never moves the selection; the tab shows its own
                // offline/empty state instead. The old `availableMediaTypes`
                // check threw users off the podcast tab on every start once
                // servers became VPN-only reachable.
                .onChange(of: session.sourcesVersion) { _, _ in
                    // Diagnosis (log-first, device-readable): full source
                    // state at every bump, so a thrown selection is traceable.
                    let subs = PodcastSubscriptions.shared
                    Logger.library.notice("Y37 sources changed → tabs \(availableMediaTypes.map(\.rawValue).joined(separator: ","), privacy: .public) selected=\(selectedMediaType.rawValue, privacy: .public) masters(a/p/m/r)=\(AppStorageKeys.audiobooksTabEnabledValue)/\(AppStorageKeys.podcastsTabEnabledValue)/\(AppStorageKeys.musicTabEnabledValue)/\(AppStorageKeys.radioTabEnabledValue) absPod=\(AppStorageKeys.absPodcastsActive)/\(ABSPodcastProvider.shared.hasPodcasts) rss=\(AppStorageKeys.rssActive)/\(subs.hasSubscriptions)")
                    if TabSelectionPolicy.shouldFallBackToHome(
                        selected: selectedMediaType,
                        masterEnabled: selectedMediaType.userMasterEnabled) {
                        Logger.library.notice("Y37 fallback → home (user deactivated \(selectedMediaType.rawValue, privacy: .public))")
                        navigationPath = NavigationPath()
                        selectedMediaType = .home
                    }
                }
            }
            .navigationTitle(Text(verbatim: barTitle))
            // Pin the LARGE display mode. Switching the dynamic
            // title on the live bar (tab change while scrolled) dropped the
            // title but kept its reserved space (probe-reproduced).
            .navigationBarTitleDisplayMode(.large)
            .toolbarTitleDisplayMode(.large)
            // The search page brings its own header (scope bar). The
            // nav bar with title + sort/settings yields while searching.
            .toolbar(isShowingSearch ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                // Our own adaptive glass instead of the system's toolbar
                // glass. The system one must be FULLY suppressed (shared
                // background hidden AND plain button style below), otherwise
                // both glasses stack: a dark doubled circle with a tinted
                // outline ring.
                // The sort/filter button is GONE from the tab
                // head. Sorting now sits at the surface it acts on (the "All
                // Books" grid, the podcast show grid, the album grid). The
                // gate that hid it on Home/Radio goes with it: there is
                // nothing left to hide. The cog keeps its position, so nothing
                // the user aims at moves.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        settingsLink
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        settingsLink
                    }
                }
            }
            // Programmatic push from the search overlay (book tap): the overlay
            // slides down and puts the item id on the path.
            .navigationDestination(for: String.self) { itemId in
                if let entry = viewModel.entries.first(where: { $0.id == itemId }) {
                    BookDetailScreen(entry: entry, coordinator: playerCoordinator, libraryViewModel: viewModel)
                }
            }
            // Podcast routes registered on the stack ROOT (not the podcast tab):
            // the Home tab now shows PodcastFeaturedCards whose info pill pushes a
            // PodcastRoute. Since the podcast tab may not be mounted yet, its
            // registration wasn't guaranteed to be in the hierarchy. A root-level
            // registration is always present and stays the single one for the type.
            .podcastNavigationDestinations(playerCoordinator: playerCoordinator)
            // Music routes on the same stack root. Music pushes must go
            // through `navigationPath` too (value-based), so a media-tab tap pops
            // album/artist pages back to the library. (Home shows album tiles as
            // well, so the registration belongs on the root, not the music tab.)
            .musicNavigationDestinations(playerCoordinator: playerCoordinator)
            // F4-discovery: radio genre drilldown on the same stack root.
            .radioNavigationDestinations(playerCoordinator: playerCoordinator)
            // A capped row's heading pushes its full list. The
            // destination is the SHARED BrowseBooksScreen. Same grid, same
            // cell, same paging behaviour as the browse surfaces.
            .navigationDestination(for: LibraryListRoute.self) { route in
                switch route {
                case .continueListening:
                    // Continue is a HOEREN page everywhere. The
                    // same compact grid with play-tap as Home's (F2: the page
                    // inherits the row's tap class; BrowseBooksScreen's cells
                    // are NACHSCHLAGEN and stay for Recently Added).
                    MixedMediaPage(route: .continueListening,
                                   continueIds: viewModel.continueListening.map(\.id),
                                   addedItems: [], musicProgress: [:],
                                   playerCoordinator: playerCoordinator,
                                   libraryViewModel: viewModel)
                case .recentlyAdded:
                    BrowseBooksScreen(
                        title: route.title,
                        entries: entries(for: route),
                        playerCoordinator: playerCoordinator,
                        libraryViewModel: viewModel
                    )
                case .allBooks:
                    // The full stock behind the preview (endless grid +
                    // the sort/filter control that moved with it).
                    AllBooksPage(viewModel: viewModel,
                                 playerCoordinator: playerCoordinator)
                }
            }
            .navigationDestination(for: FreeAudiobooksRoute.self) { route in
                switch route {
                case .area:
                    FreeAudiobooksPage(playerCoordinator: playerCoordinator)
                case .allPopular:
                    // Alias: the old full-list route lands on the source page.
                    CatalogSourcePage(source: .librivox, playerCoordinator: playerCoordinator)
                case .source(let source):
                    CatalogSourcePage(source: source, playerCoordinator: playerCoordinator)
                case .popular(let source):
                    CatalogPopularPage(source: source, playerCoordinator: playerCoordinator)
                case .shelf(let source, let key):
                    CatalogShelfPage(source: source, shelfKey: key,
                                     playerCoordinator: playerCoordinator)
                case .series(let itemId):
                    ArchiveSeriesPage(itemId: itemId,
                                      playerCoordinator: playerCoordinator)
                case .oerrCountries:
                    OERRCountriesPage()
                case .catalogBook(let itemId):
                    // The ONE audiobook detail page, catalog entrance. The
                    // mini sheet fell; every book surface pushes this page.
                    if let item = AppSession.shared.libraryItem(forId: itemId)
                        ?? AppSession.shared.playableItem(forId: itemId) {
                        BookDetailScreen(catalogItem: item, coordinator: playerCoordinator)
                    } else {
                        // A cold start with a stale route: honest state, no
                        // spinner that never ends.
                        ContentUnavailableView("This could not be loaded.",
                                               systemImage: "book.closed")
                    }
                }
            }
        }
        // Buttons inside List rows push routes over this callback instead of a
        // NavigationLink (which draws a disclosure chevron in a List). Set on
        // the NavigationStack ITSELF, not its root content. Pushed
        // destinations (the show page's episode rows) inherit the environment
        // only from here, not from a modifier on the root VStack.
        .environment(\.pushPodcastRoute) { navigationPath.append($0) }
        // Home tiles push book detail pages (String route) the same way.
        .environment(\.pushBookDetail) { navigationPath.append($0) }
        // The search deck's catalog tile pushes the merged area.
        .environment(\.pushFreeAudiobooksRoute) { navigationPath.append($0) }
        // Pushed detail pages (music album, podcast show) host the settings
        // cog themselves. The root toolbar's cog doesn't propagate. Set on the
        // NavigationStack itself so pushed destinations inherit it.
        .environment(\.openSettings) { showSettings = true }
        // Playlist cards (MediaTile onTap) push music routes through this.
        .environment(\.pushMusicRoute) { navigationPath.append($0) }
        // Teil 1: radio station rows/cards push the station detail page (variant
        // picker) from their context menu. The tap itself still plays.
        .environment(\.pushRadioRoute) { navigationPath.append($0) }
        // A push out of the search page's deck (grid cells navigate
        // value-based via NavigationLink) leaves search mode. The pushed
        // detail must get the normal bottom bar, not the search field.
        .onChange(of: navigationPath.count) { old, new in
            if isShowingSearch, new > old { closeSearch() }
        }
        // Bottom zone as an OVERLAY (reserves no space). The free space is
        // provided by the scroll contents themselves via `bottomBarClearance()`,
        // which also covers pushed screens (detail, podcast show) cleanly.
        .overlay(alignment: .bottom) {
            // Mini bar and search button in ONE row so the search button is never
            // shifted up just because the mini bar appears/disappears. Both stay
            // at the same height. Centrally above the whole NavigationStack so
            // both stay visible on every level (library AND book detail). Since
            // this row is structurally OUTSIDE the NavigationStack, the mini bar
            // cannot navigate via its own NavigationLink. Instead it hooks into
            // the stack's navigation path via a callback (see navigationPath
            // above). On the full player itself the whole row is hidden,
            // otherwise play/pause & co. would appear twice.
            if !isShowingFullPlayer {
                BottomBarCollapseReader { barCollapsed in
                bottomBarContent(collapsed: barCollapsed)
                // Slightly crisper collapse/expand spring (less floaty).
                // The mini-player keeps its matchedGeometry morph across it, the
                // extra rows cross-fade.
                // GT: gentler/slower bottom-bar collapse (was response 0.42).
                // Decouple (24.07): the top icons (`toolbarGlassIcon`) react to the
                // SAME `barCollapsed` flip immediately; the bar itself waits
                // `Self.barCollapseLag` on COLLAPSE only, so it visibly follows the
                // icons out instead of vanishing in the same frame. Expand (return
                // to rest) stays immediate. The primary surface should come back
                // promptly while the icons pop back in with their own bouncy spring.
                .animation(
                    barCollapsed
                        ? .spring(response: 0.55, dampingFraction: 0.85).delay(Self.barCollapseLag)
                        : .spring(response: 0.55, dampingFraction: 0.85),
                    value: barCollapsed)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                // The bar avoids the keyboard ONLY while the search field can
                // own one. That is the single reason the overlay ever wanted
                // the inset. Outside search a keyboard inset that hangs around
                // after dismissal (the screenshot class) lifted the whole bar
                // into the middle of the screen; ignoring the zone there means
                // a stuck inset has nothing to lift.
                .ignoresSafeArea(.keyboard, edges: isShowingSearch ? [] : .bottom)
                .task(id: playerCoordinator.activeItem?.id) {
                    let previousId = lastBottomAccentItemId
                    lastBottomAccentItemId = playerCoordinator.activeItem?.id
                    guard let item = playerCoordinator.activeItem else {
                        miniPlayerSwapOffset = 0
                        return
                    }
                    let coverURL = AppSession.shared.coverURL(forItemId: item.id)
                    // Real book SWITCH (not first appearance): dip the mini
                    // player below the screen, swap content + accent while it
                    // is hidden, then spring it back up. Masks the async
                    // accent load that used to pop the glass color hard.
                    guard let previousId, previousId != item.id else {
                        // First appearance (row insertion animates already):
                        // no dip, but clear any offset a cancelled swap left.
                        miniPlayerSwapOffset = 0
                        await bottomColorLoader.load(from: coverURL)
                        return
                    }
                    withAnimation(.easeIn(duration: 0.25)) {
                        miniPlayerSwapOffset = 160
                    }
                    await bottomColorLoader.load(from: coverURL)
                    // Hold below the edge for a beat even when the cover is
                    // cached (accent load would be instant → visible twitch).
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // Rapid double switch: a newer task owns the offset now.
                    // Springing up here would interrupt ITS dip mid-swap.
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        miniPlayerSwapOffset = 0
                    }
                }
            }
        }
        // Hoisted OUTSIDE the bottom row so the toolbar buttons (sort,
        // settings) inherit the same cover accent as the glass elements in
        // the bottom row. The detail page overrides it with its own loader.
        // The accent only ever changes COVER TO COVER. On an item
        // switch the old accent stands until the new one finished loading;
        // session end / pause / restore never reset it (hasAccent stays true,
        // and persists across restarts); neutral is only the first-run state
        // before anything ever played. The bar follows the SYSTEM appearance,
        // never the page (bar = app chrome; no page-driven forceDark).
        .environment(\.glassAccent, bottomColorLoader.hasAccent ? bottomColorLoader.accent : nil)
        // Pass the free-space height to ALL contents (also pushed screens); 0 on
        // the full player (it covers everything).
        // Constant reserve per composition (full player covers everything → 0;
        // mini-player mount is a REAL composition change and may adjust it.
        // Never `collapsed`/the morph).
        .environment(\.bottomBarInset,
                     isShowingFullPlayer ? 0 : BottomBarReserve.total(hasMiniPlayer: playerCoordinator.activeItem != nil))
        .task {
            // Series data lives here. Hand the coordinator a lookup for the
            // auto-play-next-in-series setting.
            playerCoordinator.nextInSeriesProvider = { [weak viewModel] itemId in
                viewModel?.nextInSeries(after: itemId)?.item
            }
            // X16b: a restart-from-0 clears the library's local 'finished' flag.
            playerCoordinator.onItemRestarted = { [weak viewModel] itemId in
                viewModel?.markUnfinishedLocally(itemId: itemId)
            }
            // Cover maintenance (TTL, size limit, orphaned persistent covers).
            ImageCache.shared.performMaintenance(
                activeDownloadIds: DownloadManager.shared.downloadedItemIds
            )
            // Download maintenance: repair wrong file extensions of all books.
            DownloadManager.shared.performMaintenance()
            // One-time: remove unreadable old files (auto-heal replaces them).
            DownloadManager.shared.performDeepValidation()
            if viewModel.entries.isEmpty {
                // Render the cached library IMMEDIATELY and
                // restore the mini-player from it. BEFORE the network load,
                // which then replaces everything silently.
                await viewModel.showCachedLibraryIfAvailable()
                await playerCoordinator.restoreLastSession(from: viewModel.entries)
                await viewModel.loadLibrary()
            }
            // Silently bring the last played book into the mini-player (no-op
            // when the cache-first path above already restored it).
            await playerCoordinator.restoreLastSession(from: viewModel.entries)
            // Cold start via quick action / Siri: the request arrived before
            // the library was loaded. Execute it now.
            await handlePendingResumeRequest()
            // If offline progress was left over last time (the app was closed
            // offline before the sync went through): flush it now.
            await SyncQueue.shared.flush(apiClient: provider)
            await BookmarkQueue.shared.flush(provider: provider)
            await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
            // Check whether the ABS server has podcast libraries → the podcast tab
            // appears even without local RSS subscriptions (1 request, no full load).
            await AppSession.shared.absPodcastProvider.refreshAvailability()
            // The quota watch stands BEFORE the services and does not
            // depend on any of them. It is the one place that asks why the
            // key-value store changed, and the case worth catching (the
            // channel fills because podcastProgress fills it) must not hang on
            // a service that may be switched off.
            CloudQuotaWatch.shared.start()
            // Reconcile podcast progress via iCloud (across devices).
            PodcastCloudSync.shared.start()
            ListeningStatsStore.shared.start()
            // Same switch, same store, same moment. The playlists travel with
            // the podcast progress or not at all.
            MaerPlaylistCloudSync.shared.start()
            // The travelling user choices (sorts, browse choices, favorites,
            // per-show settings, …). One mechanism, same switch.
            UserChoiceCloudSync.shared.start()
            // Takeover channel: who is playing what (self-pause + hint line).
            PlaybackClaimSync.shared.start()
            // One-off backfill. The addresses already
            // configured move into the register, so the memory is not empty
            // on the first launch after the update.
            KnownServers.backfill([
                (KeychainStore.load(forKey: KeychainKey.serverURL) ?? "", .audiobookshelf),
                (AppStorageKeys.subsonicServerURLValue, .subsonic),
                (AppStorageKeys.jellyfinServerURLValue, .jellyfin),
                (AppStorageKeys.gpodderServerURLValue, .gpodder),
                (PinchflatClient.serverURL?.absoluteString ?? "", .pinchflat),
            ].filter { !$0.0.isEmpty })
        }
        .fullScreenCover(isPresented: Binding(
            get: { driveMode.isActive },
            set: { if !$0 { driveMode.exit() } }
        )) {
            DriveModeView(coordinator: playerCoordinator, libraryViewModel: viewModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Drive mode idle-timer discipline: background always releases it.
            DriveModeController.shared.scenePhaseChanged(active: newPhase == .active)
            // When the app returns to the foreground, silently refresh the
            // progress bars. E.g. if listening continued on another device in
            // the meantime.
            if newPhase == .active {
                PodcastCloudSync.shared.reconcile()   // pull the iCloud podcast state
                // Recheck the active sources and reconnect silently.
                // An outage must never require a force-quit to recover.
                AppSession.shared.musicProvider.reconnectIfNeeded()
                Task {
                    if viewModel.isShowingOfflineCache, NetworkMonitor.shared.isConnected {
                        await viewModel.loadLibrary()   // leave the stale cache state
                    }
                    await viewModel.refreshProgress()
                    await handlePendingResumeRequest()
                }
                // A session that has run far past the cap gets a
                // pass at the next CALM moment. Enforcement no longer waits
                // for the next cold start, and never interrupts a scroll.
                if ImageCache.shared.needsUrgentMaintenance() {
                    BottomBarState.shared.runWhenCalm {
                        ImageCache.shared.performMaintenance(
                            activeDownloadIds: DownloadManager.shared.downloadedItemIds)
                    }
                }
            }
            // Offer the home-screen quick action for the last played book.
            if newPhase == .background {
                PodcastCloudSync.shared.reconcile()   // push the local state to iCloud
                updateQuickActions()
                // Re-run the cover-cache cap on backgrounding, not only at
                // launch. Otherwise a long session's cover growth stays uncapped
                // until the next cold start.
                ImageCache.shared.performMaintenance(
                    activeDownloadIds: DownloadManager.shared.downloadedItemIds
                )
            }
        }
        .onOpenURL { url in
            // Home-screen widget: maer://resume → resume path (like the quick
            // action / Siri).
            guard url.scheme == "maer" else { return }
            ResumeRequest.pending = true
            Task { await handlePendingResumeRequest() }
        }
        // Hiding a title from Continue takes effect at once. The
        // rows rebuild locally, and Home follows because its recompute token
        // watches the Continue count.
        .onReceive(NotificationCenter.default.publisher(for: .continueHiddenChanged)) { _ in
            Task { await viewModel.refreshContinueRows() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeLastBookRequested)) { _ in
            // Fires when the app was ALREADY running (no scene-phase change).
            Task { await handlePendingResumeRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .podcastNewEpisodesTapped)) { _ in
            Task { await handlePendingPodcastRequest() }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            // Covers the case that the app was open the whole time while the
            // connection returned. Without this trigger the "offline" hint would
            // wrongly stay, though there is network again.
            if isConnected && viewModel.isShowingOfflineCache {
                Task { await viewModel.loadLibrary() }
            }
            if isConnected {
                Task {
                    await SyncQueue.shared.flush(apiClient: provider)
                    await BookmarkQueue.shared.flush(provider: provider)
                    await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
                }
            } else {
                // Connection lost while possibly playing: set the sync status
                // visibly to "offline" immediately, without queueing anything.
                playerCoordinator.viewModel?.markConnectionLostWhilePlaying()
            }
        }
        .alert("Delete all downloads?", isPresented: $showDeleteAllDownloads) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded audiobooks will be removed from this device. Listening progress is kept.")
        }
        // Logout (manual or automatic on 401): end playback cleanly. The final
        // sync attempt lands in the queue with a dead token and is sent after the
        // next login; the lock-screen display is cleared.
        .onDisappear {
            playerCoordinator.viewModel?.stop()
        }
        // Settings modal. Its own NavigationStack, bottom zone set to 0 (no
        // mini-player in the sheet → no free-space reservation needed).
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(coordinator: playerCoordinator, libraryViewModel: viewModel, onLogout: onLogout)
            }
            .environment(\.bottomBarInset, 0)
        }
        // Up-Next home at the player: the queue sheet opened from the
        // mini-player long-press (the full player presents its own copy of the
        // same PlayQueueSheet). Root-level, so it works from every tab and
        // above any pushed detail page.
        .sheet(isPresented: $showQueueSheet) {
            PlayQueueSheet(playerCoordinator: playerCoordinator)
        }
        // Vollplayer → Quellseiten: registered on the ONE
        // central router. Environment wiring was fragile across player
        // presentation contexts (silent no-op when the env was missing).
        .onAppear {
            registerPlayerSourceRouter()
            #if DEBUG
            // Screenshot/diagnosis hook: jump straight into drive mode (the
            // -uitest seed provides the active player).
            if ProcessInfo.processInfo.arguments.contains("-uitest-drivemode") {
                DriveModeController.shared.enter()
            }
            if ProcessInfo.processInfo.arguments.contains("-uitest-fullplayer") {
                isShowingFullPlayer = true
            }
            #endif
        }
        // Full player as an overlay OVER the library (instead of push).
        .overlay {
            if isShowingFullPlayer {
                // Read the insets here (normal safe-area context) and pass them
                // explicitly. The overlay itself ignores safe areas at the root.
                GeometryReader { proxy in
                    FullPlayerOverlay(
                        coordinator: playerCoordinator,
                        topInset: proxy.safeAreaInsets.top,
                        bottomInset: proxy.safeAreaInsets.bottom,
                        presentHeight: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                    ) {
                        // The sheet is already down here. Just fade the mini bar in.
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                            isShowingFullPlayer = false
                        }
                    }
                }
                // No .move transition: slide in/out runs via the offset in the
                // overlay (interruptible, can no longer get stuck).
                .transition(.identity)
            }
        }
    }

    /// Gate 2: the ONE navigation handler for full-player → source-page taps.
    /// The player MINIMIZES (never stops) and the target page is pushed on
    /// the library stack in the matching tab, through the SAME value routes
    /// the global search uses. Log-first: paired with the tap/route logs in
    /// PlayerView/PlayerSourceRouter this shows on-device where a dead tap
    /// dies (handler fires vs. never called).
    private func registerPlayerSourceRouter() {
        PlayerSourceRouter.shared.handler = { target in
            Logger.library.notice("PLAYERSOURCE handling target in LibraryView")
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                isShowingFullPlayer = false
            }
            if isShowingSearch { closeSearch() }
            switch target {
            case .book(let itemId):
                selectedMediaType = .audiobooks
                navigationPath.append(itemId)
            case .podcastShow(let feedURL):
                selectedMediaType = .podcasts
                navigationPath.append(PodcastRoute.show(feedURL: feedURL))
            case .podcastEpisode(let itemId):
                selectedMediaType = .podcasts
                navigationPath.append(PodcastRoute.episode(itemId: itemId))
            case .podcastLatest:
                selectedMediaType = .podcasts
                navigationPath.append(PodcastRoute.latestAll)
            case .musicAlbum(let item):
                selectedMediaType = .music
                navigationPath.append(MusicRoute.album(item))
            case .musicArtist(let artist):
                selectedMediaType = .music
                navigationPath.append(MusicRoute.artist(artist))
            case .radioStation(let station):
                selectedMediaType = .radio
                navigationPath.append(RadioRoute.station(station))
            case .catalogAlbum(let itemId):
                selectedMediaType = .music
                navigationPath.append(MusicRoute.catalogAlbum(itemId))
            }
        }
    }

    // MARK: - Bottom zone (scroll-driven collapsible)

    /// Expanded: banner · mini-player (full) · [media pill | search].
    /// Compact: one row [home button · mini-player centered, smaller · search].
    /// ONE container for both states, with the mini-player in the SAME
    /// structural slot. Collapsing animates its real frame (the bar visibly
    /// travels into the compact row) instead of the crossfade a branch swap
    /// (`if collapsed { HStack } else { VStack }`) produced. The media pill
    /// morphs into the home button and the search button glides via
    /// matchedGeometry as before. No extra work at scroll start: the collapse
    /// now removes fewer views than the old full-branch swap.
    private func bottomBarContent(collapsed: Bool) -> some View {
        bottomBarStack(collapsed: collapsed).bottomGlassContainer()
    }

    private func bottomBarStack(collapsed barCollapsed: Bool) -> some View {
        VStack(spacing: 8) {
            // The field sits where the tab pill was, the tab
            // bar yields to the round home button (like the collapsed state).
            // Focused: mini player + home button step aside, only the search
            // pill stays above the keyboard, trailing where the magnifier sat.
            if isShowingSearch {
                // ONE structural slot for the field across the focus flip.
                // A branch swap would tear the focused TextField down and drop
                // the keyboard (the N2 identity lesson). Y19: focused, the
                // home button steps aside and the field takes the full width;
                // the X lives in its OWN round glass button (Y24: house →
                // Home, X → close).
                if !searchFieldFocused { miniPlayer(collapsed: barCollapsed) }
                HStack(spacing: 8) {
                    if !searchFieldFocused { homeButton }
                    bottomSearchField
                    searchCloseButton
                }
            } else {
            let composedCollapsed = barCollapsed
            if !composedCollapsed { banner }
            HStack(spacing: 8) {
                if composedCollapsed { homeButton }
                miniPlayer(collapsed: barCollapsed)
                if composedCollapsed { searchButton }
            }
            if !composedCollapsed {
                HStack(spacing: 10) {
                    mediaBar
                    Spacer(minLength: 0)
                    searchButton
                }
            }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        // Coordinator-level load errors ("Offline — not downloaded") appear
        // HERE too. The player screen that also renders them may not be
        // mounted when a tap on an unavailable title is rejected.
        if let error = playerCoordinator.loadError {
            Label(error, systemImage: "wifi.slash")
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(AdaptiveGlassBackground(shape: Capsule()))
                .task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    playerCoordinator.loadError = nil
                }
                .onTapGesture { playerCoordinator.loadError = nil }
        }
        if let vm = playerCoordinator.viewModel, vm.sourceHint != nil {
            ResumeMessageBanner(viewModel: vm)
        }
    }

    @ViewBuilder
    private func miniPlayer(collapsed barCollapsed: Bool) -> some View {
        if let vm = playerCoordinator.viewModel, let item = playerCoordinator.activeItem {
            MiniPlayerBar(
                coordinator: playerCoordinator, viewModel: vm, item: item,
                compact: barCollapsed,
                onOpenPlayer: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        isShowingFullPlayer = true
                    }
                },
                glassMorphID: "player", glassMorphNamespace: bottomGlassNS)
            // Up-Next entry from EVERY tab: long-press on the mini player (tap
            // keeps opening the full player). A context menu adds no glass
            // surface and no layout change. The fresh GlassEffectContainer/
            // glassEffectID morph structure stays untouched.
            .contextMenu {
                Button {
                    showQueueSheet = true
                } label: {
                    Label("Up Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                // Locale-independent handle for the UI-test harness.
                .accessibilityIdentifier("mini-queue-entry")
            }
            .offset(y: miniPlayerSwapOffset)
            .matchedGeometryEffect(id: "player", in: barNS)
        }
    }

    @ViewBuilder
    private var mediaBar: some View {
        if availableMediaTypes.count > 1 {
            MediaTabBar(
                types: availableMediaTypes, selected: selectedMediaType,
                onSelect: { newValue in
                    navigationPath = NavigationPath()
                    BottomBarState.shared.reset()   // switching tabs expands the bar
                    withAnimation(.snappy(duration: 0.2)) { selectedMediaType = newValue }
                },
                glassMorphID: "media", glassMorphNamespace: bottomGlassNS)
            .matchedGeometryEffect(id: "media", in: barNS)
        }
    }

    /// Compact "Home" button (morphed from the media pill). Expands the bar
    /// again (until the next scroll).
    private var homeButton: some View {
        Button {
            // Home = back to the library root (pops any pushed detail page) AND
            // expand the bar again. Y17: in search mode it also closes the
            // search and returns to the Home tab.
            if isShowingSearch {
                closeSearch()
                withAnimation(.snappy(duration: 0.2)) { selectedMediaType = .home }
            }
            navigationPath = NavigationPath()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                BottomBarState.shared.expand()
            }
        } label: {
            // Collapsed bar shows the ACTIVE tab's symbol; tapping only expands
            // the bar (never switches tab). Symbol changes with the tab.
            // Only THIS changing glyph is larger. Circle, magnifier and
            // every other glyph keep their sizes.
            // In search mode the button MEANS "to the Home tab". It
            // shows the house, whatever tab the search was opened from.
            Image(systemName: isShowingSearch ? MediaType.home.systemImage : selectedMediaType.systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(
            shape: Circle(), tier: .glass,
            morphID: "media", morphNamespace: bottomGlassNS))
        .matchedGeometryEffect(id: "media", in: barNS)
        .accessibilityLabel(isShowingSearch ? MediaType.home.label : selectedMediaType.label)
        .accessibilityHint(Text("Expands the bar"))
    }

    /// Value-based navigation per result type (X15 discipline). Every
    /// push goes through `navigationPath`.
    private func openSearchResult(_ result: SearchResult) {
        switch result.kind {
        case .book:
            navigationPath.append(result.id)
        case .episode:
            navigationPath.append(PodcastRoute.episode(itemId: result.id))
        case .show:
            navigationPath.append(PodcastRoute.show(feedURL: result.id))
        case .catalogShow:
            navigationPath.append(PodcastRoute.show(feedURL: result.id))
        case .catalogBook:
            // NACHSCHLAGEN. The existing detail sheet with the prominent
            // Play (the item was remembered by the search fan-out). OTR-class
            // items get their show page like everywhere else.
            if FreeCatalogProvider.shared.hasPartsList(itemId: result.id) {
                navigationPath.append(FreeAudiobooksRoute.series(itemId: result.id))
            } else if let item = FreeCatalogProvider.shared.libraryItem(forId: result.id) {
                navigationPath.append(FreeAudiobooksRoute.catalogBook(itemId: item.id))
            } else {
                searchResultUnavailable()
            }
        case .album:
            if let item = AppSession.shared.libraryItem(forId: result.id) {
                navigationPath.append(MusicRoute.album(item))
            } else {
                searchResultUnavailable()
            }
        case .playlist:
            // Playlist detail = the SAME MusicRoute.album path the F5
            // cards push (playlist item id; no second detail mechanism).
            if let item = AppSession.shared.libraryItem(forId: result.id) {
                navigationPath.append(MusicRoute.album(item))
            } else {
                searchResultUnavailable()
            }
        case .artist:
            let music = AppSession.shared.musicProvider
            if let rawId = music.artistId(fromItemId: result.id),
               let artist = music.artist(forId: rawId) {
                navigationPath.append(MusicRoute.artist(artist))
            } else {
                searchResultUnavailable()
            }
        case .song:
            if let item = AppSession.shared.libraryItem(forId: result.id) {
                Task { await playerCoordinator.open(item: item) }
            } else {
                searchResultUnavailable()
            }
        case .radioStation:
            // Play replaces the active playback. Stations never route
            // into a detail page or the queue.
            if let item = AppSession.shared.libraryItem(forId: result.id) {
                Task { await playerCoordinator.open(item: item) }
            } else {
                searchResultUnavailable()
            }
        case .author, .series:
            break   // drill down inside the overlay, never routed out
        }
    }

    /// F6 follow-up: a music hit that no longer resolves must not
    /// die silently. Brief haptic + the existing transient banner.
    private func searchResultUnavailable() {
        Haptics.tap()
        playerCoordinator.loadError = String(localized: "This result is no longer available.")
    }

    /// The bottom search field (iOS 26 pattern). Morphs from the
    /// magnifier (same matchedGeometry id). Y19: always full width; the X
    /// lives in its own round glass button next to it, never inside.
    private var bottomSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $searchModel.query, prompt: Text("Search everything"))
                .focused($searchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .modifier(AdaptiveGlassBackground(
            shape: Capsule(), tier: .glass,
            morphID: "search", morphNamespace: bottomGlassNS))
        .matchedGeometryEffect(id: "search", in: barNS)
        .accessibilityIdentifier("global-search-field")
    }

    /// The round glass X. Clears a typed query first, a second tap
    /// (or an empty field) closes the search.
    private var searchCloseButton: some View {
        Button {
            if !searchModel.query.isEmpty {
                searchModel.query = ""
            } else {
                closeSearch()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(
            shape: Circle(), tier: .glass,
            morphID: "close", morphNamespace: bottomGlassNS))
        .accessibilityLabel(Text("Close search"))
        .accessibilityIdentifier("search-close")
    }

    private func closeSearch() {
        searchFieldFocused = false
        searchModel.query = ""
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = false }
    }

    private var searchButton: some View {
        FloatingSearchButton(
            action: {
                searchModel.query = ""
                // The scope starts where the user is (Home → Library).
                searchScope = SearchScope.initial(for: selectedMediaType)
                // Release-Gate 1: the search page lives on the
                // library ROOT. Opened from a pushed detail page it sat
                // INVISIBLY underneath it (field in the bottom bar worked,
                // results never showed). Pop to root first; Y24 already
                // closes the search on any push, so root-only is the
                // consistent home of the search.
                navigationPath = NavigationPath()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = true }
            },
            glassMorphID: "search", glassMorphNamespace: bottomGlassNS)
        .matchedGeometryEffect(id: "search", in: barNS)
        .accessibilityLabel(Text("Search"))
        // Locale-independent handle for the UI-test harness.
        .accessibilityIdentifier("global-search")
    }

    // MARK: - Suchleiste

    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("Offline — last known state")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    // MARK: - Inhalt

    /// Store feeds the tab tile row (fill via Home's compute pass).
    @ObservedObject private var freeCatalogStore = FreeCatalogStore.shared

    /// The row's own key rides as @AppStorage so a settings flip
    /// re-renders the tab live (a plain UserDefaults read would not
    /// invalidate).
    @AppStorage(AppStorageKeys.freeAudiobooksEnabled) private var catalogRowVisible = true
    @AppStorage(AppStorageKeys.rowBooksRecentVisible) private var recentRowVisible = true

    /// Two honest questions instead of three levels: is the row visible,
    /// and is any of its sources allowed. A row whose every source is off
    /// hides here rather than standing empty.
    private var freeAudiobooksArea: Bool {
        catalogRowVisible
            && (AppStorageKeys.librivoxActive || AppStorageKeys.gutenbergSourceActive
                || AppStorageKeys.archiveBooksActive)
    }

    /// The tile ROW above "All Books". Linked title into the area
    /// page, "New at LibriVox" tiles (MediaTile format, tap plays, context
    /// menu opens the license sheet), catalog≠library marking kept. The row
    /// hides entirely while the store is empty (service/toggle off, offline).
    /// This row shows the CATALOGUES. LibriVox,
    /// Project Gutenberg, Internet Archive and Old Time Radio, mixed. No feed
    /// tile: a feed lands in the podcast tab as a subscription.
    ///
    /// Old Time Radio moved here on the measurement, not on taste: the most
    /// downloaded bundles are played SERIES with a beginning, an end and a
    /// listening position (`MediaFamily.booksTabMember` files them here
    /// already). The browsing door now follows the filing that existed.
    ///
    /// It also ends four surfaces drawing from two pots: the row used to draw
    /// `rows.tabBooks`, which comes from the same query as the popular lane
    /// and from the same `docs` array as Start's `discoverBooks`.
    @ViewBuilder
    private var freeAudiobooksSection: some View {
        let tiles = CatalogMix.tiles(for: .books, rows: freeCatalogStore.sourceRows)
        // No heading without content. The row hides entirely while the
        // catalogues are empty (service off, offline, still loading).
        if !tiles.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
            // Hand-built copy of RowHeading's chevron
            // branch → the shared entry variant.
            RowHeading.entry("Audiobooks and Radio Plays", destination: FreeAudiobooksRoute.area)
                .accessibilityIdentifier("free-audiobooks-entry")
            // The word "free" is gone from these headings: it is a legal
            // claim, and the per-title capsule is where the rights situation
            // belongs. Naming the ORIGIN says as much without claiming.
            Text("From open catalogs — LibriVox, Project Gutenberg, Internet Archive and Old Time Radio. Separate from your own library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            CatalogMixRow(tiles: tiles, playerCoordinator: playerCoordinator)
        }
        .task { await freeCatalogStore.ensureSourcesLoaded() }
        } else {
            Color.clear.frame(height: 0)
                .task { await freeCatalogStore.ensureSourcesLoaded() }
        }
    }

    /// Audiobook tab. The library states used to be decided for the WHOLE
    /// tab, so an unreachable or empty server hid the free-catalogue row with
    /// it. The same hostage structure the music tab carried. The scroll
    /// always renders now; the LIBRARY section carries its own three states
    /// inside `content`.
    @ViewBuilder
    private var audiobooksContent: some View {
        content
    }

    /// Serverless: the way to files on this device. A section, not a buried
    /// settings row.
    private var localFilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeading.plain("Local Files")
            NavigationLink {
                LocalFilesView()
            } label: {
                Label("Files on this device", systemImage: "folder")
                    .padding(.horizontal)
            }
        }
    }

    /// The library section's own three states. Inline, each with a way out.
    @ViewBuilder
    private var librarySectionState: some View {
        if viewModel.isLoading && viewModel.entries.isEmpty {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
            VStack(spacing: 12) {
                Text(error).multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await viewModel.loadLibrary() }
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else if viewModel.entries.isEmpty {
            // Connected, but the server has no books (yet).
            ContentUnavailableView {
                Label("No Audiobooks", systemImage: "books.vertical")
            } description: {
                Text(viewModel.isShowingOfflineCache
                    ? String(localized: "Offline — no books are downloaded.")
                    : String(localized: "Your library is empty. Add audiobooks via the Audiobookshelf web interface."))
            } actions: {
                Button("Refresh") {
                    Task { await viewModel.loadLibrary() }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                if !viewModel.continueListening.isEmpty {
                        continueFeaturedSection
                    }
                    if !viewModel.downloadedEntries.isEmpty {
                        downloadedSection
                    }
                    if recentRowVisible, !viewModel.recentlyAdded.isEmpty {
                        recentlyAddedGrid
                    }
                // The Free-Audiobooks tile row sits ABOVE "All Books".
                // Below it, the entry drowned behind the whole library
                // scroll. Above the fold the row always materializes, so the
                // lazy rule does not bite; the FILL still comes
                // from the one central compute() pass (shared store).
                // 🔴 A doubted session says so HERE. The tab keeps
                // its content (the token is intact, the server is merely
                // unreachable), and the line names the state instead of the
                // library silently looking empty.
                AbsSessionStateBanner()
                if !AppSession.shared.authViewModel.isLoggedIn {
                    // Serverless: the free area IS the tab's core.
                    // The page's sections, embedded (one parameterised
                    // version, no drifting copy), plus local files as their
                    // own section. No server sentence renders here (G8):
                    // there is no server to speak about.
                    FreeAudiobooksPage(playerCoordinator: playerCoordinator, embedded: true)
                    localFilesSection
                    if !viewModel.entries.isEmpty {
                        allBooksSection
                    }
                } else {
                    if freeAudiobooksArea {
                        freeAudiobooksSection
                    }
                    // The library's loading/error/empty state sits WHERE the
                    // library renders. The catalogue row above and the
                    // sections below stay standing whatever the server says.
                    librarySectionState
                    if !viewModel.entries.isEmpty {
                        allBooksSection
                    }
                }
                if viewModel.isLoadingMore {
                    // Progressive loading is still running. Subtle hint that
                    // more titles are on the way.
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading more…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            // Force full width explicitly. Without it the stack's width follows
            // its content instead of the actually available screen width, which
            // could lead to a circular reference with the grid inside.
            .frame(maxWidth: .infinity)
            .padding(.top, TabContentLayout.topInset)
            // Free space as INNER padding: the ScrollView stays full-bleed,
            // content keeps scrolling behind the glass but rests above the bottom
            // zone (no black area behind the mini-player).
            .bottomBarClearance()
        }
        // The refreshable closure must return promptly or the indicator can
        // stick. Kick the full reload as a background task (its progressive UI
        // shows the rest via the loading-more footer / silent replace) and only
        // hold the spinner for a short, bounded moment.
        .refreshable {
            let work = Task { await viewModel.loadLibrary() }
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = work   // keep running detached from the refresh gesture
        }
        // Subtle feedback while a background reload runs with content on
        // screen. Floats over the content, so no layout shift.
        .overlay(alignment: .top) {
            if viewModel.isRefreshing && !viewModel.entries.isEmpty {
                RefreshActivityPill()
            }
        }
        // Only the visible tab reports. Hidden-but-mounted tabs must not feed
        // the shared BottomBarState (see reportsBottomBarScroll(active:)).
        .reportsBottomBarScroll(active: selectedMediaType == .audiobooks)
    }

    // MARK: "Recently Added" (large tiles, side-scrolling)

    private var recentlyAddedGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeading(title: "Recently Added",
                       total: viewModel.recentlyAdded.count,
                       shown: RowPreview.cut(viewModel.recentlyAdded).count,
                       destination: LibraryListRoute.recentlyAdded)
            ScrollView(.horizontal, showsIndicators: false) {
                // Eager HStack: the lazy variant froze the shelf height on the
                // first measured cell and clipped taller cells' last text line.
                HStack(alignment: .top, spacing: 16) {
                    // This row was the last uncapped one in the tab.
                    ForEach(RowPreview.cut(viewModel.recentlyAdded)) { entry in
                        BookGridCell(entry: entry, width: 180,
                                     playerCoordinator: playerCoordinator, libraryViewModel: viewModel)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: "Continue" (large cards, like the podcast tab)

    private var continueFeaturedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The row is a PREVIEW. Capped, and the chevron
            // appears only when something is actually hidden behind it.
            RowHeading(title: "Keep Listening", font: .title2,
                       total: viewModel.continueListening.count,
                       shown: RowPreview.cut(viewModel.continueListening).count,
                       destination: LibraryListRoute.continueListening)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(RowPreview.cut(viewModel.continueListening)) { entry in
                        BookFeaturedCard(entry: entry,
                                         playerCoordinator: playerCoordinator,
                                         libraryViewModel: viewModel)
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        // Precompute the card accents (same pattern as the podcast tab).
        // Cards color on first render instead of flashing the neutral base.
        .task(id: viewModel.continueListening.map(\.id).joined()) {
            for entry in viewModel.continueListening {
                await CoverColorLoader.prewarm(url: AppSession.shared.coverURL(forItemId: entry.id))
            }
        }
    }

    // MARK: Downloaded (vertical list. Mirrors the podcast Downloaded pendant)

    /// Same layout/behaviour as the podcast Downloaded list: a vertical, capped
    /// (3 iPhone / 6 iPad) list of `BookDownloadRow`s (shared `MediaRowContent`),
    /// tap opens the detail page, with a storage/size menu and Show All toggle.
    private var downloadedSection: some View {
        let entries = viewModel.downloadedEntries
        let limit = horizontalSizeClass == .regular ? 6 : 3
        let shown = downloadedExpanded ? entries : Array(entries.prefix(limit))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Deliberately NOT RowHeading: this heading shares a padded
                // line with the size menu and the expand button. The
                // component's own horizontal padding would double up here.
                Text("Downloaded").font(.title3).bold()
                Menu {
                    Button(role: .destructive) {
                        showDeleteAllDownloads = true
                    } label: {
                        Label("Delete All Downloads", systemImage: "trash")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(ByteCountFormatter.string(
                            fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file))
                        Image(systemName: "ellipsis.circle")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if entries.count > limit {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { downloadedExpanded.toggle() }
                    } label: {
                        Text(downloadedExpanded
                             ? String(localized: "Show Less")
                             : String(localized: "Show All (\(entries.count))"))
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(shown) { entry in
                    BookDownloadRow(entry: entry, playerCoordinator: playerCoordinator,
                                    libraryViewModel: viewModel)
                }
            }
        }
    }

    // MARK: All Books

    /// The tab shows a PREVIEW (9 tiles, counted chevron WITH the total:
    /// "All Books · 221 ›"); the endless grid + sort/filter control moved to
    /// `AllBooksPage` behind it. This drops the last "the section IS the full
    /// list" exception. Every tab root is previews now. A cap would make
    /// books unreachable; the page behind the chevron answers that: the page
    /// exists, the chevron counts.
    ///
    /// Count rule: `total` is the WHOLE stock, `shown` the preview's books.
    /// So a persisted filter with zero hits still leaves the chevron (the way
    /// to the control on the page), and a small library (≤ 9)
    /// drops it by pure counting, no special case.
    private var allBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The head carries the active filter and the FILTERED count:
            // a filtered surface must never look like the full stock.
            RowHeading(title: "", verbatimTitle: FilteredHead.title(
                           String(localized: "All Books"),
                           filterLabel: SortIndicator.part(viewModel.filterOption.label,
                                                           ifNot: viewModel.filterOption == .alle)),
                       total: viewModel.sortedFilteredEntries.count,
                       shown: allBooksPreviewShown,
                       showsTotal: true,
                       destination: LibraryListRoute.allBooks)
            AudiobookStockGrid(viewModel: viewModel,
                               playerCoordinator: playerCoordinator,
                               limit: allBooksPreviewLimit)
            // The line NAVIGATES to the full page (with its sorting
            // and filters) instead of unfolding a second, poorer copy of it.
            // Both entries stay: chevron above, line below. Otherwise you
            // scroll back up to reach the page. G8 unchanged: the line only
            // exists when there is more than the preview shows.
            ShowAllRow(total: viewModel.sortedFilteredEntries.count,
                       hasMore: allBooksHasMore,
                       destination: LibraryListRoute.allBooks,
                       accessibilityId: "all-books-show-all")
        }
    }

    /// No expansion step here any more. The preview is 24, and
    /// everything beyond it lives on the page.
    private var allBooksPreviewLimit: Int { AudiobookStockGrid.previewLimit }

    /// Books visible in the preview window (a series stack counts its members).
    private var allBooksPreviewShown: Int {
        if viewModel.sortOption == .serie {
            return AudiobookStockGrid.previewBookCount(viewModel.seriesGroupedEntries,
                                                       limit: allBooksPreviewLimit)
        }
        return min(allBooksPreviewLimit, viewModel.sortedFilteredEntries.count)
    }

    /// Is there anything left to unfold? Counted the way the GRID counts
    /// (a series stack is one cell but several books), so the line never
    /// promises a "more" that would unfold into the same picture.
    private var allBooksHasMore: Bool {
        if viewModel.sortOption == .serie {
            return viewModel.seriesGroupedEntries.count > allBooksPreviewLimit
        }
        return viewModel.sortedFilteredEntries.count > allBooksPreviewShown
    }

    // MARK: Resume from outside (quick action / Siri)

    /// Executes a pending "continue listening" request (home-screen quick
    /// The tap on a new-episode message, carried out where tab and navigation
    /// path live.
    ///
    /// The show page resolves its show from the subscriptions, and on a cold
    /// launch those are not loaded yet. Without the wait the page would show
    /// "Show unavailable" for a show the reader has been subscribed to for
    /// months. Same reason the player and CarPlay await this.
    private func handlePendingPodcastRequest() async {
        guard let target = PodcastOpenRequest.pending else { return }
        PodcastOpenRequest.pending = nil
        await PodcastSubscriptions.shared.ensureLoaded()
        // Through the ONE navigation point, not past it. It also lowers the
        // full player and closes the search, which a jump from outside needs
        // just as much as a jump from the player.
        switch target {
        case .show(let feedURL): PlayerSourceRouter.shared.handler?(.podcastShow(feedURL: feedURL))
        case .latestEpisodes:    PlayerSourceRouter.shared.handler?(.podcastLatest)
        }
    }

    /// action or Siri shortcut): open the last played book and play.
    private func handlePendingResumeRequest() async {
        // Siri "Play <book>": a specific book beats "continue last".
        if let itemId = ResumeRequest.pendingItemId {
            ResumeRequest.pendingItemId = nil
            ResumeRequest.pending = false
            if let item = item(forId: itemId) {
                await playerCoordinator.open(item: item)
            }
            return
        }
        guard ResumeRequest.pending else { return }
        ResumeRequest.pending = false
        // Already active (e.g. paused in the mini player): just play.
        if let vm = playerCoordinator.viewModel {
            await vm.playWithServerCheck()
            return
        }
        guard let lastId = UserDefaults.standard.string(forKey: AppStorageKeys.lastPlayedItemId),
              let item = item(forId: lastId) else { return }
        await playerCoordinator.open(item: item)
    }

    /// Item for an id across sources (audiobook list OR podcast provider). For
    /// resume/quick-action/Siri.
    private func item(forId id: String) -> LibraryItem? {
        viewModel.entries.first(where: { $0.id == id })?.item
            ?? AppSession.shared.libraryItem(forId: id)
    }

    /// Registers the dynamic home-screen quick action with the current
    /// book's title as subtitle (or removes it without a last book).
    private func updateQuickActions() {
        guard let lastId = UserDefaults.standard.string(forKey: AppStorageKeys.lastPlayedItemId),
              let lastItem = item(forId: lastId) else {
            UIApplication.shared.shortcutItems = []
            return
        }
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: ResumeRequest.quickActionType,
                localizedTitle: String(localized: "Continue Listening"),
                localizedSubtitle: lastItem.title,
                icon: UIApplicationShortcutIcon(systemImageName: "play.fill")
            )
        ]
    }



    private var settingsLink: some View {
        Button {
            showSettings = true
        } label: {
            toolbarGlassIcon("gearshape")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Settings"))
        // Locale-independent handle for the UI-test harness.
        .accessibilityIdentifier("open-settings")
    }

    /// Toolbar icon on our OWN adaptive glass circle, treated EXACTLY like
    /// every other glass element (mini player, search button): shared cover
    /// accent in light mode, dark glass in dark mode.
    ///
    /// Toolbar content runs in its OWN environment that does not reliably
    /// carry our values (color scheme reported dark in light mode → black
    /// glass with white icon; `\.glassAccent` absent; menu labels tinted
    /// with the app accent → orange symbol). Everything the glass and icon
    /// need is therefore pinned/passed EXPLICITLY here.
    private func toolbarGlassIcon(_ systemName: String) -> some View {
        // The icon is the OTHER render site of `collapsed`. It observes via
        // its own reader leaf, so the flip never touches the tab container.
        BottomBarCollapseReader { barCollapsed in
        Image(systemName: systemName)
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .modifier(AdaptiveGlassBackground(
                shape: Circle(),
                tier: .glass,
                lightAccent: bottomColorLoader.hasAccent ? bottomColorLoader.accent : nil
            ))
            .environment(\.colorScheme, systemColorScheme)
            // Menu renders its label via tint (ignoring foregroundStyle).
            .tint(.primary)
            // 3c/GT3b: sort + settings (both via here) SCROLL UP out of frame
            // when the bottom bar collapses (scrolling) and POP back in at rest.
            // Same `barCollapsed` trigger (3b consistency). `opacity 0` while out
            // drops the glass render (hitch relief).
            // Hitch-rest H1: dampingFraction 0.62 → 0.9. The under-damped
            // spring OVERSHOT (forth-then-back); anything sharing its
            // transaction window at the collapse flip wiggled with it (the
            // grid's micro back-and-forth at the 60 pt threshold). 0.9 keeps a
            // slight pop-in without overshoot.
            .offset(y: barCollapsed ? -72 : 0)
            .opacity(barCollapsed ? 0 : 1)
            .allowsHitTesting(!barCollapsed)
            .animation(.spring(response: 0.35, dampingFraction: 0.9),
                       value: barCollapsed)
        }
    }

    /// The full list behind a capped row. Read live from the view
    /// model, so the page tracks the same source its preview row does.
    private func entries(for route: LibraryListRoute) -> [LibraryEntry] {
        switch route {
        case .continueListening: viewModel.continueListening
        case .recentlyAdded:     viewModel.recentlyAdded
        // .allBooks renders AllBooksPage (grid follows the live sort state
        // itself). Never reaches this list helper.
        case .allBooks:          []
        }
    }

}

extension View {
    /// Visibility of a kept-alive tab: hidden tabs stay mounted (state/tasks
    /// survive) but are invisible, untouchable and hidden from VoiceOver.
    func tabVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}
