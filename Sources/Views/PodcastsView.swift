import SwiftUI
import Combine

/// Podcast-Tab im Stil von Apple Podcasts: oben eine Reihe großer
/// „Als Nächstes"-Karten (neueste Folgen als Blickfang), darunter eine
/// kompakte Show-Reihe zum Blättern und die vollständige Folgen-Liste.
/// Episoden sind normale `LibraryItem`s und laufen über den Coordinator.
struct PodcastsView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    // Sektionen hängen an Fortschritt (gehört/läuft) und Downloads — beide
    // beobachten, damit sich „Als Nächstes"/„Geladen"/„Gehört" live neu bauen.
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @ObservedObject private var queue = PodcastQueue.shared

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
    @State private var nextUp: [LibraryItem] = []           // „Als Nächstes" (große Karten)
    @State private var inboxItems: [LibraryItem] = []       // neueste ungehörte/laufende
    @State private var downloaded: [LibraryItem] = []
    @State private var inboxFilter: PodcastEpisodeFilter = .new
    @State private var showAddPodcasts = false

    /// Neu berechnen, wenn sich Abos, Downloads oder Fortschritt ändern.
    private var recomputeToken: String {
        "\(subs.shows.count)-\(downloads.downloadedItemIds.count)-\(progress.changeToken)-\(absPodcast.changeToken)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                nextUpSection
                queueSection
                inboxSection
                showsShelf
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
        .refreshable {
            await subs.refreshAll()
            await absPodcast.refresh()
        }
        .task {
            await absPodcast.refresh()                       // ABS-Podcasts laden
            await GPodderSync.shared.autoReconcileIfNeeded()       // gpodder-Abos abgleichen
            await PodcastSubscriptionSync.autoReconcileIfNeeded()  // lokale Abos spiegeln
        }
        .task(id: recomputeToken) {
            nextUp = computeNextUp()
            inboxItems = computeInbox()
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

    /// „Neue Folgen" (Inbox): neueste noch nicht abgeschlossene Folgen über alle
    /// Abos, dedupliziert, gedeckelt. Der Filter (Neu/Läuft/Geladen) wird
    /// view-seitig auf diese Basis angewandt.
    private func computeInbox() -> [LibraryItem] {
        var picks: [(item: LibraryItem, date: Double)] = []
        for show in allShows {
            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                if podcastPlayState(for: item) == .played { continue }
                picks.append((item, item.addedAt ?? 0))
            }
        }
        var seen = Set<String>()
        return picks.sorted { $0.date > $1.date }
            .filter { seen.insert($0.item.id).inserted }
            .prefix(25).map { $0.item }
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

    // MARK: - Neue Folgen (Inbox mit Filter)

    /// Basis-Inbox nach ausgewähltem Filter.
    private var filteredInbox: [LibraryItem] {
        switch inboxFilter {
        case .new:
            return inboxItems.filter { podcastPlayState(for: $0) == .unplayed }
        case .inProgress:
            return inboxItems.filter {
                if case .inProgress = podcastPlayState(for: $0) { return true } else { return false }
            }
        case .downloaded:
            return downloaded
        }
    }

    @ViewBuilder
    private var inboxSection: some View {
        if !inboxItems.isEmpty || !downloaded.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("New Episodes").font(.title3).bold().padding(.horizontal)
                Picker("Filter", selection: $inboxFilter) {
                    ForEach(PodcastEpisodeFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                let items = filteredInbox
                if items.isEmpty {
                    Text("Nothing here.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.vertical, 8)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                            Divider().padding(.leading, 88)
                        }
                    }
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
