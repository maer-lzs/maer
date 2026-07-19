import SwiftUI
import UIKit

struct LibraryView: View {
    // Process-wide instances (AppSession) instead of own @StateObjects — the
    // CarPlay scene shares the player and library with the UI.
    @ObservedObject private var viewModel: LibraryViewModel
    @ObservedObject private var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    /// Observe subscriptions so the podcast tab appears/disappears immediately.
    @ObservedObject private var podcastSubs = PodcastSubscriptions.shared
    @State private var isShowingSearch = false
    /// Y17: the search field lives in the BOTTOM bar; bar and results overlay
    /// share this model (the overlay renders, the bar types).
    @StateObject private var searchModel = GlobalSearchModel.production()
    @FocusState private var searchFieldFocused: Bool
    @State private var navigationPath = NavigationPath()
    @State private var isShowingFullPlayer = false
    @State private var showDeleteAllDownloads = false
    /// Scroll-driven collapsing of the bottom zone (Apple-Music-like): scrolling
    /// in the library turns it into a compact row.
    @Namespace private var barNS
    @ObservedObject private var bottomBar = BottomBarState.shared
    private var barCollapsed: Bool { bottomBar.collapsed }
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
    /// Measured height of the floating bottom zone (mini-player + tabs) — passed
    /// as bottom free space to all scroll contents so nothing is covered. The
    /// zone is an overlay (reserves no space itself).
    @State private var bottomBarHeight: CGFloat = 0
    /// Settings as a modal sheet (NOT pushed onto the library stack) — otherwise
    /// the mini-player overlay lies over it and its media pills trigger a jump
    /// back to the library from within the settings.
    @State private var showSettings = false
    /// Active content-type tab. Today audiobooks only; the bottom tab bar only
    /// appears when a second source brings a different type.
    @State private var selectedMediaType: MediaType = .home
    // Teil 2: per-tab sort/filter, shared with the tab content via the same
    // AppStorage keys (audiobooks keep using LibraryViewModel's own state).
    @AppStorage(AppStorageKeys.podcastSortOption) private var podcastSort = PodcastSortOption.zuletztAktualisiert
    @AppStorage(AppStorageKeys.podcastFilterOption) private var podcastFilter = PodcastFilterOption.alle
    @AppStorage(AppStorageKeys.musicSortOption) private var musicSort = MusicSortOption.nameAZ
    /// Downloaded shelf expanded past its capped count (F6/G19).
    @State private var downloadedExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Tabs that have been shown at least once — they stay mounted (hidden)
    /// afterwards so their state/tasks survive switching. Never-visited tabs
    /// aren't mounted at all (no startup cost for the podcast/music chain).
    @State private var mountedTabs: Set<MediaType> = [.home]
    #if DEBUG
    /// Teil 7: re-render everything when the DEBUG accent trial switches, so
    /// the candidate is visible live without a relaunch.
    @AppStorage("brandAccentTrial") private var brandAccentTrial = 0
    #endif

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
                }
                .onChange(of: selectedMediaType) { _, newValue in
                    mountedTabs.insert(newValue)
                }
            }
            .navigationTitle(selectedMediaType == .audiobooks ? Text("Library") : Text(selectedMediaType.label))
            .toolbar {
                // Our own adaptive glass instead of the system's toolbar
                // glass — the system one must be FULLY suppressed (shared
                // background hidden AND plain button style below), otherwise
                // both glasses stack: a dark doubled circle with a tinted
                // outline ring.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarLeading) {
                        sortFilterMenu
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        settingsLink
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigationBarLeading) {
                        sortFilterMenu
                    }
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
        }
        // Buttons inside List rows push routes over this callback instead of a
        // NavigationLink (which draws a disclosure chevron in a List). Set on
        // the NavigationStack ITSELF, not its root content — pushed
        // destinations (the show page's episode rows) inherit the environment
        // only from here, not from a modifier on the root VStack.
        .environment(\.pushPodcastRoute) { navigationPath.append($0) }
        // Home tiles push book detail pages (String route) the same way.
        .environment(\.pushBookDetail) { navigationPath.append($0) }
        // Y17: search results sheet UNDER the bottom bar (the bar carries the
        // search field in search mode and must stay on top); the full player
        // overlay further down still covers everything.
        .overlay {
            if isShowingSearch {
                GeometryReader { proxy in
                    SearchOverlay(
                        libraryViewModel: viewModel,
                        model: searchModel,
                        activeTab: selectedMediaType,
                        topInset: proxy.safeAreaInsets.top,
                        presentHeight: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom,
                        onOpen: { result in
                            closeSearch()
                            openSearchResult(result)
                        },
                        onDismiss: { closeSearch() }
                    )
                }
                .transition(.identity)
            }
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
                bottomBarContent
                // S10: slightly crisper collapse/expand spring (less floaty) —
                // the mini-player keeps its matchedGeometry morph across it, the
                // extra rows cross-fade.
                .animation(.spring(response: 0.42, dampingFraction: 0.85), value: barCollapsed)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                // Measure the height → pass it as free space to the scroll
                // contents. ONLY while expanded, so the free space doesn't shrink
                // on collapse (that would trigger a scroll feedback loop).
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { bottomBarHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, h in
                                if !barCollapsed { bottomBarHeight = h }
                            }
                    }
                }
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
        .environment(\.bottomBarInset, isShowingFullPlayer ? 0 : bottomBarHeight)
        #if DEBUG
        // Teil 7: hard refresh on accent-trial switch (DEBUG only).
        .id(brandAccentTrial)
        #endif
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            // When the app returns to the foreground, silently refresh the
            // progress bars — e.g. if listening continued on another device in
            // the meantime.
            if newPhase == .active {
                PodcastCloudSync.shared.reconcile()   // pull the iCloud podcast state
                // Y33 (c): recheck the active sources and reconnect silently —
                // an outage must never require a force-quit to recover.
                if SubsonicProvider.shared.isAvailable == false, AppStorageKeys.subsonicEnabledValue {
                    SubsonicProvider.shared.reloadConfig()
                }
                Task {
                    if viewModel.isShowingOfflineCache, NetworkMonitor.shared.isConnected {
                        await viewModel.loadLibrary()   // leave the stale cache state
                    }
                    await viewModel.refreshProgress()
                    await handlePendingResumeRequest()
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
    private var bottomBarContent: some View {
        VStack(spacing: 8) {
            // Y17 search mode: the field sits where the tab pill was, the tab
            // bar yields to the round home button (like the collapsed state).
            // Focused: mini player + home button step aside, only the search
            // pill stays above the keyboard, trailing where the magnifier sat.
            if isShowingSearch {
                // ONE structural slot for the field across the focus flip —
                // a branch swap would tear the focused TextField down and drop
                // the keyboard (the N2 identity lesson).
                if !searchFieldFocused { miniPlayer }
                HStack(spacing: 8) {
                    if !searchFieldFocused {
                        homeButton
                    } else {
                        Spacer(minLength: 44)
                    }
                    bottomSearchField
                }
            } else {
            if !barCollapsed { banner }
            HStack(spacing: 8) {
                if barCollapsed { homeButton }
                miniPlayer
                if barCollapsed { searchButton }
            }
            if !barCollapsed {
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
    private var miniPlayer: some View {
        if let vm = playerCoordinator.viewModel, let item = playerCoordinator.activeItem {
            MiniPlayerBar(coordinator: playerCoordinator, viewModel: vm, item: item, compact: barCollapsed) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    isShowingFullPlayer = true
                }
            }
            .offset(y: miniPlayerSwapOffset)
            .matchedGeometryEffect(id: "player", in: barNS)
        }
    }

    @ViewBuilder
    private var mediaBar: some View {
        if availableMediaTypes.count > 1 {
            MediaTabBar(types: availableMediaTypes, selected: selectedMediaType) { newValue in
                navigationPath = NavigationPath()
                bottomBar.reset()   // switching tabs expands the bar
                withAnimation(.snappy(duration: 0.2)) { selectedMediaType = newValue }
            }
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
                bottomBar.expand()
            }
        } label: {
            // Collapsed bar shows the ACTIVE tab's symbol; tapping only expands
            // the bar (never switches tab). Symbol changes with the tab.
            // N3: only THIS changing glyph is larger — circle, magnifier and
            // every other glyph keep their sizes.
            Image(systemName: selectedMediaType.systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(shape: Circle()))
        .matchedGeometryEffect(id: "media", in: barNS)
        .accessibilityLabel(selectedMediaType.label)
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
        case .album:
            if let item = AppSession.shared.libraryItem(forId: result.id) {
                navigationPath.append(MusicRoute.album(item))
            } else {
                searchResultUnavailable()
            }
        case .artist:
            let rawId = String(result.id.dropFirst("sub:artist:".count))
            if let artist = SubsonicProvider.shared.artist(forId: rawId) {
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
    /// magnifier (same matchedGeometry id).
    private var bottomSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $searchModel.query, prompt: Text("Search everything"))
                .focused($searchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if searchFieldFocused || !searchModel.query.isEmpty {
                Button {
                    searchModel.query = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .frame(maxWidth: searchFieldFocused ? 320 : .infinity)
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
        .matchedGeometryEffect(id: "search", in: barNS)
        .accessibilityIdentifier("global-search-field")
    }

    private func closeSearch() {
        searchFieldFocused = false
        searchModel.query = ""
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = false }
    }

    private var searchButton: some View {
        FloatingSearchButton {
            searchModel.query = ""
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = true }
        }
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

    @State private var libraryWidth: CGFloat = 0

    /// Smallest allowed column width — the column width was already at this
    /// value before all the grid adjustments; it yields 3 columns on a normal
    /// iPhone portrait.
    private let minColumnWidth: CGFloat = 108
    private let gridSpacing: CGFloat = 16
    private let gridHorizontalPadding: CGFloat = 16

    /// Self-computed column count instead of `.adaptive` — that proved
    /// unreliable (sometimes no recompute after a rotation, sometimes a column
    /// width that did not match the actual cover size and thus overlapped). With
    /// a single reliable width measurement as the source for both column count
    /// and cell size there is no more ambiguity.
    private var columnCount: Int {
        guard libraryWidth > 0 else { return 3 }
        let available = libraryWidth - gridHorizontalPadding * 2
        let count = Int((available + gridSpacing) / (minColumnWidth + gridSpacing))
        return max(count, 1)
    }

    /// Cell width that exactly matches the computed column count — grid and cover
    /// size always use the same value, so they can never diverge.
    private var gridCellWidth: CGFloat {
        guard libraryWidth > 0 else { return 132 }
        let available = libraryWidth - gridHorizontalPadding * 2
        let totalSpacing = gridSpacing * CGFloat(columnCount - 1)
        return (available - totalSpacing) / CGFloat(columnCount)
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
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { libraryWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in
                            libraryWidth = newWidth
                        }
                }
            )
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
            Text("Recently Added").font(.title3).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                // Eager HStack: the lazy variant froze the shelf height on the
                // first measured cell and clipped taller cells' last text line.
                HStack(alignment: .top, spacing: 16) {
                    ForEach(viewModel.recentlyAdded) { entry in
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
            Text("Continue").font(.title2).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(viewModel.continueListening) { entry in
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

    private var allBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All Books")
                .font(.title3).bold()
                .padding(.horizontal)
            if viewModel.sortOption == .serie {
                seriesGrid
            } else {
                bookGrid(viewModel.sortedFilteredEntries)
            }
        }
    }

    /// Grid under series sorting: series as stacks, single books normal.
    private var seriesGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(viewModel.seriesGroupedEntries) { gridEntry in
                switch gridEntry {
                case .single(let entry):
                    // Same top spacing as the fan headroom of the stack tiles —
                    // otherwise covers/texts in mixed rows sit at different heights.
                    BookGridCell(
                        entry: entry,
                        width: gridCellWidth,
                        playerCoordinator: playerCoordinator,
                        libraryViewModel: viewModel
                    )
                    .padding(.top, 10)
                case .series(let name, let entries):
                    NavigationLink {
                        seriesDetail(name: name, entries: entries)
                    } label: {
                        SeriesStackCell(
                            name: name,
                            entries: entries,
                            cellWidth: gridCellWidth,
                            coverURL: { AppSession.shared.coverURL(forItemId: $0) }
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
    }

    /// Detail view of a series: all volumes in order.
    private func seriesDetail(name: String, entries: [LibraryEntry]) -> some View {
        ScrollView {
            bookGrid(entries)
                .padding(.top, 12)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
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

    private var sortFilterMenu: some View {
        Menu {
            // Teil 2: each tab gets its OWN sort/filter menu + persisted state.
            // The button (position/glass styling) stays identical across tabs.
            switch selectedMediaType {
            case .audiobooks: audiobookSortMenu
            case .podcasts: podcastSortMenu
            case .music: musicSortMenu
            case .home, .radio: EmptyView()   // no sortable library
            }
        } label: {
            toolbarGlassIcon("line.3.horizontal.decrease")
        }
        // Opt out of the toolbar's automatic glass button style — our
        // AdaptiveGlassBackground is the ONLY glass on this button.
        .buttonStyle(.plain)
        // The menu style tints its label ABOVE the label's own styling —
        // without this the icon renders in the app accent (orange) instead
        // of behaving like the other toolbar buttons.
        .tint(.primary)
    }

    /// Audiobooks — the reference menu, unchanged (LibraryViewModel state).
    @ViewBuilder private var audiobookSortMenu: some View {
        Picker("Sort By", selection: $viewModel.sortOption) {
            ForEach(SortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        Button {
            viewModel.sortAscending.toggle()
        } label: {
            Label(
                viewModel.sortAscending ? String(localized: "Ascending") : String(localized: "Descending"),
                systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down"
            )
        }
        Divider()
        Picker("Filter", selection: $viewModel.filterOption) {
            ForEach(FilterOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
    }

    /// Podcasts — sort + filter the "Recently updated" show grid.
    @ViewBuilder private var podcastSortMenu: some View {
        Picker("Sort By", selection: $podcastSort) {
            ForEach(PodcastSortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        Divider()
        Picker("Filter", selection: $podcastFilter) {
            ForEach(PodcastFilterOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
    }

    /// Music — server-side album sort (no direction toggle). Offline the sort is
    /// disabled with a hint instead of a silent no-op (it needs the server).
    @ViewBuilder private var musicSortMenu: some View {
        Picker("Sort By", selection: $musicSort) {
            ForEach(MusicSortOption.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .disabled(!networkMonitor.isConnected)
        if !networkMonitor.isConnected {
            Text("Sorting needs a connection")
        }
    }

    private var settingsLink: some View {
        Button {
            showSettings = true
        } label: {
            toolbarGlassIcon("gearshape")
        }
        .buttonStyle(.plain)
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
        Image(systemName: systemName)
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .modifier(AdaptiveGlassBackground(
                shape: Circle(),
                lightAccent: bottomColorLoader.hasAccent ? bottomColorLoader.accent : nil
            ))
            .environment(\.colorScheme, systemColorScheme)
            // Menu renders its label via tint (ignoring foregroundStyle).
            .tint(.primary)
    }

    /// Cover grid with a self-computed column count and width (see
    /// `columnCount`/`gridCellWidth`) instead of `.adaptive` — grid and cover
    /// size are now guaranteed to use the same value, so they can never diverge
    /// (neither too narrow with overlap, nor unnecessarily few columns on a
    /// narrow iPhone).
    private func bookGrid(_ entries: [LibraryEntry]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(entries) { entry in
                // Shared cell (BookGridComponents) — identical in the
                // library and the author/genre browse grids.
                BookGridCell(
                    entry: entry,
                    width: gridCellWidth,
                    playerCoordinator: playerCoordinator,
                    libraryViewModel: viewModel
                )
            }
        }
        .padding(.horizontal)
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
