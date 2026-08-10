// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit
import OSLog

struct LibraryView: View {
    // Process-wide instances (AppSession) instead of own @StateObjects — the
    // CarPlay scene shares the player and library with the UI.
    @ObservedObject private var viewModel: LibraryViewModel
    @ObservedObject private var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    /// Observe subscriptions so the podcast tab appears/disappears immediately.
    @ObservedObject private var podcastSubs = PodcastSubscriptions.shared
    /// Y37: observe the source configuration — `availableMediaTypes` reads
    /// `isAvailable` per render, so the tab bar follows every toggle live
    /// (Subsonic reloadConfig, ABS-podcast probe) in BOTH directions.
    @ObservedObject private var session = AppSession.shared
    @State private var isShowingSearch = false
    /// Y17: the search field lives in the BOTTOM bar; bar and search page
    /// share this model (the page renders, the bar types).
    @StateObject private var searchModel = GlobalSearchModel.production()
    @FocusState private var searchFieldFocused: Bool
    /// Y20: single-select scope of the search page — starts at the opening
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
    /// `glassEffectID` in this namespace — media pill ↔ home button, magnifier ↔
    /// search field — instead of cross-fading independent glass surfaces.
    @Namespace private var bottomGlassNS
    // Drive mode: rare-flip state (enter/exit only, never during a gesture)
    // — observing it here does NOT violate the leaf convention, and the
    // fullScreenCover trigger needs the re-render. While active, the library
    // is covered anyway.
    @ObservedObject private var driveMode = DriveModeController.shared
    // HITCH ROOT (26.07): LibraryView must NOT observe BottomBarState — it
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
    /// D4/B3: fixed-width carousel tiles get extra text lines at accessibility
    /// sizes instead of truncating titles to fragments.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Cover accent of the ACTIVE book — shared with every glass element in
    /// the bottom bar (mini player, search button, pill) via environment.
    // X24: the bar accent persists across sessions — it only ever changes
    // cover-to-cover (see the environment wiring below).
    @StateObject private var bottomColorLoader = CoverColorLoader(persistenceKey: AppStorageKeys.bottomBarAccent)
    /// Book-switch swap animation of the mini player (pushed below the
    /// screen while the new accent loads, then springs back up).
    @State private var miniPlayerSwapOffset: CGFloat = 0
    @State private var lastBottomAccentItemId: String?
    // ARCHITECTURE (25.07): the bottom clearance is the CONSTANT
    // `BottomBarReserve` — the whole live-measurement path (GeometryReader,
    // bottomBarHeight state, settle-debounce, fire-time re-validation) is
    // GONE; the bar cannot perturb scroll geometry by construction.
    /// Settings as a modal sheet (NOT pushed onto the library stack) — otherwise
    /// the mini-player overlay lies over it and its media pills trigger a jump
    /// back to the library from within the settings.
    @State private var showSettings = false
    /// Active content-type tab. Today audiobooks only; the bottom tab bar only
    /// appears when a second source brings a different type.
    @State private var selectedMediaType: MediaType = .home
    // Teil 2: per-tab sort/filter, shared with the tab content via the same
    // AppStorage keys (audiobooks keep using LibraryViewModel's own state).
    // fb21fbd: the podcast/music sort state no longer lives here — it moved to
    // the surfaces that own it (PodcastsView, MusicAlbumsPage). LibraryView
    // used to hold it only because the toolbar button sat here. Persistence and
    // the keys are unchanged, so the stored preference survives the move.
    /// Downloaded shelf expanded past its capped count (F6/G19).
    @State private var downloadedExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Tabs that have been shown at least once — they stay mounted (hidden)
    /// afterwards so their state/tasks survive switching. Never-visited tabs
    /// aren't mounted at all (no startup cost for the podcast/music chain).
    @State private var mountedTabs: Set<MediaType> = [.home]
    /// df69f6b DAMPING (accepted interim, NOT a root fix — FB18304716 family:
    /// repeated title state transitions on a live bar permanently drop the
    /// large title on iOS 26). The displayed bar title is decoupled from the
    /// tab flip: it retargets one runloop tick AFTER `selectedMediaType`
    /// changes, so the title transition never lands inside the bar's tab
    /// transition. Root fix is the per-tab NavigationStack structure
    /// (compat-sprint item 9) — constant titles remove the bug condition.
    @State private var barTitle: String = LibraryView.title(for: .home)

    private static func title(for type: MediaType) -> String {
        type == .audiobooks ? String(localized: "Library") : type.label
    }

    private func isTabMounted(_ type: MediaType) -> Bool {
        mountedTabs.contains(type) || selectedMediaType == type
    }

    /// Available content types from all active sources (deduplicated, in a fixed
    /// order). Today `[.audiobooks]`.
    private var availableMediaTypes: [MediaType] {
        let present = Set(AppSession.shared.allProviders.filter(\.isAvailable).map(\.mediaType))
        // Home is an aggregation tab (no source) — always first.
        return [.home] + MediaType.allCases.filter { $0 != .home && present.contains($0) }
    }

    let provider: any AudioProvider
    let onLogout: () -> Void

    init(provider: any AudioProvider, onLogout: @escaping () -> Void) {
        self.provider = provider
        self.onLogout = onLogout
        _viewModel = ObservedObject(wrappedValue: AppSession.shared.libraryViewModel)
        _playerCoordinator = ObservedObject(wrappedValue: AppSession.shared.playerCoordinator)
        // Letzter-Tab (01.08): start on the last selected tab — but only when
        // its MASTER toggle is still on (availability is irrelevant here, the
        // Y37 policy: a transiently unreachable tab shows its own state).
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
                // opacity) instead of being torn down by a `switch` — a branch
                // change used to destroy all @State/@StateObject/.task of the
                // old tab, so every return re-ran the tab's full load chain
                // (that was the tab-switch sluggishness).
                ZStack {
                    // df69f6b damping stage (a): ONE hidden probe captures the
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
                    // Y23 (Regel 6): the search page fully covers the active
                    // tab — covered content must not stay reachable for
                    // VoiceOver behind the page.
                    .accessibilityHidden(isShowingSearch)
                    // Y23: search mode is a FULL PAGE over the tab content
                    // (inside the stack — the deck's grid cells push value
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
                    // df69f6b damping: retarget the title OUTSIDE the flip's
                    // transaction (next main-actor tick), see `barTitle`.
                    // Stage (a): afterwards verify the bar actually shows the
                    // title and force a large-title rebuild if not — the tick
                    // alone proved flaky in long suite runs.
                    Task { @MainActor in
                        let title = Self.title(for: newValue)
                        barTitle = title
                        NavigationBarNudge.nudgeIfTitleMissing(expectedTitle: title)
                    }
                }
                // Y37 (hardened 01.08): fall back to Home ONLY on a real user
                // deactivation (master toggle) — transient availability
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
            // df69f6b: pin the LARGE display mode — switching the dynamic
            // title on the live bar (tab change while scrolled) dropped the
            // title but kept its reserved space (probe-reproduced).
            .navigationBarTitleDisplayMode(.large)
            .toolbarTitleDisplayMode(.large)
            // Y23: the search page brings its own header (scope bar) — the
            // nav bar with title + sort/settings yields while searching.
            .toolbar(isShowingSearch ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                // Our own adaptive glass instead of the system's toolbar
                // glass — the system one must be FULLY suppressed (shared
                // background hidden AND plain button style below), otherwise
                // both glasses stack: a dark doubled circle with a tinted
                // outline ring.
                // fb21fbd/8be0e17: the sort/filter button is GONE from the tab
                // head — sorting now sits at the surface it acts on (the "All
                // Books" grid, the podcast show grid, the album grid). The
                // 7330cc4 gate that hid it on Home/Radio goes with it: there is
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
            // registration wasn't guaranteed to be in the hierarchy — a root-level
            // registration is always present and stays the single one for the type.
            .podcastNavigationDestinations(playerCoordinator: playerCoordinator)
            // X15: music routes on the same stack root — music pushes must go
            // through `navigationPath` too (value-based), so a media-tab tap pops
            // album/artist pages back to the library. (Home shows album tiles as
            // well, so the registration belongs on the root, not the music tab.)
            .musicNavigationDestinations(playerCoordinator: playerCoordinator)
            // F4-discovery: radio genre drilldown on the same stack root.
            .radioNavigationDestinations(playerCoordinator: playerCoordinator)
            // 3a3b1aa: a capped row's heading pushes its full list. The
            // destination is the SHARED BrowseBooksScreen — same grid, same
            // cell, same paging behaviour as the browse surfaces (Regel 2).
            .navigationDestination(for: LibraryListRoute.self) { route in
                switch route {
                case .continueListening:
                    // 75add65 F3: Continue is a HOEREN page everywhere — the
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
                    // J1: the full stock behind the preview (endless grid +
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
                case .shelf(let source, let key):
                    CatalogShelfPage(source: source, shelfKey: key,
                                     playerCoordinator: playerCoordinator)
                case .series(let itemId):
                    ArchiveSeriesPage(itemId: itemId,
                                      playerCoordinator: playerCoordinator)
                case .oerrCountries:
                    OERRCountriesPage()
                }
            }
        }
        // Buttons inside List rows push routes over this callback instead of a
        // NavigationLink (which draws a disclosure chevron in a List). Set on
        // the NavigationStack ITSELF, not its root content — pushed
        // destinations (the show page's episode rows) inherit the environment
        // only from here, not from a modifier on the root VStack.
        .environment(\.pushPodcastRoute) { navigationPath.append($0) }
        // Home tiles push book detail pages (String route) the same way.
        .environment(\.pushBookDetail) { navigationPath.append($0) }
        // Paket 4: the search deck's catalog tile pushes the merged area.
        .environment(\.pushFreeAudiobooksRoute) { navigationPath.append($0) }
        // Y63: pushed detail pages (music album, podcast show) host the settings
        // cog themselves — the root toolbar's cog doesn't propagate. Set on the
        // NavigationStack itself so pushed destinations inherit it.
        .environment(\.openSettings) { showSettings = true }
        // F5: playlist cards (MediaTile onTap) push music routes through this.
        .environment(\.pushMusicRoute) { navigationPath.append($0) }
        // Teil 1: radio station rows/cards push the station detail page (variant
        // picker) from their context menu — the tap itself still plays.
        .environment(\.pushRadioRoute) { navigationPath.append($0) }
        // Y23: a push out of the search page's deck (grid cells navigate
        // value-based via NavigationLink) leaves search mode — the pushed
        // detail must get the normal bottom bar, not the search field.
        .onChange(of: navigationPath.count) { old, new in
            if isShowingSearch, new > old { closeSearch() }
        }
        // Bottom zone as an OVERLAY (reserves no space) — the free space is
        // provided by the scroll contents themselves via `bottomBarClearance()`,
        // which also covers pushed screens (detail, podcast show) cleanly.
        .overlay(alignment: .bottom) {
            // Mini bar and search button in ONE row so the search button is never
            // shifted up just because the mini bar appears/disappears — both stay
            // at the same height. Centrally above the whole NavigationStack so
            // both stay visible on every level (library AND book detail). Since
            // this row is structurally OUTSIDE the NavigationStack, the mini bar
            // cannot navigate via its own NavigationLink — instead it hooks into
            // the stack's navigation path via a callback (see navigationPath
            // above). On the full player itself the whole row is hidden,
            // otherwise play/pause & co. would appear twice.
            if !isShowingFullPlayer {
                BottomBarCollapseReader { barCollapsed in
                bottomBarContent(collapsed: barCollapsed)
                // S10: slightly crisper collapse/expand spring (less floaty) —
                // the mini-player keeps its matchedGeometry morph across it, the
                // extra rows cross-fade.
                // GT: gentler/slower bottom-bar collapse (was response 0.42).
                // Decouple (24.07): the top icons (`toolbarGlassIcon`) react to the
                // SAME `barCollapsed` flip immediately; the bar itself waits
                // `Self.barCollapseLag` on COLLAPSE only, so it visibly follows the
                // icons out instead of vanishing in the same frame. Expand (return
                // to rest) stays immediate — the primary surface should come back
                // promptly while the icons pop back in with their own bouncy spring.
                .animation(
                    barCollapsed
                        ? .spring(response: 0.55, dampingFraction: 0.85).delay(Self.barCollapseLag)
                        : .spring(response: 0.55, dampingFraction: 0.85),
                    value: barCollapsed)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
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
                    // is hidden, then spring it back up — masks the async
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
                    // Rapid double switch: a newer task owns the offset now —
                    // springing up here would interrupt ITS dip mid-swap.
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
        // X24 rule: the accent only ever changes COVER TO COVER. On an item
        // switch the old accent stands until the new one finished loading;
        // session end / pause / restore never reset it (hasAccent stays true,
        // and persists across restarts); neutral is only the first-run state
        // before anything ever played. The bar follows the SYSTEM appearance,
        // never the page (bar = app chrome; no page-driven forceDark).
        .environment(\.glassAccent, bottomColorLoader.hasAccent ? bottomColorLoader.accent : nil)
        // Pass the free-space height to ALL contents (also pushed screens); 0 on
        // the full player (it covers everything).
        // Constant reserve per composition (full player covers everything → 0;
        // mini-player mount is a REAL composition change and may adjust it —
        // never `collapsed`/the morph).
        .environment(\.bottomBarInset,
                     isShowingFullPlayer ? 0 : BottomBarReserve.total(hasMiniPlayer: playerCoordinator.activeItem != nil))
        .task {
            // Series data lives here — hand the coordinator a lookup for the
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
                // K1/K3 cold start: render the cached library IMMEDIATELY and
                // restore the mini-player from it — BEFORE the network load,
                // which then replaces everything silently.
                await viewModel.showCachedLibraryIfAvailable()
                await playerCoordinator.restoreLastSession(from: viewModel.entries)
                await viewModel.loadLibrary()
            }
            // Silently bring the last played book into the mini-player (no-op
            // when the cache-first path above already restored it).
            await playerCoordinator.restoreLastSession(from: viewModel.entries)
            // Cold start via quick action / Siri: the request arrived before
            // the library was loaded — execute it now.
            await handlePendingResumeRequest()
            // If offline progress was left over last time (the app was closed
            // offline before the sync went through): flush it now.
            await SyncQueue.shared.flush(apiClient: provider)
            await BookmarkQueue.shared.flush(provider: provider)
            await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
            // Check whether the ABS server has podcast libraries → the podcast tab
            // appears even without local RSS subscriptions (1 request, no full load).
            await AppSession.shared.absPodcastProvider.refreshAvailability()
            // Reconcile podcast progress via iCloud (across devices).
            PodcastCloudSync.shared.start()
            // Same switch, same store, same moment — the playlists travel with
            // the podcast progress or not at all.
            MaerPlaylistCloudSync.shared.start()
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
            // progress bars — e.g. if listening continued on another device in
            // the meantime.
            if newPhase == .active {
                PodcastCloudSync.shared.reconcile()   // pull the iCloud podcast state
                // Y33 (c): recheck the active sources and reconnect silently —
                // an outage must never require a force-quit to recover.
                AppSession.shared.musicProvider.reconnectIfNeeded()
                Task {
                    if viewModel.isShowingOfflineCache, NetworkMonitor.shared.isConnected {
                        await viewModel.loadLibrary()   // leave the stale cache state
                    }
                    await viewModel.refreshProgress()
                    await handlePendingResumeRequest()
                }
                // b4fdc36 (2): a session that has run far past the cap gets a
                // pass at the next CALM moment — enforcement no longer waits
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
                // S24: re-run the cover-cache cap on backgrounding, not only at
                // launch — otherwise a long session's cover growth stays uncapped
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
        // df0b3bb 3: hiding a title from Continue takes effect at once — the
        // rows rebuild locally, and Home follows because its recompute token
        // watches the Continue count.
        .onReceive(NotificationCenter.default.publisher(for: .continueHiddenChanged)) { _ in
            Task { await viewModel.refreshContinueRows() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeLastBookRequested)) { _ in
            // Fires when the app was ALREADY running (no scene-phase change).
            Task { await handlePendingResumeRequest() }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            // Covers the case that the app was open the whole time while the
            // connection returned — without this trigger the "offline" hint would
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
        // Logout (manual or automatic on 401): end playback cleanly — the final
        // sync attempt lands in the queue with a dead token and is sent after the
        // next login; the lock-screen display is cleared.
        .onDisappear {
            playerCoordinator.viewModel?.stop()
        }
        // Settings modal — its own NavigationStack, bottom zone set to 0 (no
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
        // Vollplayer → Quellseiten (Gate 2, 8913feb): registered on the ONE
        // central router — environment wiring was fragile across player
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
                // explicitly — the overlay itself ignores safe areas at the root.
                GeometryReader { proxy in
                    FullPlayerOverlay(
                        coordinator: playerCoordinator,
                        topInset: proxy.safeAreaInsets.top,
                        bottomInset: proxy.safeAreaInsets.bottom,
                        presentHeight: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                    ) {
                        // The sheet is already down here — just fade the mini bar in.
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
    /// N2: ONE container for both states, with the mini-player in the SAME
    /// structural slot — collapsing animates its real frame (the bar visibly
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
            // Y17 search mode: the field sits where the tab pill was, the tab
            // bar yields to the round home button (like the collapsed state).
            // Focused: mini player + home button step aside, only the search
            // pill stays above the keyboard, trailing where the magnifier sat.
            if isShowingSearch {
                // ONE structural slot for the field across the focus flip —
                // a branch swap would tear the focused TextField down and drop
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
        // A2: coordinator-level load errors ("Offline — not downloaded") appear
        // HERE too — the player screen that also renders them may not be
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
            // surface and no layout change — the fresh GlassEffectContainer/
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

    /// Compact "Home" button (morphed from the media pill) — expands the bar
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
            // N3: only THIS changing glyph is larger — circle, magnifier and
            // every other glyph keep their sizes.
            // Y24: in search mode the button MEANS "to the Home tab" — it
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

    /// F6: value-based navigation per result type (X15 discipline) — every
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
            navigationPath.append(PodcastRoute.showPreview(feedURL: result.id))
        case .catalogBook:
            // Q1: NACHSCHLAGEN — the existing detail sheet with the prominent
            // Play (the item was remembered by the search fan-out). OTR-class
            // items get their show page like everywhere else.
            if FreeCatalogProvider.shared.isOldTimeRadio(itemId: result.id) {
                navigationPath.append(FreeAudiobooksRoute.series(itemId: result.id))
            } else if let item = FreeCatalogProvider.shared.libraryItem(forId: result.id) {
                freeBookDetail = item
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
            // M5: playlist detail = the SAME MusicRoute.album path the F5
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
            // F3: play replaces the active playback — stations never route
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

    /// F6 follow-up (Regel 3): a music hit that no longer resolves must not
    /// die silently — brief haptic + the existing transient banner.
    private func searchResultUnavailable() {
        Haptics.tap()
        playerCoordinator.loadError = String(localized: "This result is no longer available.")
    }

    /// Y17: the bottom search field (iOS 26 pattern) — morphs from the
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

    /// Y19/Y24: the round glass X — clears a typed query first, a second tap
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
                // Y20: the scope starts where the user is (Home → Library).
                searchScope = SearchScope.initial(for: selectedMediaType)
                // Release-Gate 1 (30b2a32): the search page lives on the
                // library ROOT — opened from a pushed detail page it sat
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

    /// cb99bf6: store feeds the tab tile row (fill via Home's compute pass).
    @ObservedObject private var freeCatalogStore = FreeCatalogStore.shared
    @State private var freeBookDetail: LibraryItem?

    /// 5034add: master rides as @AppStorage so a settings flip re-renders
    /// the tab live (a plain UserDefaults read would not invalidate).
    @AppStorage(AppStorageKeys.freeCatalogsMasterEnabled) private var freeCatalogsMaster = true

    /// 7edb21b/5034add: ONE pure gate — master > feature toggle (audiobooks
    /// pill) > LibriVox service opt-out.
    private var freeAudiobooksArea: Bool {
        FreeCatalogActivation.effective(
            master: freeCatalogsMaster,
            feature: AppStorageKeys.freeAudiobooksAreaActive,
            service: AppStorageKeys.librivoxActive)
    }

    /// cb99bf6: the tile ROW above "All Books" — linked title into the area
    /// page, "New at LibriVox" tiles (MediaTile format, tap plays, context
    /// menu opens the license sheet), catalog≠library marking kept. The row
    /// hides entirely while the store is empty (service/toggle off, offline).
    private var freeAudiobooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 9ef73a4 Kleinigkeit: hand-built copy of RowHeading's chevron
            // branch → the shared entry variant.
            // fe13468: ONE string for the page and BOTH entries.
            RowHeading.entry("Free Audiobooks & Radio Plays", destination: FreeAudiobooksRoute.area)
                .accessibilityIdentifier("free-audiobooks-entry")
            Text("Free public-domain audiobooks from LibriVox — separate from your own library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(freeCatalogStore.rows.tabBooks) { item in
                        FreeCatalogBookTile(
                            item: item,
                            // 174f855: NACHSCHLAGEN — tap = detail.
                            onTap: { freeBookDetail = item }
                        )
                        .contextMenu {
                            Button {
                                Task { await playerCoordinator.open(item: item) }
                            } label: { Label("Play", systemImage: "play.fill") }
                            Button {
                                freeBookDetail = item
                            } label: { Label("Details", systemImage: "info.circle") }
                        }
                        .containerRelativeFrame(.horizontal,
                                                count: CardMetrics.recommendationColumns(regularWidth: false),
                                                spacing: 14)
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
        .sheet(item: $freeBookDetail) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// Audiobook tab: loading/error/empty states and the actual list.
    @ViewBuilder
    private var audiobooksContent: some View {
        if viewModel.isLoading && viewModel.entries.isEmpty {
            Spacer()
            ProgressView("Loading library…")
            Spacer()
        } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
            Spacer()
            VStack(spacing: 12) {
                Text(error).multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await viewModel.loadLibrary() }
                }
            }
            .padding()
            Spacer()
        } else if viewModel.entries.isEmpty {
            // Connected, but the server has no books (yet).
            Spacer()
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
            Spacer()
        } else {
            content
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
                    if !viewModel.recentlyAdded.isEmpty {
                        recentlyAddedGrid
                    }
                // cb99bf6 KORREKTUR: the Free-Audiobooks tile row sits ABOVE
                // "All Books" — below it, the entry drowned behind the whole
                // library scroll. Above the fold the row always materializes,
                // so the 34c36e1 lazy rule does not bite; the FILL still comes
                // from the one central compute() pass (shared store).
                if freeAudiobooksArea && !freeCatalogStore.rows.tabBooks.isEmpty {
                    freeAudiobooksSection
                }
                allBooksSection
                if viewModel.isLoadingMore {
                    // Progressive loading is still running — subtle hint that
                    // more titles are on the way.
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading more…").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            // Force full width explicitly — without it the stack's width follows
            // its content instead of the actually available screen width, which
            // could lead to a circular reference with the grid inside.
            .frame(maxWidth: .infinity)
            .padding(.top, TabContentLayout.topInset)
            // Free space as INNER padding: the ScrollView stays full-bleed,
            // content keeps scrolling behind the glass but rests above the bottom
            // zone (no black area behind the mini-player).
            .bottomBarClearance()
        }
        // A5: the refreshable closure must return promptly or the indicator can
        // stick — kick the full reload as a background task (its progressive UI
        // shows the rest via the loading-more footer / silent replace) and only
        // hold the spinner for a short, bounded moment.
        .refreshable {
            let work = Task { await viewModel.loadLibrary() }
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = work   // keep running detached from the refresh gesture
        }
        // Subtle feedback while a background reload runs with content on
        // screen — floats over the content, so no layout shift.
        .overlay(alignment: .top) {
            if viewModel.isRefreshing && !viewModel.entries.isEmpty {
                RefreshActivityPill()
            }
        }
        // Only the visible tab reports — hidden-but-mounted tabs must not feed
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
                    // 6fcb301: this row was the last uncapped one in the tab.
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
            // 6fcb301/3a3b1aa: the row is a PREVIEW — capped, and the chevron
            // appears only when something is actually hidden behind it.
            RowHeading(title: "Continue", font: .title2,
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
        // X26: precompute the card accents (same pattern as the podcast tab) —
        // cards color on first render instead of flashing the neutral base.
        .task(id: viewModel.continueListening.map(\.id).joined()) {
            for entry in viewModel.continueListening {
                await CoverColorLoader.prewarm(url: AppSession.shared.coverURL(forItemId: entry.id))
            }
        }
    }

    // MARK: Downloaded (vertical list — mirrors the podcast Downloaded pendant)

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
                // line with the size menu and the expand button — the
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

    /// J1: the tab shows a PREVIEW (9 tiles, counted chevron WITH the total:
    /// "All Books · 221 ›"); the endless grid + sort/filter control moved to
    /// `AllBooksPage` behind it. This drops the last "the section IS the full
    /// list" exception — every tab root is previews now. The e46e7b4 objection
    /// (a cap made books unreachable) is answered by DIE REGEL, which came
    /// later: the page exists, the chevron counts.
    ///
    /// Count rule: `total` is the WHOLE stock, `shown` the preview's books —
    /// so a persisted filter with zero hits still leaves the chevron (the way
    /// to the control on the page, fb21fbd trap), and a small library (≤ 9)
    /// drops it by pure counting, no special case.
    private var allBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeading(title: "All Books",
                       total: viewModel.entries.count,
                       shown: allBooksPreviewShown,
                       showsTotal: true,
                       destination: LibraryListRoute.allBooks)
            AudiobookStockGrid(viewModel: viewModel,
                               playerCoordinator: playerCoordinator,
                               limit: AudiobookStockGrid.previewLimit)
        }
    }

    /// Books visible in the preview window (a series stack counts its members).
    private var allBooksPreviewShown: Int {
        if viewModel.sortOption == .serie {
            return AudiobookStockGrid.previewBookCount(viewModel.seriesGroupedEntries,
                                                       limit: AudiobookStockGrid.previewLimit)
        }
        return min(AudiobookStockGrid.previewLimit, viewModel.sortedFilteredEntries.count)
    }

    // MARK: Resume from outside (quick action / Siri)

    /// Executes a pending "continue listening" request (home-screen quick
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

    /// Item for an id across sources (audiobook list OR podcast provider) — for
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
        // The icon is the OTHER render site of `collapsed` — it observes via
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
            // when the bottom bar collapses (scrolling) and POP back in at rest —
            // same `barCollapsed` trigger (3b consistency). `opacity 0` while out
            // drops the glass render (hitch relief).
            // Hitch-rest H1: dampingFraction 0.62 → 0.9 — the under-damped
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

    /// The full list behind a capped row (3a3b1aa). Read live from the view
    /// model, so the page tracks the same source its preview row does.
    private func entries(for route: LibraryListRoute) -> [LibraryEntry] {
        switch route {
        case .continueListening: viewModel.continueListening
        case .recentlyAdded:     viewModel.recentlyAdded
        // .allBooks renders AllBooksPage (grid follows the live sort state
        // itself) — never reaches this list helper.
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
