import SwiftUI
import Combine
import UIKit

/// A tile in "Recently updated" (Apple Podcasts style): show + time of the last
/// update + number of new episodes since the last played one.
struct RecentShowInfo: Identifiable {
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
    @ObservedObject private var subs = PodcastSubscriptions.shared
    // Sections depend on progress (played/in progress) and downloads — observe
    // both so "Up Next"/"Downloaded"/"Played" rebuild live.
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @ObservedObject private var queue = PodcastQueue.shared
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @State private var subscribingRec: Set<String> = []

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

    /// Recompute when subscriptions, downloads or progress change.
    private var recomputeToken: String {
        "\(subs.shows.count)-\(downloads.downloadedItemIds.count)-\(progress.changeToken)-\(absPodcast.changeToken)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                nextUpSection
                recommendationsSection
                queueSection
                premiumSection
                downloadedShelf
                recentlyUpdatedSection
            }
            .padding(.top, 8)
            .bottomBarClearance()
        }
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
        .reportsBottomBarScroll()   // einklappbare Bottom-Zone
        .refreshable {
            await subs.refreshAll()
            await absPodcast.refresh()
        }
        .task {
            await absPodcast.refresh()                       // ABS-Podcasts laden
            await GPodderSync.shared.autoReconcileIfNeeded()       // gpodder-Abos abgleichen
            await PodcastSubscriptionSync.autoReconcileIfNeeded()  // lokale Abos spiegeln
            await recommendations.refreshIfNeeded()               // Empfehlungen (extern)
        }
        .task(id: recomputeToken) {
            nextUp = computeNextUp()
            recentShows = computeRecentShows()
            downloaded = computeDownloaded()
            // Kartenfarben vorab berechnen → beim Scrollen passiert nichts mehr.
            for item in nextUp {
                await CoverColorLoader.prewarm(url: AppSession.shared.coverURL(forItemId: item.id))
            }
            // Neue Folgen aktivierter Shows im Hintergrund lokal laden.
            await PodcastAutoDownload.run(shows: allShows)
        }
    }

    /// "Continue": ONLY started (in-progress) episodes, sorted by the last
    /// listening time (as with audiobooks) — not by pub date. Finished ones drop
    /// out automatically. Discovering new is what "Recently updated" is for.
    private func computeNextUp() -> [LibraryItem] {
        var picks: [(item: LibraryItem, playedAt: Double)] = []
        for show in allShows {
            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                guard case .inProgress = podcastPlayState(for: item) else { continue }
                let localTs = (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double])?.last ?? 0
                let absTs = ABSPodcastProvider.shared.episodeProgress[item.id]?.lastUpdate ?? 0
                picks.append((item, max(localTs, absTs)))
            }
        }
        return picks.sorted { $0.playedAt > $1.playedAt }.prefix(10).map { $0.item }
    }

    /// "Recently updated": all shows sorted by the time of the newest episode,
    /// with the number of new (unplayed) episodes since the last played one. No
    /// more endless episode lists — a show grid.
    private func computeRecentShows() -> [RecentShowInfo] {
        var infos: [RecentShowInfo] = []
        for show in allShows {
            if AppStorageKeys.podcastInboxModeValue(show.id) == "off" { continue }
            guard let newest = show.episodes.map(\.pubDate).max(), newest > 0 else { continue }
            infos.append(RecentShowInfo(show: show, lastUpdated: newest,
                                        newCount: newEpisodeCount(show)))
        }
        return infos.sorted { $0.lastUpdated > $1.lastUpdated }
    }

    /// New episodes since the last played one: number of unplayed episodes that
    /// are NEWER than the most recent already-played one. Without any played
    /// episode, all unplayed ones count.
    private func newEpisodeCount(_ show: PodcastShow) -> Int {
        let items = show.episodes.map { podcastLibraryItem(show: show, episode: $0) }
        let lastPlayed = items
            .filter { podcastPlayState(for: $0) == .played }
            .map { $0.addedAt ?? 0 }
            .max()
        if let lastPlayed {
            return items.filter { ($0.addedAt ?? 0) > lastPlayed && podcastPlayState(for: $0) == .unplayed }.count
        }
        return items.filter { podcastPlayState(for: $0) == .unplayed }.count
    }

    /// "Downloaded" cross-source: all episodes downloaded on the device.
    private func computeDownloaded() -> [LibraryItem] {
        let ids = downloads.downloadedItemIds
        guard !ids.isEmpty else { return [] }
        return allShows
            .flatMap { show in show.episodes.map { podcastLibraryItem(show: show, episode: $0) } }
            .filter { ids.contains($0.id) }
            .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
    }

    // MARK: - Queue (nutzer-verwaltete Warteschlange)

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
                    NavigationLink {
                        PodcastQueueView(playerCoordinator: playerCoordinator)
                    } label: {
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
            Text(r.title).font(.caption).lineLimit(2).frame(width: 132, alignment: .leading)
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

    // MARK: - Zuletzt aktualisiert (Show-Grid, 2 Spalten)

    @ViewBuilder
    private var recentlyUpdatedSection: some View {
        if !recentShows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recently Updated").font(.title3).bold().padding(.horizontal)
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(recentShows) { info in
                        NavigationLink {
                            PodcastShowView(show: info.show, playerCoordinator: playerCoordinator)
                        } label: {
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

    private func recentTile(_ info: RecentShowInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

    // MARK: - Premium (private/bezahlte Feeds)

    /// Premium, wenn Basic-Auth-Zugangsdaten hinterlegt sind ODER die Feed-URL
    /// nach privatem/bezahltem Zugang aussieht (Token im Query bzw. bekannter
    /// Premium-Host).
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
                            NavigationLink {
                                PodcastShowView(show: show, playerCoordinator: playerCoordinator)
                            } label: {
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

    // MARK: - Geladen (3 Reihen, seitlich scrollbar)

    @ViewBuilder
    private var downloadedShelf: some View {
        if !downloaded.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloaded").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    // Reihenzahl an die Menge anpassen (1 Download → 1 Reihe);
                    // jede Spalte nutzt die volle Bildschirmbreite.
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(84), spacing: 4),
                                          count: max(1, min(3, downloaded.count))),
                              spacing: 12) {
                        ForEach(downloaded) { item in
                            PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}
