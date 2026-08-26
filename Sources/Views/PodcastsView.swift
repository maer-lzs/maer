// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import UIKit

/// A tile in "Recently updated" (Apple Podcasts style): show + time of the last
/// update + number of new episodes since the last played one.
nonisolated struct RecentShowInfo: Identifiable {
    let show: PodcastShow
    let lastUpdated: Double   // ms epoch of the newest episode
    let newCount: Int
    /// Teil 2: the show has at least one downloaded episode.
    var hasDownloads: Bool = false
    /// Teil 2: total unplayed episodes (drives "Most Unplayed" sort + filter).
    var unplayedCount: Int = 0
    var id: String { show.id }
}

/// Podcast tab in Apple Podcasts style: at the top a row of large "Up Next"
/// cards (newest episodes as eye-catchers), below it a compact show row to
/// browse and the full episode list. Episodes are normal `LibraryItem`s and run
/// through the coordinator.
struct PodcastsView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// False while the tab is mounted but hidden (kept alive for fast
    /// switching): the section recompute is skipped then and re-fires on
    /// becoming visible (isActive is part of the recompute token).
    var isActive: Bool = true
    @ObservedObject private var subs = PodcastSubscriptions.shared
    // The mixed catalog row renders from the calm-gated store
    // (sourceRows applies via runWhenCalm. No layout shift mid-scroll).
    @ObservedObject private var freeCatalogStore = FreeCatalogStore.shared
    // Front 2 fix 2: the tab root observes the NOISY stores (progress store =
    // every playback save, DownloadManager = every download progress tick,
    // ABS provider) only through the deduplicating recompute scope below.
    // Each publish used to re-render the WHOLE tab. Sections still rebuild via
    // `.task(id: recomputeToken)`; rows/tiles observe at leaf level.
    @ObservedObject private var recomputeScope = PodcastsRecomputeScope.shared
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared

    /// Non-observing store handles (reads only; re-render is driven by the scope).
    private var absPodcast: ABSPodcastProvider { ABSPodcastProvider.shared }
    /// See HomeView. Hiding an episode must redraw this row.
    @State private var hiddenRevision = 0
    /// More tile text lines at accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Shows of all podcast sources (RSS + ABS), deduplicated by the normalised
    /// feed URL. On a duplicate the ABS show (synced) is preferred.
    private var allShows: [PodcastShow] {
        let abs = absPodcast.activeShows
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = subs.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    // Section contents are NOT computed synchronously in the body (that
    // stuttered on tab switch) but filled in a `.task`. The tab appears
    // immediately, the sections come a frame later.
    @State private var nextUp: [LibraryItem] = []           // "Continue" (large cards)
    @State private var recentShows: [RecentShowInfo] = []   // "Recently updated" (show grid)
    /// The mirrored group's shows (their OWN row; split in compute).
    @State private var mirroredShows: [RecentShowInfo] = []
    @State private var downloaded: [LibraryItem] = []
    /// X1c: newest episode per show for the SHARED latest-episodes grid
    /// (same derivation and tile as Home).
    @State private var latestItems: [LibraryItem] = []
    @State private var showAddPodcasts = false
    @State private var isRefreshing = false
    /// Sections render only once the first complete snapshot exists. They
    /// used to pop in one by one across several recompute passes.
    @State private var sectionsReady = false
    @State private var downloadedExpanded = false
    /// Layout-shift: gated snapshot of the recommendations store. A late
    /// arrival routes through the calm gate (a whole-section insert is exactly
    /// the shift; empty→filled counts, no initial-fill exception per section).
    @State private var recommendationItems: [PodcastSearchResult] = []
    @AppStorage(AppStorageKeys.freeCatalogsMasterEnabled) private var freeCatalogsMaster = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Recompute when subscriptions, downloads or progress change. And when the
    /// tab becomes visible again (isActive gates the actual work). The store
    /// part comes deduplicated from the scope.
    private var recomputeToken: String {
        "\(isActive)-\(recomputeScope.token)-\(hiddenRevision)"
    }

    var body: some View {
        ScrollView {
            if sectionsReady {
                // Measured root fix: with the catalog tile row present,
                // this tab's outer
                // LazyVStack drove a pure SwiftUI LazyStack-placement loop
                // (289 s journey hang; app code absent from the sample). The
                // scroll reporter was ruled out (guard/constant-transform/
                // not-installed all hung identically; row out = green), and
                // the row's own container is irrelevant (lazy AND eager row
                // both green under an eager root). An EAGER root ends the
                // loop: 16 s green with the row in, both row variants. Cost
                // is bounded. Every section is a capped preview (and J2
                // caps the last full grid). Do NOT flip this back to lazy
                // without re-running the tile-row journey measurement.
                VStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    // Serverless: the tab opens with DISCOVER as its
                    // core. The former full-screen empty state blanketed the
                    // recommendation and radio-play rows that need no account.
                    // The add path stays, as a section instead of a wall.
                    if allShows.isEmpty && downloaded.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No podcasts yet")
                                .font(.title3).bold()
                            Text("Subscribe to a show or import your subscriptions from Apple Podcasts.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Add Podcasts") { showAddPodcasts = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal)
                    }
                    nextUpSection
                    // Eigener Bestand vor Schaufenster: die Reihen der Abos
                    // stehen hoeher, die Kuration rutscht zwei Reihen runter.
                    // Der Podcast-Tab ist die Flaeche der ABOS, und was hier
                    // steht, ist Feed-Kuration, weil man Feeds abonniert.
                    recommendationsSection
                    latestEpisodesSection
                    hoerspieleSection
                    // The server group is daily stock like the
                    // subscriptions. It sits right after Latest Episodes,
                    // ABOVE Premium and the subscription grid, not trailing.
                    pinchflatGroupSection
                    premiumSection
                    downloadedShelf
                    recentlyUpdatedSection
                    historyRow
                }
                .padding(.top, TabContentLayout.topInset)
                .bottomBarClearance()
                .transition(.opacity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        // Podcast routes are registered once on the NavigationStack root in
        // LibraryView (the Home tab pushes them too). Not here.
        // No subscription → instead of blank, an empty state with a path to add/import.

        .sheet(isPresented: $showAddPodcasts) {
            NavigationStack { PodcastSourceView() }
        }
        .reportsBottomBarScroll(active: isActive)   // only the visible tab reports
        .onReceive(NotificationCenter.default.publisher(for: .continueHiddenChanged)) { _ in
            hiddenRevision += 1
        }
        // The app-start mirror pass. SILENT on
        // every failure (a mesh-only server being away is normal); visible
        // errors live at the manual gesture in the source management.
        .task { await PinchflatSync.mirrorSilentlyOnce() }
        // Return promptly (stuck indicator otherwise) AND survive the
        // gesture's cancellation. The full refresh (feeds + ABS catalog incl.
        // detail fetches) keeps running as a background task; the sections
        // update reactively via the recompute token when it lands.
        .refreshable {
            let work = Task {
                isRefreshing = true
                defer { isRefreshing = false }
                // The strongest "fetch everything now" gesture left
                // OUT the very reconcile people wait for (subscriptions,
                // premium feeds, removals). Only the background service did
                // it. Reconcile FIRST, so freshly adopted shows are loaded by
                // the refresh that follows. Existing path, in-flight-safe.
                await GPodderSync.shared.reconcile()
                await subs.refreshAll()
                await absPodcast.refresh()
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            _ = work
        }
        .overlay(alignment: .top) {
            if isRefreshing { RefreshActivityPill() }
        }
        .task {
            // Let the tab-switch animation settle before kicking network
            // work. The refresh burst used to stutter the transition.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await absPodcast.refreshIfStale()                // ABS catalog (throttled)
            await GPodderSync.shared.autoReconcileIfNeeded()       // reconcile gpodder subscriptions
            await PodcastSubscriptionSync.autoReconcileIfNeeded()  // mirror local subscriptions
            await recommendations.refreshIfNeeded()               // recommendations (external)
        }
        // Layout-shift: mirror the store into the gated snapshot. #51: keyed on
        // the store's CONTENT version. The count missed same-size wholesale
        // replacements (stale section).
        .task(id: recommendations.contentVersion) {
            let fresh = recommendations.results
            BottomBarState.shared.runWhenCalm { recommendationItems = fresh }
        }
        .task(id: recomputeToken) {
            // Hidden-but-mounted: skip; the token includes isActive, so the task
            // re-fires with fresh data when the tab becomes visible again.
            guard isActive else { return }
            let sections = await computeSections()
            let latest = PodcastSections.newestPerShow(shows: allShows)
                .compactMap { AppSession.shared.libraryItem(forId: $0) }
            let initialFill = !sectionsReady
            let apply: @MainActor () -> Void = {
                withAnimation(initialFill ? .easeOut(duration: 0.25) : nil) {
                    nextUp = sections.nextUp
                    recentShows = sections.recentShows
                    mirroredShows = sections.mirroredShows
                    downloaded = sections.downloaded
                    latestItems = latest
                    sectionsReady = true
                }
            }
            // Layout-shift fix: landed background data must not reshape the
            // content mid-scroll. Non-initial updates wait for the calm gate
            // (the initial fill replaces the spinner, nothing can shift).
            if initialFill { apply() } else { BottomBarState.shared.runWhenCalm(apply) }
            // Precompute card colors → nothing happens while scrolling.
            for item in nextUp {
                await CoverColorLoader.prewarm(url: AppSession.shared.coverURL(forItemId: item.id))
            }
            // Load new episodes of active shows locally in the background.
            await PodcastAutoDownload.run(shows: allShows)
        }
    }

    /// Collect the main-actor state as one snapshot (single UserDefaults
    /// pass), then run the O(shows×episodes) computation off-main.
    private func computeSections() async -> PodcastSectionsResult {
        let shows = allShows
        let snapshot = PodcastSections.snapshot(shows: shows)
        // The tab's show grid is a PREVIEW now. Newest-first, unfiltered
        // (the sort/filter control moved to the full page, which computes with
        // the persisted values itself).
        return await PodcastSections.computeDetached(
            shows: shows, snapshot: snapshot, sort: .zuletztAktualisiert, filter: .alle
        )
    }

    // MARK: - Up Next (large cards, one per show)

    /// The row without the manually hidden entries. Read at render
    /// time (the marker store is cheap) so hiding takes effect at once.
    private var nextUpShown: [LibraryItem] {
        let markers = ContinueHiddenStore.markers()
        guard !markers.isEmpty else { return nextUp }
        return nextUp.filter { item in
            let stamp = ProgressMark.timestamp(ListeningStore.backup(item.id)) ?? 0
            return !ContinueHidden.isHidden(id: item.id, lastUpdate: stamp, markers: markers)
        }
    }

    @ViewBuilder
    private var nextUpSection: some View {
        if !nextUpShown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
RowHeading(title: "Keep Listening", font: .title2,
                           total: nextUpShown.count,
                           shown: RowPreview.cut(nextUpShown).count,
                           destination: PodcastRoute.nextUpAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        // Preview cap for every row of this tab.
                        // Hidden entries are gone from this row too.
                        ForEach(RowPreview.cut(nextUpShown)) { item in
                            PodcastFeaturedCard(item: item, playerCoordinator: playerCoordinator)
                        }
                    }
                    .padding(.horizontal)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    // MARK: - Recommended (external popularity, below the cards)

    /// The radio-play catalogue gets its entry HERE, not only in
    /// the search deck. Search is a place you go knowing what you want, a
    /// catalogue is a place you browse. Form question answered by symmetry:
    /// the audiobook tab already carries its catalogue as a LINKED SECTION
    /// HEADING with a tile row (`freeAudiobooksSection`), and this tab uses
    /// the same heading+row idiom for Recommended/Downloaded. So the same
    /// shape here, no new idiom. The search tile stays as the second entrance
    /// to the SAME page (NetworkServices pattern, no duplicate surface); a
    /// third entrance on Home would be one too many.
    ///
    /// The master switch gates it: no door into an empty room.
    /// The podcast tab's entry previews the FEED sources of the merged page
    /// (they land here as subscriptions). The audiobooks tab previews the
    /// catalog sources.
    ///
    /// The disjointness is a construction: the surface names its lanes
    /// (`CatalogMix.Surface.podcasts` carries feeds only), and a fence holds
    /// it at the TILES. The older test on the source enum proves a different
    /// sentence: it splits the ENUM, not the row.
    @ViewBuilder
    private var hoerspieleSection: some View {
        // The TILE row, unblocked by the measured root fix (eager tab root,
        // see body). The hang was the outer LazyVStack's placement loop, NOT
        // the scroll reporter (all reporter variants hung identically). The
        // row
        // ships in its intended mixed form: radio-play feeds + catalog titles
        // interleaved, heading = entry chevron onto the area page (the old
        // heading-only form dissolves into it). isActive stays as belt for
        // the mounted-but-hidden case.
        if freeCatalogsMaster && isActive {
            VStack(alignment: .leading, spacing: 10) {
                RowHeading.entry("Radio Plays to Subscribe",
                                 destination: FreeAudiobooksRoute.area)
                    .accessibilityIdentifier("free-catalog-entry-podcasts")
                CatalogMixRow(tiles: hoerspieleMixTiles,
                              playerCoordinator: playerCoordinator)
            }
            .task { await freeCatalogStore.ensureSourcesLoaded() }
        }
    }

    /// The podcast tab shows what lands here as a SUBSCRIPTION. The
    /// curated radio-play feeds. No catalog tile: those are whole works with
    /// a listening position and live in the audiobooks tab.
    private var hoerspieleMixTiles: [CatalogMix.Tile] {
        CatalogMix.tiles(for: .podcasts, rows: freeCatalogStore.sourceRows)
    }


    @ViewBuilder
    private var recommendationsSection: some View {
        // Layout-shift: renders from the GATED snapshot, not the live store.
        // The section (2nd from top) used to insert whole when the external
        // fetch landed, shoving everything below (the measured precision: the
        // conditional if-!isEmpty card-row insert IS the shift).
        if !recommendationItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
RowHeading(title: "Recommended",
                           total: recommendationItems.count,
                           shown: RowPreview.cut(recommendationItems).count,
                           destination: PodcastRoute.recommendations)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(RowPreview.cut(recommendationItems)) { r in
                            recommendationTile(r)
                                // Screen-relative slots + peek instead of
                                // the fixed 126 pt.
                                .cardRowSlot()
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Y2a: the SAME tile as Home's Discover row (RecommendationTile). Tap
    /// opens the temporary show preview, corner control subscribes.
    private func recommendationTile(_ r: PodcastSearchResult) -> some View {
        // The tab row carries the SAME reason line as Home. No
        // surface stays silent.
        RecommendationTile(result: r,
                           subtitle: PodcastRecommendationsStore.reasonLine(recommendations.reason(for: r)))
            .recommendationHideMenu(r)
    }

    // MARK: - Latest episodes (X1c: the SHARED grid, identical on Home)

    @ViewBuilder
    private var latestEpisodesSection: some View {
        if !latestItems.isEmpty {
            LatestEpisodesGrid(items: latestItems, playerCoordinator: playerCoordinator)
        }
    }

    // MARK: - Recently updated (show grid, 2 columns)

    @ViewBuilder
    private var recentlyUpdatedSection: some View {
        // A PREVIEW now. 12 tiles, newest first, unfiltered; the full
        // subscription grid (and the sort/filter control with it) lives on
        // the page behind the counted chevron. The count rule shows the total
        // ("Recently Updated · 27 ›"); with ≤ 12 shows the chevron falls away
        // by pure counting. The zero-hits trap dies with the filter's move:
        // the preview is unfiltered, and the page. Where the filter lives.
        // Always shows its own way back out.
        if !recentShows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                RowHeading(title: "Recently Updated",
                           total: recentShows.count,
                           shown: recentShowsPreview.count,
                           showsTotal: true,
                           destination: PodcastRoute.subscriptions)
                // Adaptive columns instead of a fixed pair. On iPads the
                // two flexible columns blew the tiles up to ~500pt covers.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)],
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(recentShowsPreview) { info in
                        NavigationLink(value: PodcastRoute.show(feedURL: info.show.feedURL)) {
                            RecentShowTile(info: info)
                        }
                        .buttonStyle(.plain)
                        .podcastShowMenu(info.show)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// J2 preview cut (12 = one GT-adjustable screenful of show tiles).
    private var recentShowsPreview: [RecentShowInfo] {
        Array(recentShows.prefix(12))
    }

    // MARK: - Pinchflat group

    /// The mirrored group is a NORMAL tile row after the blueprint.
    /// Show tiles (same tile as the subscription surfaces), RowPreview cap,
    /// counted chevron onto the group page (full grid). Tap = show page like
    /// any subscription; hiding is the context menu on tile + grid cell. NO
    /// per-tile origin capsule in here. The heading already says it.
    /// Row title: neutral placeholder from the server name. The final name
    /// is a device-loop decision, the string stays swappable.
    @ViewBuilder
    private var pinchflatGroupSection: some View {
        if !mirroredShows.isEmpty, let host = PinchflatClient.serverURL?.host {
            VStack(alignment: .leading, spacing: 12) {
                RowHeading(title: "", verbatimTitle: host,
                           total: mirroredShows.count,
                           shown: RowPreview.cut(mirroredShows).count,
                           destination: PodcastRoute.pinchflatGroup)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(RowPreview.cut(mirroredShows)) { info in
                            NavigationLink(value: PodcastRoute.show(feedURL: info.show.feedURL)) {
                                RecentShowTile(info: info)
                            }
                            .buttonStyle(.plain)
                            .cardRowSlot(spacing: 14)
                            .contextMenu {
                                PinchflatHideButton(show: info.show)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    // MARK: - Premium (private/paid feeds)

    /// The ONE premium test lives in PodcastSubscriptions (credentials OR
    /// token-URL class OR known members-only host).
    private func isPremium(_ show: PodcastShow) -> Bool {
        PodcastSubscriptions.isPremiumFeed(show.feedURL)
    }

    @ViewBuilder
    private var premiumSection: some View {
        let shows = allShows.filter { isPremium($0) }
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // DIE REGEL: every row has a page; the chevron is
                // pure COUNTING (total > shown). Page stays even when nobody
                // can reach it today, because other people's libraries are
                // bigger. Ad-hoc heading (not RowHeading): the lock icon is a
                // third variant. The moment RowHeading grows one more, it
                // becomes the enum noted, and this call site
                // folds in.
                if shows.count > RowPreview.cut(shows).count {
                    NavigationLink(value: PodcastRoute.premium) {
                        HStack(spacing: 6) {
                            Label("Premium", systemImage: "lock.fill")
                                .font(.title3).bold()
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    Label("Premium", systemImage: "lock.fill")
                        .font(.title3).bold().padding(.horizontal)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(RowPreview.cut(shows)) { show in
                            NavigationLink(value: PodcastRoute.show(feedURL: show.feedURL)) {
                                ShowTile(show: show)
                            }
                            .buttonStyle(.plain)
                            .podcastShowMenu(show)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Downloaded (3 rows, horizontally scrollable)

    @ViewBuilder
    /// Entry to the listen history. It lives WHERE podcasts live (a
    /// library fact, not a setting; proposal per report). Last row of the tab.
    private var historyRow: some View {
        NavigationLink(value: PodcastRoute.history) {
            HStack {
                Label("Listening History", systemImage: "checkmark.circle")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("podcast-history-row")
    }

    @ViewBuilder
    private var downloadedShelf: some View {
        if !downloaded.isEmpty {
            // Collapsed by default so the section doesn't dominate the page.
            let limit = horizontalSizeClass == .regular ? 6 : 3
            let shown = downloadedExpanded ? downloaded : Array(downloaded.prefix(limit))
            VStack(alignment: .leading, spacing: 8) {
RowHeading(title: "Downloaded",
                           total: downloaded.count,
                           shown: shown.count,
                           destination: PodcastRoute.downloadsAll)
                let mirrored = subs.mirroredEpisodeGuids()
                LazyVStack(spacing: 0) {
                    ForEach(shown) { item in
                        PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator,
                                          showsOriginCapsule: mirrored.contains(item.id))
                    }
                }
                if downloaded.count > limit {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { downloadedExpanded.toggle() }
                    } label: {
                        Text(downloadedExpanded
                             ? String(localized: "Show Less")
                             : String(localized: "Show All (\(downloaded.count))"))
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}


/// Front 2 fix 2: THE one observer of the podcast tab's noisy recompute inputs
/// (the MediaAvailabilityScope idea lifted to the tab level). It
/// listens to the stores' objectWillChange, recomputes the coarse token on the
/// next runloop turn (values settled) and republishes ONLY when the token
/// actually changed. A download progress tick or playback save no longer
/// re-renders the whole tab.
@MainActor
final class PodcastsRecomputeScope: ObservableObject {
    static let shared = PodcastsRecomputeScope()

    @Published private(set) var token: String = ""
    private var cancellables: Set<AnyCancellable> = []

    init() {
        token = Self.compute()
        Publishers.MergeMany(
            PodcastSubscriptions.shared.objectWillChange.eraseToAnyPublisher(),
            PodcastProgressStore.shared.objectWillChange.eraseToAnyPublisher(),
            DownloadManager.shared.objectWillChange.eraseToAnyPublisher(),
            ABSPodcastProvider.shared.objectWillChange.eraseToAnyPublisher()
        )
        // objectWillChange fires BEFORE the mutation. Hop to the next runloop
        // turn so the token reads settled values.
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            guard let self else { return }
            let fresh = Self.compute()
            if fresh != self.token { self.token = fresh }
        }
        .store(in: &cancellables)
    }

    private static func compute() -> String {
        // Content identity instead of counts.
        // A swapped subscription or download at equal count must recompute.
        let feeds = ContentToken.of(PodcastSubscriptions.shared.shows.map(\.feedURL))
        let downloads = ContentToken.of(DownloadManager.shared.downloadedItemIds)
        return "\(feeds)-\(downloads)-\(PodcastProgressStore.shared.changeToken)-\(ABSPodcastProvider.shared.changeToken)"
    }
}


/// The premium shows as a browsable GRID. The row's page.
/// Blueprint "recently added". The target form for tile rows:
/// heading with chevron -> the full grid. Management (S22) stays separate.
struct PremiumShowsPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared

    private var shows: [PodcastShow] {
        (subs.shows + ABSPodcastProvider.shared.shows)
            .filter { PodcastSubscriptions.isPremiumFeed($0.feedURL) }
    }

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)]

    var body: some View {
        ScrollView {
            CoverGrid(columns: columns) {
                ForEach(shows) { show in
                    NavigationLink(value: PodcastRoute.show(feedURL: show.feedURL)) {
                        ShowTile(show: show)
                    }
                    .buttonStyle(.plain)
                    .podcastShowMenu(show)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle(Text("Premium"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }
}


/// Welle 3: the continue row's full page. HOEREN grid (F2/F3: the page
/// inherits the row's tap class; tile tap PLAYS, progress on the tile).
struct PodcastContinuePage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    MediaTile(title: item.title,
                              subtitle: item.author,
                              coverURL: AppSession.shared.coverURL(forItemId: item.id),
                              placeholderSystemImage: "waveform.and.mic",
                              onTap: { Task { await playerCoordinator.open(item: item) } })
                        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator,
                                            showsContinueHide: true)
                }
            }
            .padding(.horizontal)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Continue"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let shows = PodcastAutoContinue.allShows()
            let snapshot = PodcastSections.snapshot(shows: shows)
            let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)
            let markers = ContinueHiddenStore.markers()
            items = sections.nextUp.filter { item in
                let stamp = ProgressMark.timestamp(ListeningStore.backup(item.id)) ?? 0
                return !ContinueHidden.isHidden(id: item.id, lastUpdate: stamp, markers: markers)
            }
        }
    }
}

/// Welle 3: the FULL recommendation pool. One page for Home's Discover and
/// the podcast tab's Recommended. NACHSCHLAGEN: tap opens the show
/// preview, subscribing lives there.
struct RecommendationsPage: View {
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @ObservedObject private var subs = PodcastSubscriptions.shared

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

    private var pool: [PodcastSearchResult] {
        let shows = subs.shows + ABSPodcastProvider.shared.shows
        return PodcastRecommendationsStore.excludingSubscribed(
            recommendations.results,
            subscribedNormalizedFeeds: Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }),
            subscribedTitles: shows.map(\.title))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(pool) { result in
                    RecommendationTile(result: result,
                                       subtitle: PodcastRecommendationsStore.reasonLine(recommendations.reason(for: result)))
                        .recommendationHideMenu(result)
                }
            }
            .padding(.horizontal)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Recommended"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await recommendations.refreshIfNeeded() }
    }
}


/// Welle 3b: the FULL newest-per-show grid (the 2/6-row expansion on the tab
/// is a preview, not a page. DIE REGEL). HOEREN class like the row.
struct LatestEpisodesPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @State private var items: [LibraryItem] = []

    var body: some View {
        ScrollView {
            LatestEpisodesGrid(items: items, playerCoordinator: playerCoordinator,
                               alwaysExpanded: true)
                .bottomBarClearance()
        }
        .navigationTitle(Text("Latest Episodes"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let shows = PodcastAutoContinue.allShows()
            let ids = PodcastSections.newestPerShow(shows: shows, limit: 200)
            items = ids.compactMap { AppSession.shared.libraryItem(forId: $0) }
        }
    }
}

/// Welle 3b: every downloaded episode as a full list. The tab's shelf shows
/// a capped, expandable cut. HOEREN rows (episode row plays).
struct PodcastDownloadsPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var subs = PodcastSubscriptions.shared

    private var items: [LibraryItem] {
        (subs.shows + ABSPodcastProvider.shared.shows)
            .flatMap(\.episodes)
            .compactMap { AppSession.shared.libraryItem(forId: $0.guid) }
            .filter { downloadManager.isDownloaded(itemId: $0.id) }
            .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
    }

    var body: some View {
        // Membership once per render (cell-cost rule).
        let mirrored = subs.mirroredEpisodeGuids()
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator,
                                      showsOriginCapsule: mirrored.contains(item.id))
                }
            }
            .bottomBarClearance()
        }
        .navigationTitle(Text("Downloaded"))
        .navigationBarTitleDisplayMode(.inline)
    }
}


/// H: the charts page. One tile ROW per genre of the measured
/// hoerspielChips axis, headed by a counting chevron onto the genre grid.
/// Same chart client as the chips (no second load path); genres are
/// STRUCTURE here, not filter (the chips stay on the overview only).
struct RadioPlayChartsPage: View {
    @State private var byChip: [String: [PodcastSearchResult]] = [:]
    @State private var loading = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                Text(verbatim: "Apple Podcasts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                ForEach(CatalogGenreAxis.hoerspielChips) { chip in
                    if let results = byChip[chip.key], !results.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            RowHeading(title: "", verbatimTitle: chip.title,
                                       total: results.count,
                                       shown: RowPreview.cut(results).count,
                                       destination: PodcastRoute.chartGenre(chip.key))
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 12) {
                                    ForEach(RowPreview.cut(results), id: \.feedURL) { result in
                                        RecommendationTile(result: result)
                                            .cardRowSlot()
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .scrollClipDisabled()
                        }
                    }
                }
                if loading && byChip.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(.top, TabContentLayout.topInset)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Popular Radio-Play Podcasts"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard byChip.isEmpty else { return }
            #if DEBUG
            if UITestSeed.isActive { return }
            #endif
            loading = true
            defer { loading = false }
            let directory = ITunesDirectory()
            let shows = PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows
            let feeds = Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
            let titles = shows.map(\.title)
            for chip in CatalogGenreAxis.hoerspielChips {
                var pool: [PodcastSearchResult] = []
                for genreId in chip.genreIds {
                    pool += (try? await directory.topPodcasts(genreId: genreId)) ?? []
                }
                byChip[chip.key] = PodcastRecommendationsStore.excludingSubscribed(
                    pool, subscribedNormalizedFeeds: feeds, subscribedTitles: titles)
            }
        }
    }
}

/// H stage 3: ONE parameterised genre page. The full chart grid.
/// NACHSCHLAGEN (tap = show preview, subscribing lives there).
struct ChartGenrePage: View {
    let chipKey: String
    @State private var results: [PodcastSearchResult] = []
    @State private var loading = false

    private var chip: CatalogGenreAxis.Chip? {
        CatalogGenreAxis.hoerspielChips.first { $0.key == chipKey }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            if loading && results.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(results, id: \.feedURL) { result in
                        RecommendationTile(result: result)
                    }
                }
                .padding(.horizontal)
                .bottomBarClearance()
            }
        }
        .navigationTitle(Text(verbatim: chip?.title ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard results.isEmpty, let chip else { return }
            #if DEBUG
            if UITestSeed.isActive { return }
            #endif
            loading = true
            defer { loading = false }
            let directory = ITunesDirectory()
            var pool: [PodcastSearchResult] = []
            for genreId in chip.genreIds {
                pool += (try? await directory.topPodcasts(genreId: genreId)) ?? []
            }
            let shows = PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows
            results = PodcastRecommendationsStore.excludingSubscribed(
                pool,
                subscribedNormalizedFeeds: Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) }),
                subscribedTitles: shows.map(\.title))
        }
    }
}


/// The full subscription grid behind the "Recently Updated" preview.
/// The sort/filter control moved here with it. The control sits on the
/// surface it acts on, with the same persisted AppStorage keys as before. The
/// zero-hits rule lives ON this page: an active filter with no match shows the
/// reason, and the control stays reachable.
struct PodcastSubscriptionsPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @AppStorage(AppStorageKeys.podcastSortOption) private var podcastSort = PodcastSortOption.zuletztAktualisiert
    @AppStorage(AppStorageKeys.podcastFilterOption) private var podcastFilter = PodcastFilterOption.alle
    @State private var infos: [RecentShowInfo] = []

    private var allShows: [PodcastShow] {
        let abs = ABSPodcastProvider.shared.activeShows
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = subs.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    /// Sort AND filter named when they deviate. No heading carries the sort
    /// here (the page title is stable), so the caption names both.
    private var controlLabel: String? {
        SortIndicator.summary([
            SortIndicator.part(podcastSort.label, ifNot: podcastSort == .zuletztAktualisiert),
            SortIndicator.part(podcastFilter.label, ifNot: podcastFilter == .alle),
        ])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer(minLength: 12)
                    SectionSortControl(activeLabel: controlLabel) { sortMenu }
                        .padding(.horizontal)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)],
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(infos) { info in
                        NavigationLink(value: PodcastRoute.show(feedURL: info.show.feedURL)) {
                            RecentShowTile(info: info)
                        }
                        .buttonStyle(.plain)
                        .podcastShowMenu(info.show)
                    }
                }
                .padding(.horizontal)
                if infos.isEmpty {
                    Text("No show matches this filter")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text("Recently Updated"))
        .navigationBarTitleDisplayMode(.inline)
        // Choice family: a changed sort/filter is a user statement. The
        // adoption echo re-fires this too. The equal-value guard in the note
        // keeps it from re-stamping.
        .onChange(of: podcastSort) { _, new in
            UserChoiceCloudSync.shared.noteScalar(
                key: AppStorageKeys.podcastSortOption, value: new.rawValue)
        }
        .onChange(of: podcastFilter) { _, new in
            UserChoiceCloudSync.shared.noteScalar(
                key: AppStorageKeys.podcastFilterOption, value: new.rawValue)
        }
        .task(id: "\(podcastSort.rawValue)-\(podcastFilter.rawValue)-\(subs.shows.count)") {
            let shows = allShows
            let snapshot = PodcastSections.snapshot(shows: shows)
            let sections = await PodcastSections.computeDetached(
                shows: shows, snapshot: snapshot, sort: podcastSort, filter: podcastFilter
            )
            infos = sections.recentShows
        }
    }

    @ViewBuilder private var sortMenu: some View {
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
}


/// The group page. The full mirrored-channel grid behind the row: heading →
/// full grid, no sort control, the group is server-ordered by newest. Hide =
/// context menu on the cell.
struct PinchflatGroupPage: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @State private var infos: [RecentShowInfo] = []

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)],
                alignment: .leading, spacing: 18
            ) {
                ForEach(infos) { info in
                    NavigationLink(value: PodcastRoute.show(feedURL: info.show.feedURL)) {
                        RecentShowTile(info: info)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        PinchflatHideButton(show: info.show)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .bottomBarClearance()
        }
        .navigationTitle(Text(verbatim: PinchflatClient.serverURL?.host ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: subs.shows.count) {
            let shows = subs.shows.filter { $0.origin != nil }
            let snapshot = PodcastSections.snapshot(shows: shows)
            let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)
            infos = sections.mirroredShows
        }
    }
}

/// The ONE hide gesture (context menu on row tile + grid cell).
/// Opt-out that survives mirror runs; re-admitting lives in the server
/// management (source view).
struct PinchflatHideButton: View {
    let show: PodcastShow

    var body: some View {
        Button(role: .destructive) {
            PinchflatSync.hide(feedURL: show.feedURL, title: show.title)
        } label: {
            Label("Hide Channel", systemImage: "eye.slash")
        }
    }
}

extension View {
    /// "Not interested". The permanent opt-out, offered ONLY on the three
    /// recommendation surfaces (Home row, tab row, full page). Search, genre
    /// charts and links never carry it: what the user actively steers to is
    /// not a recommendation. The release path lives in
    /// the podcast settings.
    func recommendationHideMenu(_ result: PodcastSearchResult) -> some View {
        contextMenu {
            Button(role: .destructive) {
                PodcastRecommendationsStore.shared.hide(result)
            } label: {
                Label("Not interested", systemImage: "hand.thumbsdown")
            }
        }
    }
}
