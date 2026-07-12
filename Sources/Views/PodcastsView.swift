import SwiftUI
import Combine

/// Eine Show-Gruppe in „Neue Folgen": die neuesten ungehörten Folgen einer
/// Show, gedeckelt — damit ein Vielsender nicht die ganze Inbox flutet.
struct InboxGroup: Identifiable {
    let show: PodcastShow
    let items: [LibraryItem]
    var id: String { show.id }
}

/// Podcast-Tab im Stil von Apple Podcasts: oben eine Reihe großer
/// „Als Nächstes"-Karten (neueste Folgen als Blickfang), darunter eine
/// kompakte Show-Reihe zum Blättern und die vollständige Folgen-Liste.
/// Episoden sind normale `LibraryItem`s und laufen über den Coordinator.
struct PodcastsView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// Scroll-Offset an die Bibliothek melden (für die einklappbare Bottom-Zone).
    var onScroll: ((CGFloat) -> Void)? = nil
    @ObservedObject private var subs = PodcastSubscriptions.shared
    // Sektionen hängen an Fortschritt (gehört/läuft) und Downloads — beide
    // beobachten, damit sich „Als Nächstes"/„Geladen"/„Gehört" live neu bauen.
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @ObservedObject private var queue = PodcastQueue.shared
    @ObservedObject private var recommendations = PodcastRecommendationsStore.shared
    @State private var subscribingRec: Set<String> = []

    /// Shows aller Podcast-Quellen (RSS + ABS), dedupliziert über die
    /// normalisierte Feed-URL — bei Dopplung wird die ABS-Show (synchronisiert)
    /// bevorzugt.
    private var allShows: [PodcastShow] {
        let abs = absPodcast.activeShows
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = subs.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    // Sektions-Inhalte werden NICHT synchron im Body berechnet (das ruckelte
    // beim Tab-Wechsel), sondern in einem `.task` gefüllt — der Tab erscheint
    // sofort, die Sektionen kommen einen Frame später.
    @State private var nextUp: [LibraryItem] = []           // „Continue" (große Karten)
    @State private var inboxGroups: [InboxGroup] = []       // „Neue Folgen", nach Show gruppiert
    @State private var downloaded: [LibraryItem] = []
    @State private var showAddPodcasts = false

    /// Neu berechnen, wenn sich Abos, Downloads oder Fortschritt ändern.
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
                showsShelf
                inboxSection
                if !downloaded.isEmpty { episodeListSection(title: "Downloaded", episodes: downloaded) }
            }
            .padding(.top, 8)
            .bottomBarClearance()
        }
        // Kein Abo → statt blank ein Leer-Zustand mit Weg zum Hinzufügen/Import.
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
        // Scroll-Offset an die Bibliothek melden (einklappbare Bottom-Zone).
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            onScroll?(y)
        }
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
            inboxGroups = computeInboxGroups()
            downloaded = computeDownloaded()
            // Kartenfarben vorab berechnen → beim Scrollen passiert nichts mehr.
            for item in nextUp {
                await CoverColorLoader.prewarm(url: AppSession.shared.coverURL(forItemId: item.id))
            }
            // Neue Folgen aktivierter Shows im Hintergrund lokal laden.
            await PodcastAutoDownload.run(shows: allShows)
        }
    }

    /// „Als Nächstes" quellen-übergreifend: pro Show die laufende bzw. nächste
    /// ungehörte Folge (chronologisch weiter), sonst die älteste ungehörte.
    private func computeNextUp() -> [LibraryItem] {
        var picks: [(item: LibraryItem, date: Double)] = []
        for show in allShows {
            let items = show.episodes
                .sorted { $0.pubDate < $1.pubDate }
                .map { podcastLibraryItem(show: show, episode: $0) }
            func st(_ i: LibraryItem) -> EpisodePlayState { podcastPlayState(for: i) }

            if let running = items.last(where: {
                if case .inProgress = st($0) { return true } else { return false }
            }) {
                picks.append((running, running.addedAt ?? 0)); continue
            }
            let lastPlayed = items.lastIndex { st($0) == .played }
            let range = lastPlayed.map { items.index(after: $0)..<items.endIndex } ?? items.indices
            if let next = items[range].first(where: { st($0) == .unplayed }) {
                picks.append((next, next.addedAt ?? 0))
            }
        }
        // Nur die 10 aktuellsten in „Als Nächstes" — nicht jede Show.
        return picks.sorted { $0.date > $1.date }.prefix(10).map { $0.item }
    }

    /// „Neue Folgen", nach Show gruppiert: je Show die neuesten ungehörten
    /// Folgen, PRO SHOW gedeckelt (Default 3, „Nur neueste" = 1, „Aus" = weg) —
    /// so flutet kein Vielsender die Inbox. Gruppen nach Aktualität sortiert.
    private func computeInboxGroups() -> [InboxGroup] {
        var groups: [(group: InboxGroup, date: Double)] = []
        for show in allShows {
            let mode = AppStorageKeys.podcastInboxModeValue(show.id)
            if mode == "off" { continue }
            let cap = (mode == "latest") ? 1 : 3
            let unplayed = show.episodes
                .map { podcastLibraryItem(show: show, episode: $0) }
                .filter { podcastPlayState(for: $0) == .unplayed }
                .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
                .prefix(cap)
            guard !unplayed.isEmpty else { continue }
            groups.append((InboxGroup(show: show, items: Array(unplayed)),
                           unplayed.first?.addedAt ?? 0))
        }
        return groups.sorted { $0.date > $1.date }.map { $0.group }
    }

    /// „Geladen" quellen-übergreifend: alle geräteseitig heruntergeladenen Folgen.
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
        // Nur die zuflösbaren IDs zeigen (verwaiste Einträge stillschweigend
        // überspringen — die Reorder-Seite räumt sie beim Abspielen auf).
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

    // MARK: - Als Nächstes (große Karten, eine pro Show)

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

    // MARK: - Empfohlen (externe Popularität, unter den Karten)

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
                podcastArtwork(url: r.artworkURL.flatMap { URL(string: $0) }, size: 110, corner: 12)
                subscribeControl(r).padding(6)
            }
            Text(r.title).font(.caption).lineLimit(2).frame(width: 110, alignment: .leading)
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

    // MARK: - Neue Folgen (nach Show gruppiert)

    @ViewBuilder
    private var inboxSection: some View {
        if !inboxGroups.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("New Episodes").font(.title3).bold().padding(.horizontal)
                ForEach(inboxGroups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink {
                            PodcastShowView(show: group.show, playerCoordinator: playerCoordinator)
                        } label: {
                            HStack(spacing: 8) {
                                podcastArtwork(url: group.show.artworkURL.flatMap { URL(string: $0) },
                                               size: 22, corner: 5)
                                Text(group.show.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                        }
                        .buttonStyle(.plain)
                        LazyVStack(spacing: 0) {
                            ForEach(group.items) { item in
                                PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                                Divider().padding(.leading, 88)
                            }
                        }
                    }
                }
            }
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
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Sendungen (kompakte Cover-Reihe + „Alle" → Grid)

    @ViewBuilder
    private var showsShelf: some View {
        // Alle Podcast-Quellen (RSS + ABS); Kachel = nur Cover + Titel, die
        // Folgenliste baut erst die Show-Seite (lazy).
        let shows = allShows
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Shows").font(.title3).bold()
                    Spacer()
                    NavigationLink {
                        PodcastShowsGridView(shows: shows, playerCoordinator: playerCoordinator)
                    } label: {
                        Text("See All")
                    }
                }
                .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(shows) { show in
                            NavigationLink {
                                PodcastShowView(show: show, playerCoordinator: playerCoordinator)
                            } label: {
                                ShowTile(show: show)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    /// Gemeinsame Zeilenliste (Titel + `PodcastEpisodeRow` + Trenner).
    private func episodeListSection(title: LocalizedStringKey, episodes: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3).bold().padding(.horizontal)
            LazyVStack(spacing: 0) {
                ForEach(episodes) { item in
                    PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                    Divider().padding(.leading, 88)
                }
            }
        }
    }
}
