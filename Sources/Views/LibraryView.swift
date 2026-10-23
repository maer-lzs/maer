// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit
import OSLog

struct LibraryView: View {
    @Environment(\.itemRouter) private var router
    // Process-wide instances (AppSession) instead of own @StateObjects. The
    // CarPlay scene shares the player and library with the UI.
    @ObservedObject private var viewModel: LibraryViewModel
    @ObservedObject private var playerCoordinator: PlayerCoordinator
    /// The root observes the watch and hands the answer down; the library
    /// only reacts to the CHANGE (refill the stale offline cache, flush the
    /// queues) and never renders from it.
    @Environment(\.isOnline) private var isOnline
    @ObservedObject private var downloadStock = DownloadManager.stock
    /// Observe subscriptions so the podcast tab appears/disappears immediately.
    @ObservedObject private var podcastSubs = PodcastSubscriptions.shared
    /// Observe the source configuration. `availableMediaTypes` reads
    /// `isAvailable` per render, so the tab bar follows every toggle live
    /// (Subsonic reloadConfig, ABS-podcast probe) in BOTH directions.
    @ObservedObject private var session = AppSession.shared
    @State private var isShowingSearch = false
    /// Whether the search stepped aside for a page of the books tab and
    /// comes back when the stack returns to its depth.
    @State private var searchReturn = SearchReturn()
    /// The search field lives in the BOTTOM bar; bar and search page
    /// share this model (the page renders, the bar types).
    @StateObject private var searchModel = GlobalSearchModel.production()
    @FocusState private var searchFieldFocused: Bool
    /// Single-select scope of the search page. Starts at the opening
    /// tab's scope.
    @State private var searchScope: SearchScope = .library
    /// ONE path per tab, and that is the whole point of the split. With a single
    /// shared stack the bar's title had to change on every tab flip, and
    /// repeated title transitions on a live large-title bar drop the title
    /// for good on this platform (measured at the device: four flips, four
    /// times `TITLE MISSING`, never a healthy one). Five stacks with five
    /// paths give every tab a CONSTANT title, which removes the condition
    /// instead of damping it.
    ///
    /// A tab keeps its own depth now. That is a behaviour change and it was
    /// not the goal; it comes with the smallest way there and is named.
    @State private var navigationPaths: [MediaType: NavigationPath] = [:]
    @State private var isShowingFullPlayer = false
    /// Where the system stands its bars upright (folded iPhone Duo); the
    /// tab bar follows it (`TabBarPlacement`).
    @State private var verticalBarSide: VerticalBarSide?
    /// What the system reserves in the side strip (status bar, camera): how
    /// far down, and the axis of its own column.
    @State private var reservedSide = ReservedStrip()
    /// The playback bar's middle in window points, measured: the search in
    /// the side column stands on it. Nil while no bar is drawn.
    @State private var miniPlayerMidY: CGFloat?
    /// The side strip's width, measured by the column.
    @State private var sideStripWidth: CGFloat = 0
    private var tabBarPlacement: TabBarPlacement { .of(verticalBarSide: verticalBarSide) }
    /// The side column's width: the tab capsule, the cog and the search, as
    /// narrow as the system's own column (Apple Music on the device) and
    /// above the 44 pt a finger needs.
    private static let sideColumnWidth: CGFloat = 46
    /// THE one gap of the side column (Laurenz, 23.10.2026): Wi-Fi glyph to
    /// cog, search to tabs, playback bar to search.
    private static let sideGap: CGFloat = 14
    /// How much more the system reserves under the Wi-Fi glyph than it draws
    /// (measured: region to 174 pt, glyph to about 151). The cog reaches
    /// into it, to stand `sideGap` under the glyph; a tap there reaches the
    /// cog (Laurenz' review).
    private static let reservedBelowGlyph: CGFloat = 23

    /// How far past the content's edge the playback bar reaches beside the
    /// side column, so the gap to the search is `sideGap`: the search's
    /// leading edge lies half the strip plus the axis shift minus half its
    /// width from that edge.
    private static func sideBarReach(strip: CGFloat, axisShift: CGFloat) -> CGFloat {
        strip / 2 + axisShift - sideColumnWidth / 2 - sideGap
    }

    /// The distance from the window's bottom to the side search's bottom
    /// edge, so the search's middle lies on the playback bar's middle.
    private static func sideSearchBottom(windowHeight: CGFloat, playbackMidY: CGFloat?,
                                         fallback: CGFloat) -> CGFloat {
        guard let playbackMidY else { return fallback }
        return max(0, windowHeight - playbackMidY - sideColumnWidth / 2)
    }
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
    /// Cover accent of the ACTIVE book. Shared with every glass element in
    /// the bottom bar (mini player, search button, pill) via environment.
    // The bar accent persists across sessions. It only ever changes
    // cover-to-cover (see the environment wiring below).
    @StateObject private var bottomColorLoader = CoverColorLoader(persistenceKey: AppStorageKeys.bottomBarAccent)
    /// The session the mini player showed last. The coordinator drops its
    /// model while a title change loads; the bar keeps this one in place,
    /// taking no input, until the new one is ready (`PlayerScreenContent`,
    /// the rule the full player holds by).
    @State private var miniShown: PlayerScreen.ShownSession?
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
    /// Downloaded shelf expanded past its capped count.
    @State private var downloadedExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Tabs that have been shown at least once. They stay mounted (hidden)
    /// afterwards so their state/tasks survive switching. Never-visited tabs
    /// aren't mounted at all (no startup cost for the podcast/music chain).
    @State private var mountedTabs: Set<MediaType> = [.home]
    /// The damping's shared `barTitle` is GONE with the split: every stack names
    /// its own constant title, so there is nothing left to retarget.
    ///
    /// **The nudge itself stays, and the reason has changed.** It was kept
    /// as the measuring instrument, on the expectation that it would report
    /// `healthy` once the stacks were split. It does not: the device log on
    /// build 40 carries SEVENTEEN `TITLE MISSING -> rebuilding` and not one
    /// healthy line, so it still fires on every switch. The titles do stand
    /// again, but whether that is because the split removed the cause or
    /// because the rebuild now succeeds is UNMEASURED. Taking the nudge out
    /// would decide that question by experiment on a build that ships, so
    /// it stays until after 3.1.

    /// Every tab has the same name on top as below. The exception before
    /// called the audiobook tab „Bibliothek" while its button said
    /// „Hoerbuecher"; four of five tabs wore their own label, this one did
    /// not. The word was taken as well: the MIXED search scope has that
    /// name, books plus shows plus music, and that is the true superset.
    /// In CarPlay „Bibliothek" stays right, there it is the root of the
    /// whole offer.
    private static func title(for type: MediaType) -> String {
        type.label
    }

    /// A tab's path. A missing entry IS the root state, so no tab needs a
    /// preset, and a new one does not either.
    private func path(for type: MediaType) -> Binding<NavigationPath> {
        Binding(get: { navigationPaths[type] ?? NavigationPath() },
                set: { navigationPaths[type] = $0 })
    }

    /// Pushes into the path of a given tab. The tab need not be mounted for
    /// that: the path is a value, and the stack reads it as soon as it
    /// comes into being.
    private func push(_ value: some Hashable, to type: MediaType) {
        var next = navigationPaths[type] ?? NavigationPath()
        next.append(value)
        navigationPaths[type] = next
    }

    /// Pushes into the path of the ACTIVE tab. The bottom bar lies outside
    /// every stack and always means the one on screen.
    private func pushToActive(_ value: some Hashable) {
        push(value, to: selectedMediaType)
    }

    /// ONE tab: its own stack, its own path, its own CONSTANT title. The
    /// title is the whole reason: shared and changing, it made this platform
    /// drop the large title for good.
    @ViewBuilder
    private func tabStack<Content: View>(_ type: MediaType,
                                         @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path(for: type)) {
            librarySurface(title: Self.title(for: type)) {
                VStack(spacing: 0) {
                    if viewModel.isShowingOfflineCache {
                        offlineBanner
                    }
                    ZStack {
                        content()
                            // The search page covers the tab completely;
                            // what lies below stays out of VoiceOver's
                            // reach.
                            .accessibilityHidden(isShowingSearch && selectedMediaType == type)
                        if selectedMediaType == type {
                            // The probe catches the navigation controller
                            // of THIS stack, and it stands only in the
                            // active one: otherwise the instrument would
                            // take the bar of a hidden tab for the one meant.
                            NavigationBarNudge.Probe()
                                .frame(width: 0, height: 0)
                                .accessibilityHidden(true)
                            if isShowingSearch { searchPage }
                        }
                    }
                }
            }
        }
        // On the STACK, not on its root content: pushed destinations inherit
        // the environment only from here. The scroll edge effect is DECLARED,
        // not inherited from the platform: its default changed between SDK
        // 26.5 and 27 (the top edge became a hard-edged milky band reaching
        // far under the status bar, measured at the pixel on both SDKs), and
        // named here it holds for the tab root and every page pushed on it.
        .softTopScrollEdge()
        // Every hook pushes into the path of EXACTLY THIS tab, so a push on
        // Home also lands in Home.
        .environment(\.pushPodcastRoute) { push($0, to: type) }
        .environment(\.pushBookDetail) { push($0, to: type) }
        .environment(\.pushFreeAudiobooksRoute) { push($0, to: type) }
        .environment(\.pushLibraryListRoute) { push($0, to: type) }
        .environment(\.pushMusicRoute) { push($0, to: type) }
        .environment(\.pushRadioRoute) { push($0, to: type) }
        // A push from the search leaves the search: the pushed page gets the
        // normal bottom bar, not the search field. A page of the books tab
        // opened from it only sets it aside, and back at that depth the
        // search stands again with its query and results.
        .onChange(of: (navigationPaths[type] ?? NavigationPath()).count) { old, new in
            guard selectedMediaType == type else { return }
            switch searchReturn.pathChanged(from: old, to: new, showing: isShowingSearch) {
            case .close: closeSearch()
            case .stepAside:
                searchFieldFocused = false
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = false }
            case .comeBack:
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = true }
            case .none: break
            }
        }
        .tabVisibility(selectedMediaType == type)
    }

    /// The search page, as its own surface above the active tab and INSIDE
    /// the stack: its deck tiles push by value, and that only works within
    /// the stack whose path they mean.
    private var searchPage: some View {
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
                // Into the path of the NEW tab, never the old one.
                push(route, to: .music)
            },
            onOpenLibraryPage: { route in
                searchReturn.opensPage()
                push(route, to: selectedMediaType)
            }
        )
        .background(Color(.systemBackground).ignoresSafeArea())
        .transition(.opacity)
    }

    /// Everything EVERY tab stack carries on its root content: title,
    /// toolbar and the FULL destination bundle. The bundle stands in every
    /// stack on purpose, not just each tab's own type: Home pushes
    /// destinations of every type, and the destination's tab need not be
    /// mounted for that. The blunter form is the right one here, because
    /// it cannot go wrong.
    @ViewBuilder
    private func librarySurface<Content: View>(
        title: String, @ViewBuilder content: () -> Content) -> some View {
        content()
            .navigationTitle(Text(verbatim: title))
            // The large title stands IN the bar, level with the settings
            // gear, instead of in a row of its own below it: one row less
            // above the content. Pinned, because switching the display mode
            // on the live bar (tab change while scrolled) dropped the title
            // but kept its space. Only this modifier may name the mode: next
            // to `.navigationBarTitleDisplayMode(.large)` the older one wins
            // and the title falls back into its own row (measured).
            .toolbarTitleDisplayMode(.inlineLarge)
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
                // the user aims at moves. With the tabs at the side the cog
                // stands at the top of that column instead: the head's
                // trailing end lies against the status bar there.
                if !tabBarPlacement.isSide {
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
            // Radio genre drilldown on the same stack root.
            .radioNavigationDestinations(playerCoordinator: playerCoordinator)
            // A capped row's heading pushes its full list. The
            // destination is the SHARED BrowseBooksScreen. Same grid, same
            // cell, same paging behaviour as the browse surfaces.
            .navigationDestination(for: LibraryListRoute.self) { route in
                switch route {
                case .continueListening:
                    // Continue is a HOEREN page everywhere. The
                    // same compact grid with play-tap as Home's (the page
                    // inherits the row's tap class; BrowseBooksScreen's cells
                    // are NACHSCHLAGEN and stay for Recently Added).
                    MixedMediaPage(route: .continueListening,
                                   continueIds: viewModel.continueListening.map(\.id),
                                   addedItems: [],
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
                case .author, .series, .genre:
                    BrowseBooksScreen(
                        title: route.title,
                        entries: entries(for: route),
                        playerCoordinator: playerCoordinator,
                        libraryViewModel: viewModel
                    )
                case .groups(let kind):
                    // The one page of the groups: the books tab's tiles and
                    // the search deck's tiles open it.
                    BookGroupsScreen(kind: kind, entries: viewModel.entries)
                case .localFiles:
                    LocalFilesView()
                case .history:
                    ListenHistoryScreen(family: .book)
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
                    if let item = router.playable(itemId) {
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
        }
    }

    var body: some View {
        // Content by tab, and each tab is its OWN NavigationStack
        // with its own path and its own CONSTANT title. They stay mounted
        // side by side exactly as the tab contents did before (a branch
        // change would destroy all @State/@StateObject/.task of the old tab,
        // which was the tab-switch sluggishness).
        ZStack {
            if isTabMounted(.home) {
                tabStack(.home) {
                    HomeView(playerCoordinator: playerCoordinator,
                             isActive: selectedMediaType == .home,
                             libraryViewModel: viewModel)
                }
            }
            if isTabMounted(.audiobooks) {
                tabStack(.audiobooks) { audiobooksContent }
            }
            if isTabMounted(.podcasts) {
                tabStack(.podcasts) {
                    PodcastsView(playerCoordinator: playerCoordinator,
                                 isActive: selectedMediaType == .podcasts)
                }
            }
            if isTabMounted(.music) {
                tabStack(.music) {
                    MusicView(playerCoordinator: playerCoordinator,
                              isActive: selectedMediaType == .music)
                }
            }
            if isTabMounted(.radio) {
                tabStack(.radio) {
                    RadioView(playerCoordinator: playerCoordinator,
                              isActive: selectedMediaType == .radio)
                }
            }
        }
        .onChange(of: selectedMediaType) { _, newValue in
                    // A search set aside on another tab does not come back here.
                    searchReturn.forget()
                    mountedTabs.insert(newValue)
                    // Letzter-Tab: remember the choice across launches.
                    AppStorageKeys.lastSelectedTabValue = newValue.rawValue
                    // The title no longer moves at all (every stack names its
                    // own), so there is nothing left to retarget. The nudge
                    // stays for now as the MEASURING INSTRUMENT at the device:
                    // a `healthy` line here in place of `TITLE MISSING` is the
                    // proof that the rebuild did what the damping could not.
                    Task { @MainActor in
                        NavigationBarNudge.nudgeIfTitleMissing(expectedTitle: Self.title(for: newValue))
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
                    // A source can start serving books after the start (a
                    // Jellyfin books library is a server answer). Without this
                    // the shelf keeps the mix it made before that answer.
                    Task { await viewModel.refreshSecondarySources(from: session.allProviders) }
                    if TabSelectionPolicy.shouldFallBackToHome(
                        selected: selectedMediaType,
                        masterEnabled: selectedMediaType.userMasterEnabled) {
                        Logger.library.notice("Y37 fallback → home (user deactivated \(selectedMediaType.rawValue, privacy: .public))")
                        // The HOME path is the one that must stand at its
                        // root here, not the one of the tab being left: we
                        // are going to Home, and what the old tab held is
                        // its own business now.
                        returnToRoot(.home)
                        selectedMediaType = .home
                    }
                }
        // The rows draw past their frame on purpose (`scrollClipDisabled`);
        // with the tabs at the side they end at that column, so no card
        // lies behind it. Top and bottom stay open.
        .clipShape(SideColumnClip(placement: tabBarPlacement))
        // Where the system stands its bars upright, the tabs and the search
        // stand in the strip the system keeps free at that edge, under the
        // status bar; the bottom keeps only what plays.
        .overlay {
            // Under an open sheet the column draws nothing of its own: the
            // sheet leaves the strip free, and our glass showed through it.
            if tabBarPlacement.isSide, !isShowingFullPlayer, !isShowingSearch,
               !showSettings, !showQueueSheet {
                GeometryReader { proxy in
                    let strip = verticalBarSide == .leading ? proxy.safeAreaInsets.leading : proxy.safeAreaInsets.trailing
                    // From the top as the system's own column (Apple Music on
                    // the device): the system, then the page's buttons, a
                    // gap, the tabs, the search at the very bottom.
                    VStack(spacing: Self.sideGap) {
                        FloatingSearchButton(action: { showSettings = true },
                                             systemImage: "gearshape", label: "Settings",
                                             diameter: Self.sideColumnWidth)
                            .accessibilityIdentifier("open-settings")
                        Spacer(minLength: 16)
                        mediaBar(upright: true)
                        searchButton(diameter: Self.sideColumnWidth)
                    }
                    // As narrow as the system's own column and on its axis,
                    // under clock and Wi-Fi, clear of the rounded corner.
                    .frame(width: Self.sideColumnWidth)
                    .offset(x: reservedSide.axisShift)
                    .frame(width: max(strip, Self.sideColumnWidth + 8))
                    .frame(maxHeight: .infinity)
                    .padding(.top, max(0, reservedSide.top - Self.reservedBelowGlyph + Self.sideGap))
                    // The search stands on the playback bar's middle; with no
                    // bar, clear of the bottom edge.
                    .padding(.bottom, Self.sideSearchBottom(
                        windowHeight: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom,
                        playbackMidY: miniPlayerMidY,
                        fallback: proxy.safeAreaInsets.bottom + 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: verticalBarSide == .leading ? .topLeading : .topTrailing)
                    .ignoresSafeArea()
                    .readsReservedStrip(ofWidth: strip, $reservedSide)
                    .onChange(of: strip, initial: true) { _, width in sideStripWidth = width }
                }
            }
        }
        .readsVerticalBarSide($verticalBarSide)
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
                .padding(.leading, 10)
                // Beside the side column the bar reaches up to the search,
                // with the column's own gap between them.
                .padding(.trailing, tabBarPlacement.isSide
                         ? -Self.sideBarReach(strip: sideStripWidth, axisShift: reservedSide.axisShift)
                         : 10)
                .padding(.bottom, 2)
                // The bar avoids the keyboard ONLY while the search field can
                // own one. That is the single reason the overlay ever wanted
                // the inset. Outside search a keyboard inset that hangs around
                // after dismissal (the screenshot class) lifted the whole bar
                // into the middle of the screen; ignoring the zone there means
                // a stuck inset has nothing to lift.
                .ignoresSafeArea(.keyboard, edges: isShowingSearch ? [] : .bottom)
                // A title change keeps the bar in place: the accent follows
                // the new cover where it stands. The bar used to dip below
                // the screen for the swap; between two titles no part of it
                // may leave.
                .task(id: playerCoordinator.activeItem?.id) {
                    guard let item = playerCoordinator.activeItem else { return }
                    await bottomColorLoader.load(from: router.coverURL(item.id))
                }
            }
        }
        // The bar's held session follows the coordinator also while the bar
        // is not drawn (full player open), so it never holds an older title.
        // A failed load or the end of the session lets it go.
        .onChange(of: miniContent, initial: true) { _, content in
            switch content {
            case .player: miniShown = runningSession
            case .error, .nothing: miniShown = nil
            case .held, .loading: break
            }
        }
        .onChange(of: playerCoordinator.viewModel.map(ObjectIdentifier.init)) {
            if miniContent == .player { miniShown = runningSession }
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
                     isShowingFullPlayer ? 0 : BottomBarReserve.total(hasMiniPlayer: playerCoordinator.activeItem != nil || miniContent == .held))
        .task {
            // Series data lives here. Hand the coordinator a lookup for the
            // auto-play-next-in-series setting.
            playerCoordinator.nextInSeriesProvider = { [weak viewModel] itemId in
                viewModel?.nextInSeries(after: itemId)?.item
            }
            // A restart from 0 clears the library's local 'finished' flag.
            playerCoordinator.onItemRestarted = { [weak viewModel] itemId in
                viewModel?.markUnfinishedLocally(itemId: itemId)
            }
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
            await AppHousekeeping.flushQueues(provider: provider)
            await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
            await AppHousekeeping.startServices()
            // LAST: the housekeeping runs behind the content the person is
            // waiting for. It used to stand at the TOP of this task, ahead of
            // the cached library.
            AppHousekeeping.maintenance()
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
            // The app-level half (drive mode, iCloud pull, reconnect, cover
            // cap) lives in AppHousekeeping. What stays here needs VIEW state.
            AppHousekeeping.sceneChanged(to: newPhase)
            if newPhase == .active {
                // When the app returns to the foreground, silently refresh the
                // progress bars. E.g. if listening continued on another device
                // in the meantime.
                Task {
                    if viewModel.isShowingOfflineCache, isOnline {
                        await viewModel.loadLibrary()   // leave the stale cache state
                    }
                    await viewModel.refreshProgress()
                    await handlePendingResumeRequest()
                }
                // A session that has run far past the cap gets a pass at the
                // next CALM moment, and the calm gate is the VIEW's question.
                // WHETHER it is far past the cap is decided inside the sweep's
                // own background task: asking here meant a full directory
                // enumeration on the main actor at every return.
                ScrollCalm.run {
                    Artwork.sweepIfOverCap()
                }
            }
            // Offer the home-screen quick action for the last played book.
            if newPhase == .background { updateQuickActions() }
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
        .onChange(of: isOnline) { _, isConnected in
            // Covers the case that the app was open the whole time while the
            // connection returned. Without this trigger the "offline" hint would
            // wrongly stay, though there is network again.
            if isConnected && viewModel.isShowingOfflineCache {
                Task { await viewModel.loadLibrary() }
            }
            if isConnected {
                Task {
                    await AppHousekeeping.flushQueues(provider: provider)
                    await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
                }
            } else {
                // Connection lost while possibly playing: set the sync status
                // visibly to "offline" immediately, without queueing anything.
                playerCoordinator.viewModel?.markConnectionLostWhilePlaying()
            }
        }
        // Logout (manual or automatic on 401): end playback cleanly. The final
        // sync attempt lands in the queue with a dead token and is sent after the
        // next login; the lock-screen display is cleared.
        .onDisappear {
            playerCoordinator.viewModel?.stop(caller: "library view disappeared")
        }
        // Settings modal. Its own NavigationStack, bottom zone set to 0 (no
        // mini-player in the sheet → no free-space reservation needed).
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(coordinator: playerCoordinator, libraryViewModel: viewModel, onLogout: onLogout)
            }
            // The list rows of the settings keep their title's edge at an
            // accessibility size (`RowLabelStyle`).
            .labelStyle(RowLabelStyle())
            .environment(\.bottomBarInset, 0)
            .followsAppearanceChoice()
        }
        // Up-Next home at the player: the queue sheet opened from the
        // mini-player long-press (the full player presents its own copy of the
        // same PlayQueueSheet). Root-level, so it works from every tab and
        // above any pushed detail page.
        .sheet(isPresented: $showQueueSheet) {
            PlayQueueSheet(playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
        // Full player to source pages: registered on the ONE
        // central router. Environment wiring was fragile across player
        // presentation contexts (silent no-op when the env was missing).
        .onAppear {
            registerPlayerSourceRouter()
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
            selectedMediaType = target.tab
            switch target {
            case .book(let itemId):
                pushToActive(itemId)
            case .catalogBook(let itemId):
                pushToActive(FreeAudiobooksRoute.catalogBook(itemId: itemId))
            case .podcastShow(let feedURL):
                pushToActive(PodcastRoute.show(feedURL: feedURL))
            case .podcastEpisode(let itemId):
                pushToActive(PodcastRoute.episode(itemId: itemId))
            case .podcastLatest:
                pushToActive(PodcastRoute.latestAll)
            case .musicAlbum(let item):
                pushToActive(MusicRoute.album(item))
            case .musicArtist(let artist):
                pushToActive(MusicRoute.artist(artist))
            case .radioStation(let station):
                pushToActive(RadioRoute.station(station))
            case .catalogAlbum(let itemId):
                pushToActive(MusicRoute.catalogAlbum(itemId))
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
                // the keyboard (a view's identity must survive the flip).
                // Focused, the home button steps aside and the field takes the
                // full width; the X lives in its OWN round glass button (house
                // → Home, X → close).
                if !searchFieldFocused { miniPlayer(collapsed: barCollapsed) }
                HStack(spacing: 8) {
                    if !searchFieldFocused { homeButton }
                    bottomSearchField
                    searchCloseButton
                }
            } else {
            let composedCollapsed = barCollapsed
            // With the tabs at the side the bottom keeps only what plays.
            let tabsBelow = !tabBarPlacement.isSide
            if !composedCollapsed { banner }
            HStack(spacing: 8) {
                if composedCollapsed && tabsBelow { homeButton }
                miniPlayer(collapsed: barCollapsed)
                if composedCollapsed && tabsBelow { searchButton() }
            }
            if !composedCollapsed && tabsBelow {
                HStack(spacing: 10) {
                    mediaBar()
                    Spacer(minLength: 0)
                    searchButton()
                }
            }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        // The one channel, observed by the pill itself: it draws when a
        // notice arrives and shows nothing otherwise. A failed open is one
        // of its notices too, not a line of its own.
        ResumeMessageBanner(notices: playerCoordinator.notices)
    }

    /// What the bar shows, by the full player's rule: the running session,
    /// or while a title change loads, the one it showed before.
    private var miniContent: PlayerScreenContent {
        playerCoordinator.screenContent(holdsShown: miniShown != nil)
    }

    private var runningSession: PlayerScreen.ShownSession? {
        guard let vm = playerCoordinator.viewModel, let item = playerCoordinator.activeItem else { return nil }
        return PlayerScreen.ShownSession(viewModel: vm, item: item)
    }

    private var miniDisplayed: PlayerScreen.ShownSession? {
        switch miniContent {
        case .player:
            return runningSession
        case .held:
            return miniShown
        case .loading, .error, .nothing:
            return nil
        }
    }

    @ViewBuilder
    private func miniPlayer(collapsed barCollapsed: Bool) -> some View {
        if let session = miniDisplayed {
            MiniPlayerBar(
                coordinator: playerCoordinator, viewModel: session.viewModel, item: session.item,
                compact: barCollapsed,
                // The held session is the stopped one: its buttons would act
                // on nothing, the bar itself still opens the full player.
                controlsLive: miniContent == .player,
                onOpenPlayer: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                        isShowingFullPlayer = true
                    }
                },
                glassMorphID: "player", glassMorphNamespace: bottomGlassNS,
                // Beside the side column at the search's height.
                slim: tabBarPlacement.isSide)
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
            .matchedGeometryEffect(id: "player", in: barNS)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midY } action: { miniPlayerMidY = $0 }
            .onDisappear { miniPlayerMidY = nil }
        }
    }

    @ViewBuilder
    private func mediaBar(upright: Bool = false) -> some View {
        if availableMediaTypes.count > 1 {
            MediaTabBar(
                types: availableMediaTypes, selected: selectedMediaType,
                onSelect: { newValue in
                    // A tab tap leads back to the root of THIS tab, just as
                    // a tap used to leave the pushed page. What the other
                    // tabs hold stays theirs.
                    returnToRoot(newValue)
                    BottomBarState.shared.reset()   // switching tabs expands the bar
                    withAnimation(.snappy(duration: 0.2)) { selectedMediaType = newValue }
                },
                glassMorphID: "media", glassMorphNamespace: bottomGlassNS,
                upright: upright)
            .matchedGeometryEffect(id: "media", in: barNS)
        }
    }

    /// Compact "Home" button (morphed from the media pill). Expands the bar
    /// again (until the next scroll).
    private var homeButton: some View {
        Button {
            // Home = back to the library root (pops any pushed detail page) AND
            // expand the bar again. In search mode it also closes the
            // search and returns to the Home tab.
            if isShowingSearch {
                closeSearch()
                withAnimation(.snappy(duration: 0.2)) { selectedMediaType = .home }
                returnToRoot(.home)
            }
            returnToRoot(selectedMediaType)
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

    /// Value-based navigation per result type. Every
    /// push goes through `navigationPath`.
    /// The view PERFORMS the target; it does not decide it. The decision
    /// lives in `SearchRouting`, the search door's second question, where
    /// every hit kind must be answered before it compiles.
    private func openSearchResult(_ result: SearchResult) {
        switch SearchDoor.target(for: result) {
        case .book(let itemId):
            pushToActive(itemId)
        case .episode(let itemId):
            pushToActive(PodcastRoute.episode(itemId: itemId))
        case .show(let feedURL):
            pushToActive(PodcastRoute.show(feedURL: feedURL))
        case .catalogSeries(let itemId):
            pushToActive(FreeAudiobooksRoute.series(itemId: itemId))
        case .catalogBook(let itemId):
            pushToActive(FreeAudiobooksRoute.catalogBook(itemId: itemId))
        case .album(let itemId):
            // Albums AND playlists push this one route; a playlist detail
            // is not a second mechanism.
            guard let item = router.item(itemId) else { return searchResultUnavailable() }
            pushToActive(MusicRoute.album(item))
        case .artist(let itemId):
            // The hit's own server, not the device's configured one.
            let owner = session.musicProvider(for: itemId)
            guard let rawId = owner.artistId(fromItemId: itemId),
                  let artist = owner.artist(forId: rawId) else { return searchResultUnavailable() }
            pushToActive(MusicRoute.artist(artist))
        case .play(let itemId):
            // Play replaces the active playback. Songs and stations never
            // route into a detail page or the queue.
            guard let item = router.item(itemId) else { return searchResultUnavailable() }
            Task { await playerCoordinator.open(item: item) }
        case .drillInPlace:
            break   // authors and series drill inside the overlay
        case .unavailable:
            searchResultUnavailable()
        }
    }

    /// A music hit that no longer resolves must not
    /// die silently. Brief haptic + the channel's pill.
    private func searchResultUnavailable() {
        Haptics.tap()
        playerCoordinator.sayOpenFailure(String(localized: "This result is no longer available."),
                                         cause: .unknown, title: nil)
    }

    /// The bottom search field (iOS 26 pattern). Morphs from the
    /// magnifier (same matchedGeometry id). Always full width; the X
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

    /// A tab's stack back at its root: Home, a tap on a tab, a new search.
    /// That is no way back from a page, so a search set aside does not come
    /// back with it; only the system's back to its depth brings it.
    private func returnToRoot(_ type: MediaType) {
        searchReturn.forget()
        navigationPaths[type] = NavigationPath()
    }

    private func closeSearch() {
        searchReturn.forget()
        searchFieldFocused = false
        searchModel.query = ""
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = false }
    }

    private func searchButton(diameter: CGFloat = 56) -> some View {
        FloatingSearchButton(
            action: {
                searchModel.query = ""
                // The scope starts where the user is (Home → Library).
                searchScope = SearchScope.initial(for: selectedMediaType)
                // The search page lives on the library ROOT. Opened from a
                // pushed detail page it sat INVISIBLY underneath it (field in
                // the bottom bar worked, results never showed). Pop to root
                // first; any push already closes the search, so root-only is the
                // consistent home of the search.
                returnToRoot(selectedMediaType)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = true }
            },
            glassMorphID: "search", glassMorphNamespace: bottomGlassNS,
            diameter: diameter)
        .matchedGeometryEffect(id: "search", in: barNS)
        .accessibilityLabel(Text("Search"))
        // Locale-independent handle for the UI-test harness.
        .accessibilityIdentifier("global-search")
    }

    // MARK: - Suchleiste

    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("Offline: last known state")
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
            Text("From open catalogs: LibriVox, Project Gutenberg, Internet Archive and Old Time Radio. Separate from your own library.")
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
    /// settings row. The same route the tile deck opens with a server.
    private var localFilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowHeading.plain("Local Files")
            NavigationLink(value: LibraryListRoute.localFiles) {
                Label("Files on this device", systemImage: "folder")
                    .padding(.horizontal)
            }
        }
    }

    /// The listening history as the row at the end of the tab, with and
    /// without a server: the one row music and podcasts end with.
    private var historySection: some View {
        ListeningHistoryRow(route: LibraryListRoute.history, accessibilityId: LibraryListRoute.history.tileId)
    }

    /// With a server: the entries into the own library as the SAME deck of
    /// tiles the music tab and the search show (series, authors, local
    /// files; genres stand in the search deck only). No numeral: the groups
    /// are counted off the main thread on their page, not per evaluation
    /// of the tab.
    private var bookTabDeck: some View {
        CategoryDeckGrid(entries: LibraryListRoute.bookTabEntries.map { route in
            CategoryDeckEntry(id: route.tileId, title: route.title,
                              systemImage: route.systemImage ?? "books.vertical",
                              count: nil, accessibilityId: route.tileId) {
                push(route, to: .audiobooks)
            }
        })
    }

    /// The library section's own three states. Inline, each with a way out.
    @ViewBuilder
    private var librarySectionState: some View {
        if viewModel.isLoading && viewModel.entries.isEmpty {
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
            LoadFailedView(form: .row, sentence: Text(error)) {
                Task { await viewModel.loadLibrary() }
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else if viewModel.entries.isEmpty {
            // Connected, but the server has no books (yet).
            ContentUnavailableView {
                Label("No Audiobooks", systemImage: "books.vertical")
            } description: {
                Text(viewModel.isShowingOfflineCache
                    ? String(localized: "Offline. No books are downloaded.")
                    : String(localized: "Your library is empty. Add audiobooks via the Audiobookshelf web interface."))
            } actions: {
                Button("Refresh") {
                    Task { await viewModel.loadLibrary() }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The device's downloads and the newest of the library: the stock
    /// rows both branches share, in one place.
    @ViewBuilder
    private var stockSections: some View {
        if !viewModel.downloadedEntries.isEmpty {
            downloadedSection
        }
        if recentRowVisible, !viewModel.recentlyAdded.isEmpty {
            recentlyAddedGrid
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                // The order of the tabs: what you are hearing, the
                // notice when needed, your stock, and the offer from
                // outside at the bottom.
                if !viewModel.continueListening.isEmpty {
                    continueFeaturedSection
                }
                if !AppSession.shared.authViewModel.isLoggedIn {
                    // Serverless: local files, then the downloads and the
                    // device's own books, and the free area as the offer.
                    // The page's sections are embedded (one parameterised
                    // version, no drifting copy). No server sentence renders
                    // here: there is no server to speak about. The catalog
                    // row's switch holds here too: hidden, the tab keeps
                    // local files and the books, and no catalog or chart is
                    // asked.
                    localFilesSection
                    stockSections
                    if !viewModel.entries.isEmpty {
                        allBooksSection
                    }
                    if catalogRowVisible {
                        FreeAudiobooksPage(playerCoordinator: playerCoordinator, embedded: true)
                    }
                    historySection
                } else {
                    // 🔴 A doubted session says so HERE, right under what
                    // you are hearing. The tab keeps its content (the token
                    // is intact, the server is merely unreachable), and the
                    // line names the state instead of the library silently
                    // looking empty.
                    AbsSessionStateBanner()
                    stockSections
                    // The library's loading/error/empty state sits WHERE the
                    // library renders.
                    librarySectionState
                    if !viewModel.entries.isEmpty {
                        allBooksSection
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
                    // The free-catalog row is the offer from outside and
                    // stands under the library. Its FILL comes from the one
                    // central compute() pass (shared store), so standing
                    // below the fold in the lazy stack costs it nothing.
                    if freeAudiobooksArea {
                        freeAudiobooksSection
                    }
                    // The entries into the own library, then the history
                    // at the end of the tab.
                    bookTabDeck
                    historySection
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
                await CoverColorLoader.prewarm(url: router.coverURL(entry.id))
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
                // line with the size and the expand button. The component's
                // own horizontal padding would double up here.
                Text("Downloads list").font(.title3).bold()
                // The size of exactly the titles this row shows. Mass deletion
                // lives in the settings, per kind and once for everything; a
                // single book is deleted from its context menu. The sizes
                // come from the stock, never from the disk while rendering.
                Text(ByteCountFormatter.string(
                    fromByteCount: entries.reduce(0) { $0 + (downloadStock.sizeByItem[$1.id] ?? 0) },
                    countStyle: .file))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
            // scroll back up to reach the page. The line only
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
        //
        // These two lines said that and did the opposite: they called the
        // registered closure DIRECTLY and so skipped `open`, which is where
        // the diagnosis line lives. A jump that arrives from a notification
        // left no trace at all, and if no handler was registered yet it was a
        // silent no-op. That is the exact failure this router was built to end.
        switch target {
        case .show(let feedURL): PlayerSourceRouter.shared.open(.podcastShow(feedURL: feedURL))
        case .latestEpisodes:    PlayerSourceRouter.shared.open(.podcastLatest)
        }
    }

    /// action or Siri shortcut): open the last played book and play.
    private func handlePendingResumeRequest() async {
        // Siri "Play <book>": a specific book beats "continue last". A title
        // not found while the library still loads waits for the call after
        // the load (`.task`) instead of being dropped.
        if let itemId = ResumeRequest.pendingItemId {
            guard let item = item(forId: itemId) else {
                guard !viewModel.isLoading else { return }
                ResumeRequest.pendingItemId = nil
                ResumeRequest.pending = false
                resumeTargetMissing("item")
                return
            }
            ResumeRequest.pendingItemId = nil
            ResumeRequest.pending = false
            await playerCoordinator.open(item: item)
            return
        }
        guard ResumeRequest.pending else { return }
        // Already active (e.g. paused in the mini player): just play.
        if let vm = playerCoordinator.viewModel {
            ResumeRequest.pending = false
            await vm.playWithServerCheck()
            return
        }
        guard let lastId = AppStorageKeys.lastPlayedItemIdValue,
              let item = item(forId: lastId) else {
            guard !viewModel.isLoading else { return }
            ResumeRequest.pending = false
            resumeTargetMissing("last played")
            return
        }
        ResumeRequest.pending = false
        await playerCoordinator.open(item: item)
    }

    /// A shortcut, a quick action or the widget asked for a title this
    /// device cannot find: said like a search hit that no longer resolves,
    /// never a silent tap.
    private func resumeTargetMissing(_ what: String) {
        Logger.library.notice("RESUME request found no title what=\(what, privacy: .public)")
        Haptics.tap()
        playerCoordinator.sayOpenFailure(String(localized: "Audiobook could not be loaded."),
                                         cause: .unknown, title: nil)
    }

    /// Item for an id across sources (audiobook list OR podcast provider). For
    /// resume/quick-action/Siri.
    private func item(forId id: String) -> LibraryItem? {
        viewModel.entries.first(where: { $0.id == id })?.item
            ?? router.item(id)
    }

    /// Registers the dynamic home-screen quick action with the current
    /// book's title as subtitle (or removes it without a last book).
    private func updateQuickActions() {
        guard let lastId = AppStorageKeys.lastPlayedItemIdValue,
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
            // Sort + settings (both via here) SCROLL UP out of frame
            // when the bottom bar collapses (scrolling) and POP back in at rest.
            // Same `barCollapsed` trigger as the bar. `opacity 0` while out
            // drops the glass render (hitch relief).
            // dampingFraction 0.9, not 0.62: the under-damped
            // spring OVERSHOT (forth-then-back); anything sharing its
            // transaction window at the collapse flip wiggled with it (the
            // grid's micro back-and-forth at the 60 pt threshold). 0.9 keeps a
            // slight pop-in without overshoot.
            .offset(y: barCollapsed ? -72 : 0)
            .opacity(barCollapsed ? 0 : 1)
            .takesInput(!barCollapsed)
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
        // itself), the groups, local files and history pages read on their
        // own. They never reach this list helper.
        case .allBooks, .groups, .localFiles, .history: []
        // The books of one author, of one series, of one genre: asked in
        // ONE place, next to the groups their page counts.
        case .author(let name): LibraryViewModel.books(of: .authors, named: name, in: viewModel.entries)
        case .series(let name): LibraryViewModel.books(of: .series, named: name, in: viewModel.entries)
        case .genre(let name):  LibraryViewModel.books(of: .genres, named: name, in: viewModel.entries)
        }
    }

}

extension View {
    /// Visibility of a kept-alive tab: hidden tabs stay mounted (state/tasks
    /// survive) but are invisible, untouchable and hidden from VoiceOver.
    func tabVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .takesInput(visible)
    }

    /// Whether a view takes input of any kind, without changing how it
    /// looks. A finger is not the only way in: VoiceOver, Voice Control,
    /// Switch Control and Full Keyboard Access reach a view through the
    /// accessibility tree, so blocking hit testing alone leaves them in.
    func takesInput(_ takes: Bool) -> some View {
        allowsHitTesting(takes)
            .accessibilityHidden(!takes)
    }
}

private extension View {
    /// The declared soft top edge of every tab stack, its root and its pushed
    /// pages. Scroll edge effects exist from iOS 26; below it there is none
    /// to declare.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}
