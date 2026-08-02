// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
    /// Package 3: progress per in-progress music playlist (id → progress), so a
    /// playlist continue card can show its bar and resume at the right spot.
    @State private var musicContinueProgress: [String: BookProgress] = [:]
    /// X1b "Latest Episodes": newest episode of each recently-active show, shown
    /// as episode tiles in a 2-row adaptive grid.
    @State private var recentEpisodeItems: [LibraryItem] = []
    /// Radio on Home: recently played stations (RadioStore recents, loaded in
    /// the same compute pass as the other sections — no extra observer).
    @State private var radioRecents: [RadioStation] = []
    /// Teil 3 "Rediscover": daily-rotated local picks (paused / unheard / next
    /// volume) — empty hides the section.
    @State private var rediscoverPicks: [RediscoverSections.Pick] = []
    /// Teil 5: ONE opt-out for both recommendation sections (Rediscover +
    /// Discover); the library-fact sections stay untouched.
    @AppStorage(AppStorageKeys.homeRecommendations) private var recommendationsEnabled = true
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @ObservedObject private var subs = PodcastSubscriptions.shared
    // TF4/E1: the Home page no longer observes DownloadManager/NetworkMonitor.
    // A download-progress tick used to re-render the whole page and every
    // section; now each tile's availability lives in its own MediaAvailabilityScope.
    @Environment(\.pushPodcastRoute) private var pushRoute
    @Environment(\.pushBookDetail) private var pushBook
    /// W2 "Recently Added": newly added books + albums, mixed by added time —
    /// each rendered with its own tab's tile (BookGridCell / AlbumCell).
    @State private var recentlyAddedItems: [LibraryItem] = []
    /// 34c36e1: free-catalog row data — loaded once per session in
    /// compute() (retry rides the recompute token like everything else).
    @State private var freeCatalogRows = FreeCatalogLoader.Rows()
    @State private var freeCatalogLoaded = false
    /// 7edb21b: tapped Discover book → detail sheet (PD badge + takeover).
    @State private var discoverBookDetail: LibraryItem?

    /// M4: recently PLAYED music albums ("Zuletzt gehört (Musik)") — the
    /// provider's `.recent` shelf; empty (no music server / nothing played)
    /// hides the section.
    @State private var recentMusicItems: [LibraryItem] = []
    /// TF4/E3: the Discover row's subscribed-Set + excluding-subscribed filter,
    /// computed off the body (only when subscriptions/recommendations change)
    /// instead of on every render.
    @State private var discoverShown: [PodcastSearchResult] = []
    @State private var ready = false
    /// Kachel-Auftrag: column counts of the horizontal rows per width class.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// TF4/E4: explicit height for the lazy "Recently Added" cells — the fixed
    /// 150 cover plus a Dynamic-Type-scaling text block, so every cell matches
    /// and none clips. (Device candidate: the text allowance.)
    @ScaledMetric(relativeTo: .caption) private var recentlyAddedTextHeight: CGFloat = 70
    private var recentlyAddedCellHeight: CGFloat { 150 + recentlyAddedTextHeight }

    /// TF4/E3: recompute the Discover row only when its inputs change.
    private var discoverToken: String {
        // #51 V1 (tab parity with the podcast tab's snapshot): the store's
        // CONTENT version instead of the count — same-size replacements used
        // to leave the Discover row stale. #51 W1: the sibling inputs use
        // content identity too — a swapped subscription at equal count must
        // still recompute (ContentToken, class-B convention).
        let feeds = ContentToken.of((subs.shows + ABSPodcastProvider.shared.shows)
            .map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        return "\(recommendationsEnabled)-\(recommendations.contentVersion)-\(feeds)"
    }

    private func recomputeDiscover() {
        guard recommendationsEnabled else { discoverShown = []; return }
        let subscribed = Set((subs.shows + ABSPodcastProvider.shared.shows)
            .map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let fresh = PodcastRecommendationsStore.excludingSubscribed(
            recommendations.results, subscribedNormalizedFeeds: subscribed)
        // Layout-shift: the whole-section insert (2nd from top) routes through
        // the calm gate — empty→filled IS the shift, so no immediate path here.
        BottomBarState.shared.runWhenCalm { discoverShown = fresh }
    }

    private var recomputeToken: String {
        "\(isActive)-\(libraryViewModel.entries.count)-\(libraryViewModel.continueListening.count)-\(libraryViewModel.recentlyAdded.count)-\(queue.ids.count)-\(recommendationsEnabled)"
    }

    var body: some View {
        ScrollView {
            if ready {
                // Y1 order: Continue → Discover → Up Next → Latest Episodes →
                // Rediscover → Recently Added.
                LazyVStack(alignment: .leading, spacing: TabContentLayout.sectionSpacing) {
                    continueSection
                    if recommendationsEnabled { discoverSection }
                    // 0714d26/34c36e1: free-catalog rows — data loads in
                    // compute() (a lazy below-the-fold view never ran its
                    // own task reliably), rows render dumb.
                    FreeCatalogRows(playerCoordinator: playerCoordinator,
                                    freeMusic: freeCatalogRows.freeMusic,
                                    classical: freeCatalogRows.classical)
                    upNextSection
                    radioSection
                    latestEpisodesSection
                    if recommendationsEnabled { rediscoverSection }
                    recentMusicSection
                    recentlyAddedSection
                    if isEmpty { emptyState }
                }
                .padding(.top, TabContentLayout.topInset)
                .bottomBarClearance()
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
        // E3: recompute the Discover filter only when its inputs change.
        .task(id: discoverToken) { recomputeDiscover() }
        .sheet(item: $discoverBookDetail) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
        }
    }

    private var isEmpty: Bool {
        continueIds.isEmpty && queue.isEmpty && recentEpisodeItems.isEmpty && recentlyAddedItems.isEmpty
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
        if let entry = libraryViewModel.entry(id: id) {
            BookFeaturedCard(entry: entry,
                             playerCoordinator: playerCoordinator,
                             libraryViewModel: libraryViewModel)
        } else if AppSession.shared.musicProvider.owns(itemId: id),
                  [.playlist, .album].contains(AppSession.shared.musicProvider.kind(of: id)),
                  let item = AppSession.shared.libraryItem(forId: id) {
            // Package 3 + M1: playlists AND albums resume here (mosaic for
            // playlists, the album cover for albums — the card degrades to a
            // single-cover fill on its own).
            MusicContinueCard(item: item,
                              progress: musicContinueProgress[id],
                              playerCoordinator: playerCoordinator)
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

    /// Radio on Home: "recently listened" stations as the SAME card row the
    /// radio tab uses (`RadioCardRow`) — the fourth media type joins the hub.
    /// Placed after Up Next (planned queue) and before Latest Episodes, like a
    /// "recently used" shelf. Unlike the radio tab, favorites are NOT filtered
    /// out — Home has no favorites list to duplicate against.
    @ViewBuilder
    private var radioSection: some View {
        if RadioHomePresentation.showsSection(radioActive: RadioProvider.shared.isAvailable,
                                              recentsCount: radioRecents.count) {
            RadioCardRow(title: String(localized: "Radio"),
                         stations: radioRecents,
                         playerCoordinator: playerCoordinator)
        }
    }

    /// X1b/X1c "Latest Episodes" — see `LatestEpisodesGrid` (shared with the
    /// podcast tab).
    @ViewBuilder
    private var latestEpisodesSection: some View {
        if !recentEpisodeItems.isEmpty {
            // X1c: the SHARED grid — identical on the podcast tab (Regel 2).
            LatestEpisodesGrid(items: recentEpisodeItems, playerCoordinator: playerCoordinator)
        }
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
        // E3: the subscribed-Set + filter are computed off the body (discoverToken);
        // the section only reads the result.
        let shown = discoverShown
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Discover").font(.title3).bold().padding(.horizontal)
                // Y2a: horizontally scrollable, the FULL recommendation pool —
                // one shared tile with the podcast tab (RecommendationTile);
                // its tap opens the temporary show preview.
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        // 7edb21b: LibriVox books mix in at a moderate share
                        // (pure discoverMix, cap 3) with the honest Discover-
                        // style reason line; tap opens the detail sheet.
                        let mixed = FreeCatalog.discoverMix(
                            recommendations: shown, books: freeCatalogRows.discoverBooks)
                        ForEach(Array(mixed.enumerated()), id: \.offset) { _, slot in
                            Group {
                                if let result = slot.rec {
                                    RecommendationTile(
                                        result: result,
                                        subtitle: reasonText(recommendations.reason(for: result)))
                                } else if let book = slot.book {
                                    MediaTile(
                                        title: book.title,
                                        subtitle: String(localized: "Public domain · LibriVox"),
                                        coverURL: AppSession.shared.coverURL(forItemId: book.id),
                                        placeholderSystemImage: "book.closed",
                                        onTap: { discoverBookDetail = book }
                                    )
                                }
                            }
                            // Kachel-Auftrag: screen-relative slots + peek.
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

    private func reasonText(_ reason: PodcastRecommendationsStore.Reason) -> String {
        switch reason {
        case .sameAuthor(let author): return String(localized: "Because you listen to \(author)")
        case .genre(let genre): return String(localized: "Because you listen to \(genre)")
        case .popular: return String(localized: "Popular")
        }
    }

    /// Teil 3/Y4a "Rediscover": daily-rotated local picks, horizontally
    /// scrollable with the full candidate pool. Hidden without candidates.
    @ViewBuilder
    private var rediscoverSection: some View {
        if !rediscoverPicks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rediscover").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(rediscoverPicks, id: \.id) { pick in
                            rediscoverTile(pick)
                                // Kachel-Auftrag: screen-relative slots + peek
                                // instead of the fixed 140 pt.
                                .containerRelativeFrame(.horizontal,
                                    count: CardMetrics.rediscoverColumns(regularWidth: horizontalSizeClass == .regular),
                                    span: 1, spacing: 12)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollClipDisabled()
            }
        }
    }

    @ViewBuilder
    private func rediscoverTile(_ pick: RediscoverSections.Pick) -> some View {
        // TF4/E1: the shared scope is the ONE observer of download/network state
        // for the tile; MediaTile stays value-driven off its `unavailable`.
        if let entry = libraryViewModel.entry(id: pick.id) {
            MediaAvailabilityScope(itemId: entry.id) { unavailable in
                MediaTile(
                    title: entry.item.title,
                    subtitle: rediscoverSubtitle(pick.reason),
                    coverURL: AppSession.shared.coverURL(forItemId: entry.id),
                    placeholderSystemImage: "book.closed",
                    progress: (entry.progress?.isStarted ?? false) ? entry.progress?.fraction : nil,
                    unavailable: unavailable,
                    onTap: { pushBook(entry.id) }
                ) {
                    MediaTilePlayBadge { Task { await playerCoordinator.open(item: entry.item) } }
                }
            }
        } else if let item = AppSession.shared.libraryItem(forId: pick.id) {
            MediaAvailabilityScope(itemId: item.id) { unavailable in
                MediaTile(
                    title: item.title,
                    subtitle: rediscoverSubtitle(pick.reason),
                    coverURL: AppSession.shared.coverURL(forItemId: item.id),
                    progress: episodeProgress(item),
                    unavailable: unavailable,
                    onTap: { pushRoute(.episode(itemId: item.id)) }
                ) {
                    MediaTilePlayBadge { Task { await playerCoordinator.open(item: item) } }
                }
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
                    // TF4/E4: LazyHStack (was eager). The lazy variant used to freeze
                    // the shelf height on the first cell and clip taller ones — an
                    // EXPLICIT per-cell height fixes that: the cover is a fixed 150,
                    // the text block scales with Dynamic Type, so every cell is the
                    // same height and none clips.
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(recentlyAddedItems) { item in
                            recentlyAddedTile(item)
                                .frame(width: 150, height: recentlyAddedCellHeight, alignment: .top)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    /// M4 "Zuletzt gehört (Musik)": the provider's recently-played album
    /// shelf as a horizontal AlbumCell row — the SAME shelf mechanics and
    /// cell as Recently Added (Regel 2: no Home-specific tile).
    @ViewBuilder
    private var recentMusicSection: some View {
        if !recentMusicItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recently Played (Music)").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(recentMusicItems) { item in
                            AlbumCell(item: item, width: 150, playerCoordinator: playerCoordinator)
                                .frame(width: 150, alignment: .top)
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
        if let entry = libraryViewModel.entry(id: item.id) {
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
        // Y10: the episode pool must not depend on the podcast tab having been
        // visited — Home kicks the SAME loading chain itself (tab parity).
        // Both calls are idempotent/throttled, so no double load happens when
        // the podcast tab already ran them.
        await PodcastSubscriptions.shared.ensureLoaded()
        await ABSPodcastProvider.shared.refreshIfStale()
        let shows = PodcastAutoContinue.allShows()
        let snapshot = PodcastSections.snapshot(shows: shows)
        let sections = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)

        // Weiterhören: in-progress books + in-progress episodes, by last played.
        let books = libraryViewModel.continueListening.map {
            (id: $0.id, ts: $0.progress?.lastUpdate ?? 0)
        }
        let episodes = sections.nextUp.map { (id: $0.id, ts: localTimestamp($0.id)) }
        // Package 3: in-progress music playlists as a THIRD stream (no merge
        // rewrite — byRecency already takes N streams). Keep the progress map so
        // the playlist card can render its bar + resume.
        let musicProvider = AppSession.shared.musicProvider
        let musicProgress = (try? await musicProvider.fetchAllProgress()) ?? [:]
        // M1: albums join playlists in the continue stream (same machinery).
        let music = musicProgress
            .filter { key, value in
                let kind = musicProvider.kind(of: key)
                return (kind == .playlist || kind == .album) && value.isStarted
            }
            .map { (id: $0.key, ts: $0.value.lastUpdate) }
        // 6c52b67/a9ad69e: row limit 10 (landscape/iPad show 4–5 cards),
        // music share capped at 2 via the pure rule (exception inside).
        let musicIds = Set(music.map(\.id))
        let rankedContinue = HomeSections.cappedShare(
            HomeSections.byRecency([books, episodes, music], limit: 24),
            capped: musicIds, cap: HomeSections.continueMusicCap, limit: 10)

        // Radio on Home: cheap sync read; empty when the source is off, so the
        // pure gating hides the section (no placeholder). Applied with the
        // other sections through the calm gate below.
        let radio = RadioProvider.shared.isAvailable ? RadioStore.recents() : []

        // X1b/X1c "Latest Episodes": the newest episode of each show, newest
        // first — the shared pure derivation (cap 30 so the Y3a six-row
        // expansion actually has content; the old 8-cap starved it).
        let episodeIds = PodcastSections.newestPerShow(shows: shows)

        // W2/X1a "Recently Added": newly added books + newly added albums (the
        // "newest" shelf, best-effort — empty without a music server). Both inputs
        // are already recency-ordered; a FAIR interleave keeps both libraries
        // present (a pure time sort let the music library's fresher timestamps take
        // every slot, so books vanished).
        let bookItems = libraryViewModel.recentlyAdded.map(\.item)
        let newAlbums = (try? await AppSession.shared.musicProvider.albumShelf(shelf: .newest, size: 12)) ?? []
        // M4: recently played music — the ONE provider access point again.
        let recentMusic = (try? await AppSession.shared.musicProvider.albumShelf(shelf: .recent, size: 12)) ?? []
        // 34c36e1: free-catalog rows load HERE (compute always runs) — once
        // per session, but retried while empty (a failed first pass heals on
        // the next recompute instead of deciding forever, Y37 class).
        if !freeCatalogLoaded, NetworkMonitor.shared.isConnected {
            let loadedRows = await FreeCatalogLoader.load()
            freeCatalogLoaded = !loadedRows.discoverBooks.isEmpty
                || !loadedRows.freeMusic.isEmpty || !loadedRows.classical.isEmpty
            BottomBarState.shared.runWhenCalm { freeCatalogRows = loadedRows }
        }
        let byId = Dictionary((bookItems + newAlbums).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mergedIds = HomeSections.interleave([bookItems.map(\.id), newAlbums.map(\.id)], limit: 12)

        // X26: precompute the continue-card accents before they render.
        for id in rankedContinue {
            await CoverColorLoader.prewarm(url: AppSession.shared.coverURL(forItemId: id))
        }
        let rediscover: [RediscoverSections.Pick]
        if recommendationsEnabled {
            rediscover = computeRediscover(
                bookContinue: books, episodeContinue: episodes, visibleContinue: Set(rankedContinue))
            await recommendations.refreshIfNeeded()
        } else {
            rediscover = []
        }
        let episodeItems = episodeIds.compactMap { AppSession.shared.libraryItem(forId: $0) }
        let addedItems = mergedIds.compactMap { byId[$0] }
        let initialFill = !ready
        let apply: @MainActor () -> Void = {
            radioRecents = radio
            continueIds = rankedContinue
            musicContinueProgress = musicProgress
            recentEpisodeItems = episodeItems
            recentlyAddedItems = addedItems
            recentMusicItems = recentMusic
            rediscoverPicks = rediscover
            withAnimation(initialFill ? .easeOut(duration: 0.25) : nil) { ready = true }
        }
        // Layout-shift fix: same calm gate as the other libraries — a landed
        // recompute never reshapes Home mid-scroll.
        if initialFill { apply() } else { BottomBarState.shared.runWhenCalm(apply) }
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
            limit: Self.rediscoverPoolLimit)
    }

    /// Y4a: the horizontal row carries the full pool, capped sanely.
    private static let rediscoverPoolLimit = 24

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
