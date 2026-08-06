// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
    // Front 2 fix 2: the tab root observes the NOISY stores (progress store =
    // every playback save, DownloadManager = every download progress tick,
    // ABS provider) only through the deduplicating recompute scope below —
    // each publish used to re-render the WHOLE tab. Sections still rebuild via
    // `.task(id: recomputeToken)`; rows/tiles observe at leaf level.
    @ObservedObject private var recomputeScope = PodcastsRecomputeScope.shared
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared

    /// Non-observing store handles (reads only; re-render is driven by the scope).
    private var absPodcast: ABSPodcastProvider { ABSPodcastProvider.shared }
    // Teil 2: show-grid sort/filter, persisted; shared with the toolbar menu in
    // LibraryView via the same AppStorage keys.
    /// df0b3bb 3: see HomeView — hiding an episode must redraw this row.
    @State private var hiddenRevision = 0
    @AppStorage(AppStorageKeys.podcastSortOption) private var podcastSort = PodcastSortOption.zuletztAktualisiert
    @AppStorage(AppStorageKeys.podcastFilterOption) private var podcastFilter = PodcastFilterOption.alle
    /// D4/B3: more tile text lines at accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Shows of all podcast sources (RSS + ABS), deduplicated by the normalised
    /// feed URL — on a duplicate the ABS show (synced) is preferred.
    private var allShows: [PodcastShow] {
        let abs = absPodcast.activeShows
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = subs.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    // Section contents are NOT computed synchronously in the body (that
    // stuttered on tab switch) but filled in a `.task` — the tab appears
    // immediately, the sections come a frame later.
    @State private var nextUp: [LibraryItem] = []           // "Continue" (large cards)
    @State private var recentShows: [RecentShowInfo] = []   // "Recently updated" (show grid)
    @State private var downloaded: [LibraryItem] = []
    /// X1c: newest episode per show for the SHARED latest-episodes grid
    /// (same derivation and tile as Home).
    @State private var latestItems: [LibraryItem] = []
    @State private var showAddPodcasts = false
    @State private var isRefreshing = false
    /// Sections render only once the first complete snapshot exists — they
    /// used to pop in one by one across several recompute passes.
    @State private var sectionsReady = false
    @State private var downloadedExpanded = false
    /// Layout-shift: gated snapshot of the recommendations store — a late
    /// arrival routes through the calm gate (a whole-section insert is exactly
    /// the shift; empty→filled counts, no initial-fill exception per section).
    @State private var recommendationItems: [PodcastSearchResult] = []
    @AppStorage(AppStorageKeys.freeCatalogsMasterEnabled) private var freeCatalogsMaster = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Recompute when subscriptions, downloads or progress change — and when the
    /// tab becomes visible again (isActive gates the actual work). The store
    /// part comes deduplicated from the scope.
    private var recomputeToken: String {
        "\(isActive)-\(recomputeScope.token)-\(podcastSort.rawValue)-\(podcastFilter.rawValue)-\(hiddenRevision)"
    }

    var body: some View {
        ScrollView {
            if sectionsReady {
                LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    nextUpSection
                    hoerspieleSection
                    recommendationsSection
                    latestEpisodesSection
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
        // LibraryView (the Home tab pushes them too) — not here.
        // No subscription → instead of blank, an empty state with a path to add/import.
        .overlay {
            // The queue no longer renders on this tab (its home is the player),
            // so queued items don't keep the empty state away anymore.
            if allShows.isEmpty && downloaded.isEmpty {
                ContentUnavailableView {
                    Label("No podcasts yet", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Subscribe to a show or import your subscriptions from Apple Podcasts.")
                } actions: {
                    Button("Add Podcasts") { showAddPodcasts = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showAddPodcasts) {
            NavigationStack { PodcastSourceView() }
        }
        .reportsBottomBarScroll(active: isActive)   // only the visible tab reports
        .onReceive(NotificationCenter.default.publisher(for: .continueHiddenChanged)) { _ in
            hiddenRevision += 1
        }
        // A5: return promptly (stuck indicator otherwise) AND survive the
        // gesture's cancellation — the full refresh (feeds + ABS catalog incl.
        // detail fetches) keeps running as a background task; the sections
        // update reactively via the recompute token when it lands.
        .refreshable {
            let work = Task {
                isRefreshing = true
                defer { isRefreshing = false }
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
            // S3: let the tab-switch animation settle before kicking network
            // work — the refresh burst used to stutter the transition.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await absPodcast.refreshIfStale()                // ABS catalog (throttled)
            await GPodderSync.shared.autoReconcileIfNeeded()       // reconcile gpodder subscriptions
            await PodcastSubscriptionSync.autoReconcileIfNeeded()  // mirror local subscriptions
            await recommendations.refreshIfNeeded()               // recommendations (external)
        }
        // Layout-shift: mirror the store into the gated snapshot. #51: keyed on
        // the store's CONTENT version — the count missed same-size wholesale
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
                    downloaded = sections.downloaded
                    latestItems = latest
                    sectionsReady = true
                }
            }
            // Layout-shift fix: landed background data must not reshape the
            // content mid-scroll — non-initial updates wait for the calm gate
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

    /// S2: collect the main-actor state as one snapshot (single UserDefaults
    /// pass), then run the O(shows×episodes) computation off-main.
    private func computeSections() async -> PodcastSectionsResult {
        let shows = allShows
        let snapshot = PodcastSections.snapshot(shows: shows)
        return await PodcastSections.computeDetached(
            shows: shows, snapshot: snapshot, sort: podcastSort, filter: podcastFilter
        )
    }

    // MARK: - Up Next (large cards, one per show)

    /// df0b3bb 3: the row without the manually hidden entries. Read at render
    /// time (the marker store is cheap) so hiding takes effect at once.
    private var nextUpShown: [LibraryItem] {
        let markers = ContinueHiddenStore.markers()
        guard !markers.isEmpty else { return nextUp }
        return nextUp.filter { item in
            let stamp = (UserDefaults.standard
                .array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double])?.last ?? 0
            return !ContinueHidden.isHidden(id: item.id, lastUpdate: stamp, markers: markers)
        }
    }

    @ViewBuilder
    private var nextUpSection: some View {
        if !nextUpShown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
RowHeading(title: "Continue", font: .title2,
                           total: nextUpShown.count,
                           shown: RowPreview.cut(nextUpShown).count,
                           destination: PodcastRoute.nextUpAll)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        // 6fcb301: preview cap for every row of this tab.
                        // df0b3bb 3: hidden entries are gone from this row too.
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

    /// cae18f5: the radio-play catalogue gets its entry HERE, not only in
    /// the search deck — search is a place you go knowing what you want, a
    /// catalogue is a place you browse. Form question answered by symmetry:
    /// the audiobook tab already carries its catalogue as a LINKED SECTION
    /// HEADING with a tile row (`freeAudiobooksSection`), and this tab uses
    /// the same heading+row idiom for Recommended/Downloaded — so the same
    /// shape here, no new idiom. The search tile stays as the second entrance
    /// to the SAME page (NetworkServices pattern, no duplicate surface); a
    /// third entrance on Home would be one too many.
    ///
    /// The master switch gates it: no door into an empty room.
    /// Paket 4: the podcast tab's entry previews the FEED sources of the
    /// merged page (they land here as subscriptions) — the audiobooks tab
    /// previews the catalog sources. Disjoint by construction (CatalogSource
    /// split, tested), which is the owner's "no tile in both tabs".
    @ViewBuilder
    private var hoerspieleSection: some View {
        // isActive gate: this row is STATICALLY filled and would render at app
        // start inside the kept-alive but HIDDEN tab — where a tile row hangs
        // the main thread in a layout loop (adbc018 class; measured three
        // times: TabPill journey 281s instead of ~20 whenever the podcast tab
        // was mounted invisible, green the moment it is the visible one; both
        // width strategies hung, so the gate is on VISIBILITY, not sizing).
        // Every other row in this tab is fetch-filled and thus empty until the
        // tab is visible — this one needs the explicit gate instead.
        if freeCatalogsMaster && isActive {
            VStack(alignment: .leading, spacing: 10) {
                // 733ac2a asked for a TILE row here — built three ways
                // (RecommendationTile + containerRelativeFrame, fixed width,
                // plain MediaTile) and every variant hangs the main thread in
                // an AttributeGraph invalidation loop on this tab (sampled:
                // hang3.sample shows reportsBottomBarScroll in the cycle;
                // bisect: row out = journeys green in 10s, any tile row in =
                // 282s). The stable heading form ships; the tile-row form is
                // an OPEN finding with the measurement protocol in the report
                // — not silently dropped.
                RowHeading.entry("Free Audiobooks & Radio Plays",
                                 destination: FreeAudiobooksRoute.area)
                    .accessibilityIdentifier("free-catalog-entry-podcasts")
                Text("Radio plays and audiobooks from public broadcasters, independent producers and public-domain catalogs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }


    @ViewBuilder
    private var recommendationsSection: some View {
        // Layout-shift: renders from the GATED snapshot, not the live store —
        // the section (2nd from top) used to insert whole when the external
        // fetch landed, shoving everything below (the reviewer's precision: the
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
                                // Kachel-Auftrag: screen-relative slots + peek
                                // instead of the fixed 126 pt.
                                .containerRelativeFrame(.horizontal,
                                    count: CardMetrics.recommendationColumns(regularWidth: horizontalSizeClass == .regular),
                                    span: 1, spacing: 12)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    /// Y2a: the SAME tile as Home's Discover row (RecommendationTile) — tap
    /// opens the temporary show preview, corner control subscribes.
    private func recommendationTile(_ r: PodcastSearchResult) -> some View {
        RecommendationTile(result: r)
    }

    // MARK: - Latest episodes (X1c: the SHARED grid, identical on Home)

    @ViewBuilder
    private var latestEpisodesSection: some View {
        if !latestItems.isEmpty {
            LatestEpisodesGrid(items: latestItems, playerCoordinator: playerCoordinator)
        }
    }

    // MARK: - Recently updated (show grid, 2 columns)

    /// fb21fbd: the podcast sort/filter menu now lives WHERE it acts — the
    /// tab's show grid — instead of in the shared toolbar. Content unchanged.
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

    @ViewBuilder
    private var recentlyUpdatedSection: some View {
        // fb21fbd Falle: the control now lives IN this section, so gating the
        // section on a non-empty grid would hide the only way back out of a
        // filter that matches nothing — and the filter is persisted, so it
        // would survive a restart. The section therefore also shows while a
        // filter is active, then with a reason instead of tiles.
        if !recentShows.isEmpty || podcastFilter != .alle {
            VStack(alignment: .leading, spacing: 12) {
                // Heading reflects the active grid sort (Teil 2); default sort's
                // label is "Recently Updated", so the default look is unchanged.
                // fb21fbd: sort/filter sit AT this grid — it is the surface
                // they act on. The HEADING already names the sort (Teil 2), so
                // the caption beside the symbol carries only the filter; naming
                // the sort twice in one line would be noise.
                HStack(alignment: .firstTextBaseline) {
                    RowHeading.plain(verbatim: podcastSort.label)
                    Spacer(minLength: 12)
                    SectionSortControl(
                        activeLabel: SortIndicator.part(podcastFilter.label,
                                                        ifNot: podcastFilter == .alle)
                    ) { podcastSortMenu }
                        .padding(.horizontal)
                }
                // D6/B5: adaptive columns instead of a fixed pair — on iPads the
                // two flexible columns blew the tiles up to ~500pt covers.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)],
                    alignment: .leading, spacing: 18
                ) {
                    // 6fcb301 gilt fuer VORSCHAU-Reihen — dieses Raster ist
                    // keine: es IST die Abo-Sammlung des Tabs (die Sortierung
                    // im Kopf wirkt genau hier), das Podcast-Gegenstueck zu
                    // "Alle Buecher". Ein Deckel haette ab dem 13. Abo Feeds
                    // unerreichbar gemacht — es gibt keine Flaeche dahinter.
                    ForEach(recentShows) { info in
                        NavigationLink(value: PodcastRoute.show(feedURL: info.show.feedURL)) {
                            RecentShowTile(info: info)
                        }
                        .buttonStyle(.plain)
                        .podcastShowMenu(info.show)
                    }
                }
                .padding(.horizontal)
                if recentShows.isEmpty {
                    Text("No show matches this filter")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Premium (private/paid feeds)

    /// Y52: the ONE premium test lives in PodcastSubscriptions (credentials OR
    /// token-URL class OR known members-only host).
    private func isPremium(_ show: PodcastShow) -> Bool {
        PodcastSubscriptions.isPremiumFeed(show.feedURL)
    }

    @ViewBuilder
    private var premiumSection: some View {
        let shows = allShows.filter { isPremium($0) }
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // DIE REGEL (5c646c6): every row has a page; the chevron is
                // pure COUNTING (total > shown) — page stays even when nobody
                // can reach it today, because other people's libraries are
                // bigger. Ad-hoc heading (not RowHeading): the lock icon is a
                // third variant — the moment RowHeading grows one more, it
                // becomes the enum the reviewer noted (e268c70), and this call site
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
    /// V6: entry to the listen history — it lives WHERE podcasts live (a
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
                LazyVStack(spacing: 0) {
                    ForEach(shown) { item in
                        PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
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
/// (the MediaAvailabilityScope idea lifted to the tab level, Regel 2). It
/// listens to the stores' objectWillChange, recomputes the coarse token on the
/// next runloop turn (values settled) and republishes ONLY when the token
/// actually changed — a download progress tick or playback save no longer
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
        // objectWillChange fires BEFORE the mutation — hop to the next runloop
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
        // #51 W1 (class-B convention): content identity instead of counts —
        // a swapped subscription or download at equal count must recompute.
        let feeds = ContentToken.of(PodcastSubscriptions.shared.shows.map(\.feedURL))
        let downloads = ContentToken.of(DownloadManager.shared.downloadedItemIds)
        return "\(feeds)-\(downloads)-\(PodcastProgressStore.shared.changeToken)-\(ABSPodcastProvider.shared.changeToken)"
    }
}


/// e96d396 B2: the premium shows as a browsable GRID — the row's page.
/// Blaupause "Zuletzt hinzugefuegt" (the owner named it the target form):
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


/// Welle 3: the continue row's full page — HOEREN grid (F2/F3: the page
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
                let stamp = (UserDefaults.standard
                    .array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double])?.last ?? 0
                return !ContinueHidden.isHidden(id: item.id, lastUpdate: stamp, markers: markers)
            }
        }
    }
}

/// Welle 3: the FULL recommendation pool — one page for Home's Discover and
/// the podcast tab's Recommended (Regel 2). NACHSCHLAGEN: tap opens the show
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
                    RecommendationTile(result: result)
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
/// is a preview, not a page — DIE REGEL). HOEREN class like the row.
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

/// Welle 3b: every downloaded episode as a full list — the tab's shelf shows
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
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                }
            }
            .bottomBarClearance()
        }
        .navigationTitle(Text("Downloaded"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
