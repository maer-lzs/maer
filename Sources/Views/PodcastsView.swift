import SwiftUI
import Combine
import UIKit

/// A tile in "Recently updated" (Apple Podcasts style): show + time of the last
/// update + number of new episodes since the last played one.
nonisolated struct RecentShowInfo: Identifiable {
    let show: PodcastShow
    let lastUpdated: Double   // ms epoch of the newest episode
    let newCount: Int
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
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    // Sections depend on progress (played/in progress) and downloads — observe
    // both so "Up Next"/"Downloaded"/"Played" rebuild live.
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @ObservedObject private var queue = PodcastQueue.shared
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @State private var subscribingRec: Set<String> = []
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
    @State private var showAddPodcasts = false
    @State private var isRefreshing = false
    /// Sections render only once the first complete snapshot exists — they
    /// used to pop in one by one across several recompute passes.
    @State private var sectionsReady = false
    @State private var downloadedExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Recompute when subscriptions, downloads or progress change — and when the
    /// tab becomes visible again (isActive gates the actual work).
    private var recomputeToken: String {
        "\(isActive)-\(subs.shows.count)-\(downloads.downloadedItemIds.count)-\(progress.changeToken)-\(absPodcast.changeToken)"
    }

    var body: some View {
        ScrollView {
            if sectionsReady {
                LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    nextUpSection
                    recommendationsSection
                    queueSection
                    premiumSection
                    downloadedShelf
                    recentlyUpdatedSection
                }
                .padding(.top, TabContentLayout.topInset)
                .bottomBarClearance()
                .transition(.opacity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        .podcastNavigationDestinations(playerCoordinator: playerCoordinator)
        // No subscription → instead of blank, an empty state with a path to add/import.
        .overlay {
            if allShows.isEmpty && downloaded.isEmpty && queue.isEmpty {
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
        .task(id: recomputeToken) {
            // Hidden-but-mounted: skip; the token includes isActive, so the task
            // re-fires with fresh data when the tab becomes visible again.
            guard isActive else { return }
            let sections = await computeSections()
            withAnimation(sectionsReady ? nil : .easeOut(duration: 0.25)) {
                nextUp = sections.nextUp
                recentShows = sections.recentShows
                downloaded = sections.downloaded
                sectionsReady = true
            }
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
        return await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)
    }

    // MARK: - Queue (user-managed)

    @ViewBuilder
    private var queueSection: some View {
        // Show only the resolvable ids (skip orphaned entries silently — the
        // reorder page cleans them up on play).
        let items = queue.ids.compactMap { AppSession.shared.libraryItem(forId: $0) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Up Next").font(.title3).bold()
                    Spacer()
                    NavigationLink(value: PodcastRoute.queue) {
                        Text("Edit")
                    }
                }
                .padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(items.prefix(5)) { item in
                        PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                        Divider().padding(.leading, 88)
                    }
                }
            }
        }
    }

    // MARK: - Up Next (large cards, one per show)

    @ViewBuilder
    private var nextUpSection: some View {
        if !nextUp.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Continue").font(.title2).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(nextUp) { item in
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

    @ViewBuilder
    private var recommendationsSection: some View {
        if !recommendations.results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recommended").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(recommendations.results) { r in recommendationTile(r) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func recommendationTile(_ r: PodcastSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                podcastArtwork(url: r.artworkURL.flatMap { URL(string: $0) }, size: 132, corner: 14)
                subscribeControl(r).padding(6)
            }
            Text(r.title).font(.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .frame(width: 132, alignment: .leading)
        }
        .contextMenu {
            Button {
                subscribingRec.insert(r.feedURL)
                Task {
                    await subscribeRecommendation(r.feedURL)
                    recommendations.remove(feedURL: r.feedURL)
                    subscribingRec.remove(r.feedURL)
                }
            } label: { Label("Subscribe", systemImage: "plus.circle") }
            Button {
                UIPasteboard.general.string = r.feedURL
            } label: { Label("Copy Feed URL", systemImage: "doc.on.doc") }
        }
    }

    @ViewBuilder
    private func subscribeControl(_ r: PodcastSearchResult) -> some View {
        if subscribingRec.contains(r.feedURL) {
            ProgressView().controlSize(.small)
                .padding(4).background(Circle().fill(.black.opacity(0.35)))
        } else {
            Button {
                subscribingRec.insert(r.feedURL)
                Task {
                    await subscribeRecommendation(r.feedURL)
                    recommendations.remove(feedURL: r.feedURL)
                    subscribingRec.remove(r.feedURL)
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3).foregroundStyle(.white, AppTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func subscribeRecommendation(_ feedURL: String) async {
        if AppStorageKeys.absPodcastsEnabledValue, absPodcast.hasPodcasts {
            _ = await absPodcast.subscribeOnServer(feedURL: feedURL)
        } else {
            _ = await subs.subscribe(urlString: feedURL)
            await GPodderSync.shared.reconcile()
        }
    }

    // MARK: - Recently updated (show grid, 2 columns)

    @ViewBuilder
    private var recentlyUpdatedSection: some View {
        if !recentShows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recently Updated").font(.title3).bold().padding(.horizontal)
                // D6/B5: adaptive columns instead of a fixed pair — on iPads the
                // two flexible columns blew the tiles up to ~500pt covers.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 14)],
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(recentShows) { info in
                        NavigationLink(value: PodcastRoute.show(feedURL: info.show.feedURL)) {
                            recentTile(info)
                        }
                        .buttonStyle(.plain)
                        .podcastShowMenu(info.show)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// A show is unusable offline when none of its episodes is downloaded —
    /// same dimming convention as the featured cards.
    private func isOfflineUnavailable(_ show: PodcastShow) -> Bool {
        guard !networkMonitor.isConnected else { return false }
        return !show.episodes.contains { DownloadManager.shared.isDownloaded(itemId: $0.guid) }
    }

    private func recentTile(_ info: RecentShowInfo) -> some View {
        let unavailable = isOfflineUnavailable(info.show)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(url: info.show.artworkURL.flatMap { URL(string: $0) }, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "mic").foregroundStyle(.secondary))
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(unavailable ? 0.5 : 1)
                .overlay(alignment: .topLeading) {
                    if unavailable {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.white, .secondary)
                            .padding(8)
                    }
                }

                if info.newCount > 0 {
                    Text("\(info.newCount)")
                        .font(.caption2.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.red))
                        .padding(7)
                }
            }
            Text(info.show.title)
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(Date(timeIntervalSince1970: info.lastUpdated / 1000)
                    .formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Premium (private/paid feeds)

    /// Premium if basic-auth credentials are stored OR the feed URL looks like
    /// private/paid access (token in the query or a known premium host).
    private func isPremium(_ show: PodcastShow) -> Bool {
        if PodcastFeedAuth.hasCredentials(feedKey: PodcastSubscriptions.feedKey(show.feedURL)) {
            return true
        }
        let url = show.feedURL.lowercased()
        let hosts = ["patreon.com", "supercast", "supportingcast", "memberful", "acast.com/access"]
        if hosts.contains(where: { url.contains($0) }) { return true }
        if let items = URLComponents(string: show.feedURL)?.queryItems,
           items.contains(where: { ["auth", "token", "key", "secret"].contains($0.name.lowercased()) }) {
            return true
        }
        return false
    }

    @ViewBuilder
    private var premiumSection: some View {
        let shows = allShows.filter { isPremium($0) }
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Premium", systemImage: "lock.fill")
                    .font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
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
            }
        }
    }

    // MARK: - Downloaded (3 rows, horizontally scrollable)

    @ViewBuilder
    private var downloadedShelf: some View {
        if !downloaded.isEmpty {
            // Collapsed by default so the section doesn't dominate the page.
            let limit = horizontalSizeClass == .regular ? 6 : 3
            let shown = downloadedExpanded ? downloaded : Array(downloaded.prefix(limit))
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloaded").font(.title3).bold().padding(.horizontal)
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
