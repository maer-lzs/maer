import SwiftUI

/// Home = cross-section aggregation tab (Etappe 3). It is NOT a library — the
/// media tabs stay full libraries. Reuses ONLY existing components (Regel 2:
/// PlayQueueRow, AlbumCell) and ranks STRICTLY by timestamp via HomeSections.
/// Sections are computed from a snapshot in a `.task` (staged, E10/F5 pattern),
/// never in the body.
struct HomeView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    var isActive: Bool = true
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject private var queue = PlayQueue.shared

    /// Recency-ordered ids of in-progress books + episodes — resolved to the
    /// matching FeaturedCard (book vs podcast) in the view (Regel 2: same cards
    /// as the library tabs, no Home-specific component).
    @State private var continueIds: [String] = []
    /// X1b "Latest Episodes": newest episode of each recently-active show, shown
    /// as episode tiles in a 2-row adaptive grid.
    @State private var recentEpisodeItems: [LibraryItem] = []
    /// Teil 3 "Rediscover": daily-rotated local picks (paused / unheard / next
    /// volume) — empty hides the section.
    @State private var rediscoverPicks: [RediscoverSections.Pick] = []
    /// Teil 5: ONE opt-out for both recommendation sections (Rediscover +
    /// Discover); the library-fact sections stay untouched.
    @AppStorage(AppStorageKeys.homeRecommendations) private var recommendationsEnabled = true
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @Environment(\.pushPodcastRoute) private var pushRoute
    @Environment(\.pushBookDetail) private var pushBook
    /// W2 "Recently Added": newly added books + albums, mixed by added time —
    /// each rendered with its own tab's tile (BookGridCell / AlbumCell).
    @State private var recentlyAddedItems: [LibraryItem] = []
    /// X1b: measured content width → adaptive column count for the episode grid.
    @State private var contentWidth: CGFloat = 0
    @State private var ready = false

    private var recomputeToken: String {
        "\(isActive)-\(libraryViewModel.entries.count)-\(libraryViewModel.continueListening.count)-\(libraryViewModel.recentlyAdded.count)-\(queue.ids.count)-\(recommendationsEnabled)"
    }

    var body: some View {
        ScrollView {
            if ready {
                // Teil 5 order: Continue (+ its planned Up Next) → Discover →
                // Latest Episodes → Rediscover → Recently Added.
                LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    continueSection
                    upNextSection
                    if recommendationsEnabled { discoverSection }
                    latestEpisodesSection
                    if recommendationsEnabled { rediscoverSection }
                    recentlyAddedSection
                    if isEmpty { emptyState }
                }
                .padding(.top, TabContentLayout.topInset)
                .bottomBarClearance()
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in contentWidth = w }
                    }
                )
                .transition(.opacity)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 280)
            }
        }
        // Home hangs on the SHARED bottom bar like every tab — only the visible
        // one reports (active-gate). Transition/feedback edge untouched.
        .reportsBottomBarScroll(active: isActive)
        .task(id: recomputeToken) {
            guard isActive else { return }
            await compute()
        }
    }

    private var isEmpty: Bool {
        continueIds.isEmpty && queue.isEmpty && recentEpisodeItems.isEmpty && recentlyAddedItems.isEmpty
    }

    /// Teil 2: adaptive column count — iPhone 3, small iPad 4, large iPad 5.
    private var episodeColumns: Int {
        guard contentWidth > 0 else { return 3 }
        if contentWidth >= 1000 { return 5 }
        if contentWidth >= 640 { return 4 }
        return 3
    }

    // MARK: - Sections (reused components only)

    /// W1 "Continue": in-progress books + episodes as the SAME large FeaturedCards
    /// the library tabs use — BookFeaturedCard for books, PodcastFeaturedCard for
    /// episodes — mixed in one horizontal carousel, ranked by last played. Cards
    /// mean "started"; the rows below (Up Next) mean "planned". No new component.
    @ViewBuilder
    private var continueSection: some View {
        if !continueIds.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Continue").font(.title2).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(continueIds, id: \.self) { id in
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
        if let entry = libraryViewModel.entries.first(where: { $0.id == id }) {
            BookFeaturedCard(entry: entry,
                             playerCoordinator: playerCoordinator,
                             libraryViewModel: libraryViewModel)
        } else if let item = AppSession.shared.libraryItem(forId: id) {
            PodcastFeaturedCard(item: item, playerCoordinator: playerCoordinator)
        }
    }

    /// "Up Next" — the global PlayQueue, same row component as the queue page.
    @ViewBuilder
    private var upNextSection: some View {
        let items = queue.ids.compactMap { AppSession.shared.libraryItem(forId: $0) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next").font(.title3).bold().padding(.horizontal)
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

    /// X1b/Teil 2 "Latest Episodes": the newest episode of each recently-active
    /// show as MediaTiles in a vertical grid — capped at ALWAYS 2 rows, columns
    /// adaptive (iPhone 3, small iPad 4, large iPad 5 → 6/8/10 tiles). Image =
    /// the episode's own artwork when the feed ships one (the provider already
    /// prefers it), with the show cover as the corner badge ONLY when it
    /// differs (nothing doubled). Tap → episode page; play badge plays.
    @ViewBuilder
    private var latestEpisodesSection: some View {
        if !recentEpisodeItems.isEmpty {
            let cols = episodeColumns
            let shown = Array(recentEpisodeItems.prefix(cols * 2))   // always 2 rows
            VStack(alignment: .leading, spacing: 10) {
                Text("Latest Episodes").font(.title3).bold().padding(.horizontal)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: cols),
                    alignment: .leading, spacing: 14
                ) {
                    ForEach(shown) { item in
                        episodeTile(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func episodeTile(_ item: LibraryItem) -> some View {
        MediaTile(
            title: item.title,
            coverURL: AppSession.shared.coverURL(forItemId: item.id),
            cornerBadgeURL: showBadgeURL(for: item),
            progress: episodeProgress(item),
            onTap: { pushRoute(.episode(itemId: item.id)) }
        ) {
            MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
        }
        .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator)
    }

    /// The show cover as a corner badge only when the tile image is the
    /// episode's OWN artwork (feed-provided) — never double the show cover.
    private func showBadgeURL(for item: LibraryItem) -> URL? {
        guard let show = AppSession.shared.rssProvider.show(forEpisodeId: item.id),
              let raw = show.artworkURL, let url = URL(string: raw),
              url != AppSession.shared.coverURL(forItemId: item.id)
        else { return nil }
        return url
    }

    private func episodeProgress(_ item: LibraryItem) -> Double? {
        if case .inProgress(let fraction, _) = podcastPlayState(for: item) { return fraction }
        return nil
    }

    /// Teil 4 "Discover" (stage 1: podcast shows): one row from the existing
    /// RecommendationsStore (PodcastIndex/charts, same as the podcast tab),
    /// with an HONEST reason as the subtitle — derived locally only. Already
    /// subscribed shows never appear (filtered again at render time, the pool
    /// may predate a subscription). The corner control is the SAME subscribe
    /// flow as the podcast tab's Discover grid; the tile tap opens that grid.
    @ViewBuilder
    private var discoverSection: some View {
        let subscribed = Set((subs.shows + ABSPodcastProvider.shared.shows)
            .map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let shown = Array(PodcastRecommendationsStore.excludingSubscribed(
            recommendations.results, subscribedNormalizedFeeds: subscribed
        ).prefix(episodeColumns))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Discover").font(.title3).bold().padding(.horizontal)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: episodeColumns),
                    alignment: .leading, spacing: 14
                ) {
                    ForEach(shown) { result in
                        MediaTile(
                            title: result.title,
                            subtitle: reasonText(recommendations.reason(for: result)),
                            coverURL: result.artworkURL.flatMap { URL(string: $0) },
                            onTap: { pushRoute(.discover) }
                        ) {
                            PodcastSubscribeBadge(feedURL: result.feedURL)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func reasonText(_ reason: PodcastRecommendationsStore.Reason) -> String {
        switch reason {
        case .sameAuthor(let author): return String(localized: "Because you listen to \(author)")
        case .genre(let genre): return String(localized: "Because you listen to \(genre)")
        case .popular: return String(localized: "Popular")
        }
    }

    /// Teil 3 "Rediscover": one row of daily-rotated local picks. Hidden when
    /// there are no candidates.
    @ViewBuilder
    private var rediscoverSection: some View {
        let shown = Array(rediscoverPicks.prefix(episodeColumns))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rediscover").font(.title3).bold().padding(.horizontal)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: episodeColumns),
                    alignment: .leading, spacing: 14
                ) {
                    ForEach(shown, id: \.id) { pick in
                        rediscoverTile(pick)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func rediscoverTile(_ pick: RediscoverSections.Pick) -> some View {
        if let entry = libraryViewModel.entries.first(where: { $0.id == pick.id }) {
            MediaTile(
                title: entry.item.title,
                subtitle: rediscoverSubtitle(pick.reason),
                coverURL: AppSession.shared.coverURL(forItemId: entry.id),
                placeholderSystemImage: "book.closed",
                progress: (entry.progress?.isStarted ?? false) ? entry.progress?.fraction : nil,
                onTap: { pushBook(entry.id) }
            ) {
                MediaTilePlayBadge { Task { await playerCoordinator.open(item: entry.item) } }
            }
        } else if let item = AppSession.shared.libraryItem(forId: pick.id) {
            MediaTile(
                title: item.title,
                subtitle: rediscoverSubtitle(pick.reason),
                coverURL: AppSession.shared.coverURL(forItemId: item.id),
                progress: episodeProgress(item),
                onTap: { pushRoute(.episode(itemId: item.id)) }
            ) {
                MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
            }
        }
    }

    private func rediscoverSubtitle(_ reason: RediscoverSections.Reason) -> String {
        switch reason {
        case .paused(let weeks):
            return String(localized: "Paused for \(weeks) weeks")
        case .unheardSince(let added):
            return String(localized: "Unheard since \(added.formatted(.dateTime.month(.wide).year()))")
        case .nextInSeries(let volume):
            return volume > 0
                ? String(localized: "Volume \(volume) of your series")
                : String(localized: "Next volume of your series")
        }
    }

    /// W2 "Recently Added": newly added books AND albums in one horizontal shelf,
    /// ranked by added time. Each tile is its own tab's component — BookGridCell
    /// for a book, AlbumCell for an album — at one shared width so the mixed row
    /// stays even (Regel 2: no Home-specific tile).
    @ViewBuilder
    private var recentlyAddedSection: some View {
        if !recentlyAddedItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recently Added").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    // Eager HStack (like the library tab's shelf): the lazy variant
                    // froze the shelf height on the first cell and clipped taller ones.
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(recentlyAddedItems) { item in
                            recentlyAddedTile(item)
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
        if let entry = libraryViewModel.entries.first(where: { $0.id == item.id }) {
            BookGridCell(entry: entry, width: 150,
                         playerCoordinator: playerCoordinator, libraryViewModel: libraryViewModel)
        } else {
            AlbumCell(item: item, width: 150, playerCoordinator: playerCoordinator)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing here yet",
            systemImage: "house",
            description: Text("Start listening — your books, podcasts and music show up here.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: - Snapshot compute (off the body)

    private func compute() async {
        let shows = PodcastAutoContinue.allShows()
        let snapshot = PodcastSections.snapshot(shows: shows)
        let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)

        // Weiterhören: in-progress books + in-progress episodes, by last played.
        let books = libraryViewModel.continueListening.map {
            (id: $0.id, ts: $0.progress?.lastUpdate ?? 0)
        }
        let episodes = sections.nextUp.map { (id: $0.id, ts: localTimestamp($0.id)) }
        let rankedContinue = HomeSections.byRecency([books, episodes], limit: 8)

        // X1b "Latest Episodes": the newest episode of each show, newest first —
        // one per show so a daily show doesn't dominate. Capped generously; the
        // section itself shows only 2 rows.
        let newestEpisodeIds = shows.compactMap { show -> (id: String, ts: Double)? in
            guard let ep = show.episodes.max(by: { $0.pubDate < $1.pubDate }) else { return nil }
            return (ep.guid, ep.pubDate)
        }
        let episodeIds = HomeSections.byRecency([newestEpisodeIds], limit: 8)

        // W2/X1a "Recently Added": newly added books + newly added albums (the
        // "newest" shelf, best-effort — empty without a music server). Both inputs
        // are already recency-ordered; a FAIR interleave keeps both libraries
        // present (a pure time sort let the music library's fresher timestamps take
        // every slot, so books vanished).
        let bookItems = libraryViewModel.recentlyAdded.map(\.item)
        let newAlbums = (try? await SubsonicProvider.shared.albumShelf(type: "newest", size: 12)) ?? []
        let byId = Dictionary((bookItems + newAlbums).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mergedIds = HomeSections.interleave([bookItems.map(\.id), newAlbums.map(\.id)], limit: 12)

        continueIds = rankedContinue
        recentEpisodeItems = episodeIds.compactMap { AppSession.shared.libraryItem(forId: $0) }
        recentlyAddedItems = mergedIds.compactMap { byId[$0] }
        if recommendationsEnabled {
            rediscoverPicks = computeRediscover(
                bookContinue: books, episodeContinue: episodes, visibleContinue: Set(rankedContinue))
            await recommendations.refreshIfNeeded()
        } else {
            rediscoverPicks = []
        }
        withAnimation(ready ? nil : .easeOut(duration: 0.25)) { ready = true }
    }

    /// Teil 3: assemble the three candidate sources (mixed media types) and let
    /// the pure logic pick — timestamps normalized to seconds.
    private func computeRediscover(
        bookContinue: [(id: String, ts: Double)],
        episodeContinue: [(id: String, ts: Double)],
        visibleContinue: Set<String>
    ) -> [RediscoverSections.Pick] {
        // (a) paused: started books + episodes, EXCLUDING what the Continue
        // carousel already shows (no doubles on one page).
        let paused = (bookContinue + episodeContinue)
            .filter { !visibleContinue.contains($0.id) }
            .map { (id: $0.id, lastPlayed: Self.seconds($0.ts)) }
        // (b) unheard additions (books; albums have no reliable local addedAt).
        let unheard = libraryViewModel.entries
            .filter { !($0.progress?.isStarted ?? false) && !($0.progress?.isFinished ?? false) }
            .compactMap { entry -> (id: String, addedAt: Double)? in
                guard let added = entry.item.addedAt else { return nil }
                return (entry.id, Self.seconds(added))
            }
        // (c) the next UNSTARTED volume after a finished predecessor.
        let seriesNext = libraryViewModel.entries
            .filter { $0.progress?.isFinished ?? false }
            .compactMap { finished -> (id: String, volume: Int)? in
                guard let next = libraryViewModel.nextInSeries(after: finished.id),
                      !(next.progress?.isStarted ?? false) else { return nil }
                return (next.id, RediscoverSections.volume(fromSeriesName: next.item.media?.metadata?.seriesName) ?? 0)
            }
        let now = Date()
        return RediscoverSections.picks(
            paused: paused, unheard: unheard, seriesNext: seriesNext,
            now: now, daySeed: RediscoverSections.daySeed(for: now),
            limit: episodeColumns)
    }

    /// ABS timestamps are milliseconds since 1970 — normalize to seconds.
    private static func seconds(_ ts: Double) -> Double {
        ts > 4_000_000_000 ? ts / 1000 : ts
    }

    /// Last-played timestamp of an item from the local position store (same
    /// source podcast auto-continue uses), 0 if none.
    private func localTimestamp(_ id: String) -> Double {
        (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(id)) as? [Double])?.last ?? 0
    }
}
