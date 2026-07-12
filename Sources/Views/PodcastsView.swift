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

/// Filter für die „Neue Folgen"-Inbox.
enum PodcastEpisodeFilter: String, CaseIterable, Identifiable {
    case new, inProgress, downloaded
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .new: return "New"
        case .inProgress: return "In Progress"
        case .downloaded: return "Downloaded"
        }
    }
}

/// Vollständiges Sendungs-Grid (erreichbar über „See All" in der Shows-Reihe).
struct PodcastShowsGridView: View {
    let shows: [PodcastShow]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(shows) { show in
                    NavigationLink {
                        PodcastShowView(show: show, playerCoordinator: playerCoordinator)
                    } label: {
                        ShowTile(show: show)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .bottomBarClearance()
        }
        .navigationTitle("Shows")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Pro-Show-Einstellungen: Tempo (greift als Start-Rate), Auto-Download neuer
/// Folgen und Sortierung. Erreichbar über das Schieberegler-Symbol der Show.
struct PodcastShowSettingsSheet: View {
    let showId: String
    @Binding var newestFirst: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rate: Float?          // nil = Standard-Tempo
    @State private var autoDownload = false
    private let rates: [Float] = [0.8, 1.0, 1.1, 1.2, 1.5, 1.75, 2.0]

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback Speed") {
                    Picker("Speed", selection: $rate) {
                        Text("Default").tag(Float?.none)
                        ForEach(rates, id: \.self) { r in
                            Text(String(format: "%g×", r)).tag(Float?.some(r))
                        }
                    }
                }
                Section {
                    Toggle("Auto-download new episodes", isOn: $autoDownload)
                } footer: {
                    Text("Newly published episodes are downloaded to this device automatically.")
                }
                Section("Sort") {
                    Picker("Order", selection: $newestFirst) {
                        Label("Newest First", systemImage: "arrow.down").tag(true)
                        Label("Oldest First", systemImage: "arrow.up").tag(false)
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Podcast Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                rate = UserDefaults.standard.object(forKey: AppStorageKeys.podcastShowRate(showId)) as? Float
                autoDownload = PodcastAutoDownload.isEnabled(showId)
            }
            .onChange(of: rate) { _, new in
                let key = AppStorageKeys.podcastShowRate(showId)
                if let new { UserDefaults.standard.set(new, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            .onChange(of: autoDownload) { _, on in
                PodcastAutoDownload.setEnabled(showId, on)
            }
        }
    }
}

/// Reorderbare „Queue"-Seite: umsortieren (`.onMove`/EditButton), per Swipe
/// entfernen, Tap auf eine Zeile spielt sie (und nimmt sie aus der Queue).
struct PodcastQueueView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var queue = PodcastQueue.shared

    var body: some View {
        List {
            ForEach(queue.ids, id: \.self) { id in
                if let item = AppSession.shared.libraryItem(forId: id) {
                    PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
            .onMove { queue.move(from: $0, to: $1) }
            .onDelete { offsets in
                offsets.map { queue.ids[$0] }.forEach { queue.remove($0) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Up Next")
        .toolbar {
            if !queue.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { queue.clear() }
                }
            }
        }
        .overlay {
            if queue.isEmpty {
                ContentUnavailableView(
                    "Nothing up next",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Add episodes with Play Next or Play Last.")
                )
            }
        }
    }
}

/// Große „Als Nächstes"-Karte (Apple Podcasts): Episoden-Cover mit Show-Badge,
/// darunter eine Textfläche in der Cover-Durchschnittsfarbe (weicher Übergang
/// aus dem Bild). Tap öffnet die Folgenseite; Play-Pille + Download liegen als
/// Overlay darüber und lösen daher keine Navigation aus.
private struct PodcastFeaturedCard: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @StateObject private var colorLoader = CoverColorLoader()
    private let width: CGFloat = 235

    private var coverURL: URL? { AppSession.shared.coverURL(forItemId: item.id) }
    private var isPlayed: Bool { podcastPlayState(for: item) == .played }

    /// Show-Cover nur als Badge zeigen, wenn es sich vom Episoden-Cover
    /// unterscheidet (sonst wäre es redundant).
    private var showBadgeURL: URL? {
        guard let show = AppSession.shared.rssProvider.show(forEpisodeId: item.id),
              let raw = show.artworkURL, let url = URL(string: raw), url != coverURL
        else { return nil }
        return url
    }

    var body: some View {
        NavigationLink {
            PodcastEpisodeDetailView(item: item, playerCoordinator: playerCoordinator)
        } label: {
            cardBody
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .background(colorLoader.accent)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        // Aktionen als Overlay → eigener Tap-Bereich, keine Navigation.
        .overlay(alignment: .bottomLeading) { playPill.padding(12) }
        .overlay(alignment: .bottomTrailing) {
            PodcastDownloadButton(item: item, tint: .white).padding(14)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            podcastArtwork(url: coverURL, size: width, corner: 0, thumbnailPixel: 800)
                .opacity(isPlayed ? 0.5 : 1)
                // Bild läuft weich in die Farbfläche aus (der „blurry" Seam).
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.clear, colorLoader.accent],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: width * 0.3)
                }
                .overlay(alignment: .bottomLeading) { showBadge }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    if isPlayed { Image(systemName: "checkmark.circle.fill").font(.caption) }
                    Text(isPlayed ? String(localized: "Played") : relativeDateText(item))
                }
                .font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Text(item.title)
                    .font(.headline).foregroundStyle(.white).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let show = item.media?.metadata?.authorName {
                    Text(show).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
            .padding(14)
            .padding(.bottom, 40)   // Platz für die Overlay-Pille/Download
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var showBadge: some View {
        if let showBadgeURL {
            podcastArtwork(url: showBadgeURL, size: 44, corner: 8)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.6), lineWidth: 1))
                .padding(12)
        }
    }

    private var playPill: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.caption)
                Text(durationText(item)).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Solide, halbtransparente Kapsel statt Material-Blur — Blur ist
            // beim horizontalen Scrollen pro Frame teuer.
            .background(Capsule().fill(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// Folgenseite: Episoden-Cover + Titel, verlinkte Show, Play/Fortsetzen,
/// Download, Gehört-Umschalter und Beschreibung — Hintergrund im
/// Cover-Farbverlauf wie die Hörbuch-Detailseite.
struct PodcastEpisodeDetailView: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @StateObject private var colorLoader = CoverColorLoader()
    @State private var chapters: [ABSChapter] = []

    private var coverURL: URL? { AppSession.shared.coverURL(forItemId: item.id) }
    /// Show quellen-bewusst: ABS-Folge → aus dem ABS-Store, sonst RSS.
    private var show: PodcastShow? {
        if item.id.hasPrefix("abspod:") {
            return absPodcast.shows.first { $0.episodes.contains { $0.guid == item.id } }
        }
        return AppSession.shared.rssProvider.show(forEpisodeId: item.id)
    }
    private var state: EpisodePlayState { podcastPlayState(for: item) }
    private var isPlayed: Bool { state == .played }
    private var isInProgress: Bool {
        if case .inProgress = state { return true } else { return false }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: colorLoader.topAccent, location: 0.0),
                    .init(color: colorLoader.topAccent.opacity(0.6), location: 0.35),
                    .init(color: .black.opacity(0.85), location: 0.8)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    podcastArtwork(url: coverURL, size: 220, corner: 16)
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                        .opacity(isPlayed ? 0.6 : 1)

                    VStack(spacing: 8) {
                        Text(item.title)
                            .font(.title3.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                        showLink
                        Text(metaText)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    HStack(spacing: 14) {
                        playButton
                        PodcastDownloadButton(item: item, tint: .white)
                        markPlayedButton
                    }

                    chaptersSection

                    if let description = item.media?.metadata?.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description").font(.headline).foregroundStyle(.white)
                            Text(podcastPlainText(description))
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                .bottomBarClearance()
            }
        }
        .navigationTitle(show?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        // Kapitel lazy laden (RSS: JSON-Datei, ABS: aus dem Episoden-Objekt).
        .task(id: item.id) {
            chapters = (try? await AppSession.shared.provider(for: item.id)
                .fetchItemDetail(itemId: item.id))?.media.chapters ?? []
        }
    }

    /// Kapitelliste (Podcasting 2.0 / ABS). Tippen spielt ab dieser Stelle.
    @ViewBuilder
    private var chaptersSection: some View {
        if !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chapters").font(.headline).foregroundStyle(.white)
                ForEach(chapters) { chapter in
                    Button {
                        Task {
                            await playerCoordinator.open(item: item)
                            await playerCoordinator.viewModel?.seek(to: chapter.start)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(chapterTimestamp(chapter.start))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 52, alignment: .leading)
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Image(systemName: "play.circle")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    /// Sekunden → „m:ss" bzw. „h:mm:ss".
    private func chapterTimestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    @ViewBuilder
    private var showLink: some View {
        if let show {
            NavigationLink {
                PodcastShowView(show: show, playerCoordinator: playerCoordinator)
            } label: {
                HStack(spacing: 8) {
                    podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: 24, corner: 5)
                    Text(show.title).font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
    }

    private var playButton: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            Label(isInProgress ? String(localized: "Resume") : String(localized: "Play"),
                  systemImage: "play.fill")
                .font(.headline)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var markPlayedButton: some View {
        Button {
            podcastSetPlayed(item, !isPlayed)
        } label: {
            Image(systemName: isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlayed ? Text("Mark as Unplayed") : Text("Mark as Played"))
    }

    private var metaText: String {
        var parts: [String] = []
        let date = relativeDateText(item)
        if !date.isEmpty { parts.append(date) }
        switch state {
        case .played:
            parts.append(String(localized: "Played"))
        case .inProgress(_, let remaining):
            parts.append(String(localized: "\(Int(remaining / 60)) min left"))
        case .unplayed:
            if let duration = item.media?.duration, duration > 0 { parts.append(durationText(item)) }
        }
        return parts.joined(separator: " · ")
    }
}

/// Kompakte Show-Kachel für die Blättern-Reihe.
private struct ShowTile: View {
    let show: PodcastShow
    private let size: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: size, corner: 12)
            Text(show.title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: size, alignment: .leading)
        }
    }
}

/// Folgenliste einer Show mit Kopf (Artwork, Titel, Autor, Beschreibung).
struct PodcastShowView: View {
    let show: PodcastShow
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionExpanded = false
    @State private var showDeleteConfirm = false
    // „Ältere Folgen nachladen" (nur ABS-Shows): Feed-Folgen, die noch nicht am
    // Server liegen.
    @State private var available: [FeedEpisode] = []
    @State private var availableLoaded = false
    @State private var loadingAvailable = false
    @State private var downloading: Set<String> = []
    @State private var downloadError: String?
    @State private var loadingHistory = false
    @State private var historyResult: String?
    @State private var showSettings = false
    private var isServerShow: Bool { show.id.hasPrefix("abspod:") }

    /// Aktuelle Show aus dem Store (nicht der beim Öffnen übergebene Snapshot) —
    /// damit nachgeladene Folgen (PodcastIndex/Server) sofort erscheinen.
    private var liveShow: PodcastShow {
        if isServerShow { return absPodcast.shows.first { $0.id == show.id } ?? show }
        return subs.shows.first { $0.id == show.id } ?? show
    }
    /// Sortierrichtung pro Show gemerkt (Default: neueste zuerst).
    @AppStorage private var newestFirst: Bool

    init(show: PodcastShow, playerCoordinator: PlayerCoordinator) {
        self.show = show
        _playerCoordinator = ObservedObject(wrappedValue: playerCoordinator)
        _newestFirst = AppStorage(wrappedValue: true, "podcastSort.\(show.id)")
    }

    /// Folgen dieser Show als LibraryItems, nach Umschalter sortiert — lazy im
    /// Body (nur wenn die Seite wirklich angezeigt wird).
    private var sortedItems: [LibraryItem] {
        AppSession.shared.rssProvider.showItems(for: liveShow).sorted { a, b in
            let da = a.addedAt ?? 0, db = b.addedAt ?? 0
            return newestFirst ? da > db : da < db
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                Divider().padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(sortedItems) { item in
                        PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                        Divider().padding(.leading, 88)
                    }
                }
                if isServerShow { availableSection } else { historySection }
            }
            .padding(.top, 8)
            .bottomBarClearance()
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            }
        }
        .sheet(isPresented: $showSettings) {
            PodcastShowSettingsSheet(showId: show.id, newestFirst: $newestFirst)
        }
        .alert("Download failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) { downloadError = nil }
        } message: {
            if let downloadError { Text(downloadError) }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: 150, corner: 16)
            VStack(spacing: 4) {
                Text(show.title).font(.headline).multilineTextAlignment(.center)
                if let author = show.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let description = show.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { withAnimation { descriptionExpanded.toggle() } }
            }
            manageButton
                .font(.subheadline)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .confirmationDialog("Delete on server?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete on server", role: .destructive) {
                Task { _ = await absPodcast.deleteShowOnServer(showId: show.id); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the podcast and its listening history from the server for everyone.")
        }
    }

    /// ABS-Show: archivieren (Server bleibt) bzw. endgültig löschen; RSS-Show:
    /// lokal abbestellen.
    @ViewBuilder
    private var manageButton: some View {
        if isServerShow {
            Menu {
                Button {
                    absPodcast.setArchived(show.id, true)
                    dismiss()
                } label: {
                    Label("End subscription (archive)", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete on server", systemImage: "trash")
                }
            } label: {
                Label("Manage subscription", systemImage: "ellipsis.circle")
            }
        } else {
            Button(role: .destructive) {
                subs.unsubscribe(id: show.id)
                dismiss()
            } label: {
                Label("Unsubscribe", systemImage: "minus.circle")
            }
        }
    }

    /// Feed-Folgen, die noch nicht am Server liegen — server-seitig nachladbar
    /// (für „von Anfang an hören"). Wird erst auf Knopfdruck geladen.
    @ViewBuilder
    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.horizontal)
            if !availableLoaded {
                Button {
                    Task {
                        loadingAvailable = true
                        available = await absPodcast.availableEpisodes(for: show)
                        availableLoaded = true
                        loadingAvailable = false
                    }
                } label: {
                    Label(loadingAvailable ? String(localized: "Loading…") : String(localized: "Load older episodes"),
                          systemImage: "tray.and.arrow.down")
                }
                .disabled(loadingAvailable)
                .padding(.horizontal)
            } else if available.isEmpty {
                Text("All feed episodes are on the server.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            } else {
                Text("Available episodes").font(.title3).bold().padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(available) { ep in
                        // Tippen = sofort vom Original-Host streamen (rss:-Item,
                        // Fortschritt lokal+iCloud); Pfeil = am Server sichern.
                        let item = feedEpisodePlayItem(show: liveShow, feed: ep)
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle").font(.title2).foregroundStyle(AppTheme.accent)
                            Text(ep.title).font(.subheadline).lineLimit(2)
                            Spacer(minLength: 8)
                            if downloading.contains(ep.id) {
                                ProgressView()
                            } else {
                                Button {
                                    downloadAvailable(ep)
                                } label: {
                                    Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Für „Download-on-Play" registrieren, dann streamen.
                            PodcastServerSave.shared.register(rssItemId: item.id, showId: show.id, feed: ep)
                            Task { await playerCoordinator.open(item: item) }
                        }
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    /// Server anweisen, die Folge zu laden; danach neu einlesen (der Download
    /// läuft server-seitig asynchron, daher kurz warten).
    private func downloadAvailable(_ ep: FeedEpisode) {
        downloading.insert(ep.id)
        Task {
            if let error = await absPodcast.downloadEpisode(showId: show.id, episode: ep) {
                downloadError = error
                downloading.remove(ep.id)
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await absPodcast.refresh()
            available.removeAll { $0.id == ep.id }
            downloading.remove(ep.id)
        }
    }

    /// RSS-Shows: volle Folgen-Historie über PodcastIndex nachladen (wenn Key
    /// hinterlegt) — holt auch alte Folgen, die aus dem Live-Feed gefallen sind.
    @ViewBuilder
    private var historySection: some View {
        if AppStorageKeys.podcastIndexConfigured {
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.horizontal)
                Button {
                    Task {
                        loadingHistory = true
                        let n = await subs.loadFullHistory(showId: show.id)
                        historyResult = n > 0
                            ? String(localized: "\(n) episodes added")
                            : String(localized: "No additional episodes found.")
                        loadingHistory = false
                    }
                } label: {
                    Label(loadingHistory ? String(localized: "Loading…") : String(localized: "Load full history"),
                          systemImage: "clock.arrow.circlepath")
                }
                .disabled(loadingHistory)
                .padding(.horizontal)
                if let historyResult {
                    Text(historyResult).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
        }
    }
}

/// Reiche Episoden-Zeile: Cover, Show + Titel, Datum/Restzeit, Fortschritt,
/// Play- und Download-Button. Tap spielt ab.
struct PodcastEpisodeRow: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared

    private var state: EpisodePlayState { podcastPlayState(for: item) }
    private var isPlayed: Bool { state == .played }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            podcastArtwork(url: AppSession.shared.coverURL(forItemId: item.id), size: 64, corner: 8)
                // Gehörte Folgen abgedimmt, wie in Apple Podcasts.
                .opacity(isPlayed ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 3) {
                if let show = item.media?.metadata?.authorName {
                    Text(show.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isPlayed ? .secondary : .primary)
                    .lineLimit(2)

                if case .inProgress(let fraction, _) = state {
                    // Angespielt: dünner Balken + Restzeit.
                    ProgressView(value: fraction)
                        .tint(AppTheme.accent)
                        .padding(.trailing, 40)
                        .padding(.top, 2)
                }

                HStack(spacing: 8) {
                    if isPlayed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(metaText).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    PodcastDownloadButton(item: item)
                    playButton
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { Task { await playerCoordinator.open(item: item) } }
        .contextMenu {
            Button {
                PodcastQueue.shared.playNext(item.id)
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            Button {
                PodcastQueue.shared.playLast(item.id)
            } label: {
                Label("Play Last", systemImage: "text.append")
            }
            Button {
                podcastSetPlayed(item, !isPlayed)
            } label: {
                Label(
                    isPlayed ? String(localized: "Mark as Unplayed") : String(localized: "Mark as Played"),
                    systemImage: isPlayed ? "arrow.uturn.backward.circle" : "checkmark.circle"
                )
            }
        }
    }

    private var playButton: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
    }

    /// „vor 2 Tagen · 45 Min", „vor 2 Tagen · 12 Min übrig" bzw. „Abgespielt".
    private var metaText: String {
        var parts: [String] = []
        let date = relativeDateText(item)
        if !date.isEmpty { parts.append(date) }
        switch state {
        case .played:
            parts.append(String(localized: "Played"))
        case .inProgress(_, let remaining):
            parts.append(String(localized: "\(Int(remaining / 60)) min left"))
        case .unplayed:
            if let duration = item.media?.duration, duration > 0 {
                parts.append(durationText(item))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Download-Steuerung für eine Podcast-Episode (Zustand aus dem DownloadManager):
/// Pfeil → Ring beim Laden → Häkchen wenn geladen. Wiederverwendet in Karte + Zeile.
private struct PodcastDownloadButton: View {
    let item: LibraryItem
    /// Icon-Farbe — Default passt in Listen; auf farbigem/dunklem Grund `.white`.
    var tint: Color = .secondary
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        if downloads.isDownloaded(itemId: item.id) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(tint)
        } else if case .downloading(let f) = downloads.phase[item.id] {
            ProgressView(value: f).progressViewStyle(.circular).scaleEffect(0.7)
        } else {
            Button {
                Task {
                    guard let detail = try? await AppSession.shared.rssProvider.fetchItemDetail(itemId: item.id) else { return }
                    await DownloadManager.shared.download(item: detail, provider: AppSession.shared.rssProvider)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Wiedergabe-Zustand

/// Drei Zustände einer Episode fürs UI — ungehört, angespielt (mit Restzeit)
/// oder komplett gehört. Podcasts syncen NICHT über den Server; die Basis ist
/// die lokale `localPosition` (die der Player alle 5 s schreibt).
enum EpisodePlayState: Equatable {
    case unplayed
    case inProgress(fraction: Double, remaining: Double)
    case played
}

/// Reaktiver Zugriff auf den lokalen Podcast-Fortschritt. Nötig, weil
/// `localPosition` in UserDefaults liegt (kein @Published) — ohne diesen Store
/// würde ein „als gehört markieren" die Liste nicht sofort aktualisieren.
@MainActor
final class PodcastProgressStore: ObservableObject {
    static let shared = PodcastProgressStore()
    // Expliziter Publisher statt @Published: unter dem Projekt-Default
    // `MainActor` scheitert die synthetisierte ObservableObject-Conformance
    // aus einer @Published-Property. Wir senden die Änderung selbst.
    nonisolated let objectWillChange = ObservableObjectPublisher()
    /// Zählt Fortschritts-Änderungen — als `.task`-id, um die Podcast-Sektionen
    /// gezielt neu zu berechnen (statt bei jedem Body-Eval).
    private(set) var changeToken = 0

    func state(for item: LibraryItem) -> EpisodePlayState {
        state(guid: item.id, duration: item.media?.duration ?? 0)
    }

    /// Zustand direkt aus guid + Dauer — ohne ein `LibraryItem` zu bauen
    /// (die Podcast-Sektionen rechnen so über tausende Folgen ohne Overhead).
    func state(guid: String, duration: Double) -> EpisodePlayState {
        guard duration > 0,
              let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(guid)) as? [Double],
              stored.count == 2 else { return .unplayed }
        let time = stored[0]
        if time >= duration - 1 { return .played }
        if time > 1 { return .inProgress(fraction: min(max(time / duration, 0), 1), remaining: duration - time) }
        return .unplayed
    }

    /// „Als gehört" schreibt die Position ans Ende, „ungehört" löscht sie.
    func setPlayed(_ item: LibraryItem, _ played: Bool) {
        let key = AppStorageKeys.localPosition(item.id)
        if played, let duration = item.media?.duration, duration > 0 {
            UserDefaults.standard.set([duration, Date().timeIntervalSince1970 * 1000], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        changeToken += 1
        objectWillChange.send()
    }

    /// Nach externem Schreiben von `localPosition` (z. B. Apple-Import) alle
    /// beobachtenden Zeilen neu bewerten lassen.
    func reload() { changeToken += 1; objectWillChange.send() }
}

/// PodcastShow + Episode → LibraryItem (quellen-agnostisch). Der Namespace im
/// `guid`/`id` (`rss:`/`abspod:`) routet Wiedergabe/Cover/Fortschritt auf die
/// richtige Quelle.
func podcastLibraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
    LibraryItem(
        id: episode.guid,
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: episode.title, authorName: show.title, narratorName: nil,
                seriesName: show.title, genres: nil, publishedYear: nil,
                description: episode.description
            ),
            duration: episode.duration, chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: episode.duration,
                                   contentUrl: episode.audioURL, metadata: nil)]
        ),
        addedAt: episode.pubDate
    )
}

/// Pro-Show-Auto-Download: lädt für aktivierte Shows die neuesten, seit dem
/// Einschalten erschienenen Folgen lokal (quellenübergreifend RSS + ABS). Nur
/// Folgen NACH dem Aktivierungszeitpunkt werden gezogen, damit vom Nutzer
/// gelöschte Altfolgen nicht endlos neu geladen werden.
@MainActor
enum PodcastAutoDownload {
    static func flagKey(_ showId: String) -> String { "podcastAutoDownload.\(showId)" }
    private static func sinceKey(_ showId: String) -> String { "podcastAutoDownloadSince.\(showId)" }

    static func isEnabled(_ showId: String) -> Bool {
        UserDefaults.standard.bool(forKey: flagKey(showId))
    }

    static func setEnabled(_ showId: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: flagKey(showId))
        // Beim Einschalten den Stichtag setzen → ab jetzt neue Folgen.
        if on { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: sinceKey(showId)) }
    }

    /// Für alle aktivierten Shows die neuen (seit Stichtag), noch nicht lokal
    /// vorhandenen Folgen ziehen. `perShow` deckelt pro Durchlauf.
    static func run(shows: [PodcastShow], perShow: Int = 3) async {
        let dm = DownloadManager.shared
        for show in shows where isEnabled(show.id) {
            let since = UserDefaults.standard.double(forKey: sinceKey(show.id))
            let candidates = show.episodes
                .filter { $0.pubDate >= since }
                .sorted { $0.pubDate > $1.pubDate }
                .prefix(perShow)
                .map { podcastLibraryItem(show: show, episode: $0) }
            for item in candidates where !dm.isDownloaded(itemId: item.id) {
                let provider = AppSession.shared.provider(for: item.id)
                guard let detail = try? await provider.fetchItemDetail(itemId: item.id) else { continue }
                await dm.download(item: detail, provider: provider)
            }
        }
    }
}

/// Feed-only-Folge einer ABS-Show → abspielbares `rss:`-Item: streamt vom
/// Original-Host, Fortschritt läuft lokal+iCloud (kein Server-Download nötig).
/// Gleiche `rss:<feedKey>:<guid>`-ID wie RSS/PodcastIndex → gemeinsamer
/// Fortschritt, und die Basis für den späteren Server-Handoff.
@MainActor
func feedEpisodePlayItem(show: PodcastShow, feed: FeedEpisode) -> LibraryItem {
    let guid = "rss:\(PodcastSubscriptions.feedKey(show.feedURL)):\(feed.id)"
    return LibraryItem(
        id: guid,
        media: LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: feed.title, authorName: show.title, narratorName: nil,
                seriesName: show.title, genres: nil, publishedYear: nil, description: nil),
            duration: feed.duration, chapters: nil,
            tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: feed.duration,
                                   contentUrl: feed.enclosureUrl, metadata: nil)]),
        addedAt: feed.publishedAt)
}

// MARK: - Quellen-bewusster Gehört-Zustand

/// Gehört-Zustand vereinheitlicht (Reconciliation): `localPosition` spiegelt
/// bereits lokal+iCloud (nach `PodcastCloudSync.reconcile`); für `abspod:`
/// zusätzlich den ABS-Server-Stand einbeziehen — der jüngere Zeitstempel
/// gewinnt.
@MainActor
func podcastPlayState(for item: LibraryItem) -> EpisodePlayState {
    let duration = item.media?.duration ?? 0
    // Gleichwertige IDs beider Quellen (self + Brücke über die Feed-guid), damit
    // die importierte rss:-History auch auf der ABS-Kopie sichtbar ist.
    let ids = ABSPodcastProvider.shared.equivalentIds(item.id)

    // Jüngster lokaler Stand über alle Brücken-IDs.
    var bestGuid: String?
    var bestTs = -1.0
    for id in ids {
        if let arr = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(id)) as? [Double],
           arr.count == 2, arr[1] > bestTs {
            bestTs = arr[1]; bestGuid = id
        }
    }

    // Server-Stand der abspod:-Kopie einbeziehen (jüngerer Zeitstempel gewinnt).
    if let absId = ids.first(where: { $0.hasPrefix("abspod:") }) {
        let absTs = ABSPodcastProvider.shared.episodeProgress[absId]?.lastUpdate ?? -1
        if absTs > bestTs {
            return ABSPodcastProvider.shared.state(forEpisodeId: absId, duration: duration)
        }
    }
    guard let bestGuid else { return .unplayed }
    return PodcastProgressStore.shared.state(guid: bestGuid, duration: duration)
}

/// „Als gehört/ungehört": immer lokal setzen (→ iCloud propagiert es) und bei
/// ABS zusätzlich am Server; danach sofort nach iCloud pushen.
@MainActor
func podcastSetPlayed(_ item: LibraryItem, _ played: Bool) {
    PodcastProgressStore.shared.setPlayed(item, played)
    // Auch am Server spiegeln: die abspod:-Kopie ist self (abspod-Item) oder die
    // über die Feed-guid gebrückte Server-Folge (rss-Item).
    let absId = item.id.hasPrefix("abspod:")
        ? item.id
        : ABSPodcastProvider.shared.bridgedABSId(forRSS: item.id)
    if let absId, let absItem = AppSession.shared.libraryItem(forId: absId) {
        Task { await ABSPodcastProvider.shared.setPlayed(absItem, played) }
    }
    PodcastCloudSync.shared.reconcile()
}

// MARK: - Gemeinsame Helfer

/// HTML aus Episodenbeschreibungen zu Plaintext entschärfen (Tags/Entities),
/// analog `BookDetailScreen.plainText(fromHTML:)`.
private func podcastPlainText(_ html: String) -> String {
    var text = html
    text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
    text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.caseInsensitive, .regularExpression])
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&amp;": "&", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
    for (entity, replacement) in entities {
        text = text.replacingOccurrences(of: entity, with: replacement)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// „vor 2 Tagen" — relatives Datum aus `addedAt` (pubDate).
private func relativeDateText(_ item: LibraryItem) -> String {
    guard let added = item.addedAt, added > 0 else { return "" }
    return Date(timeIntervalSince1970: added / 1000)
        .formatted(.relative(presentation: .named))
}

/// „55 min" bzw. „1 Std 51 min" aus der Episodendauer.
private func durationText(_ item: LibraryItem) -> String {
    let total = Int((item.media?.duration ?? 0) / 60)
    if total >= 60 {
        return String(localized: "\(total / 60) h \(total % 60) min")
    }
    return String(localized: "\(total) min")
}

/// Podcast-Cover (Remote-URL) mit Fallback-Mikrofon. `thumbnailPixel` erzwingt
/// ein Thumbnail dieser Zielgröße (z. B. 800 px für die „Als Nächstes"-Karten —
/// scharf, aber viel leichter als der Voll-Decode bis ~2200 px).
@ViewBuilder
private func podcastArtwork(url: URL?, size: CGFloat, corner: CGFloat, thumbnailPixel: CGFloat? = nil) -> some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    Group {
        if let url {
            CachedAsyncImage(url: url,
                             useThumbnail: thumbnailPixel != nil || size <= 200,
                             thumbnailMaxPixel: thumbnailPixel) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                shape.fill(Color.secondary.opacity(0.15))
            }
        } else {
            shape.fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "mic").font(.title3).foregroundStyle(.secondary))
        }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
}
