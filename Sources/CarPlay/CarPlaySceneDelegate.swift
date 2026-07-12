import CarPlay
import UIKit

/// CarPlay-Szene: drei Tabs (Weiter hören / Heruntergeladen / Bibliothek) als
/// Listen, Auswahl startet die Wiedergabe über den GEMEINSAMEN
/// PlayerCoordinator (AppSession) und zeigt den Now-Playing-Screen — dessen
/// Inhalt/Buttons kommen automatisch aus MPNowPlayingInfoCenter/RemoteCommands,
/// die für den Lockscreen längst verdrahtet sind.
///
/// Funktioniert auch beim KALTSTART im Auto (Telefon in der Tasche): die
/// Bibliothek lädt hier selbst (fällt offline auf den Disk-Cache zurück).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { await self.setupTemplates() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    private func setupTemplates() async {
        let session = AppSession.shared
        if session.libraryViewModel.entries.isEmpty {
            await session.libraryViewModel.loadLibrary()
        }

        let continueTab = await listTemplate(
            title: String(localized: "Continue Listening"),
            systemImage: "play.circle",
            entries: session.libraryViewModel.continueListening
        )
        let downloadedTab = await listTemplate(
            title: String(localized: "Downloaded"),
            systemImage: "arrow.down.circle",
            entries: session.libraryViewModel.downloadedEntries
        )
        let libraryTab = await listTemplate(
            title: String(localized: "Library"),
            systemImage: "books.vertical",
            entries: session.libraryViewModel.sortedFilteredEntries
        )

        var templates: [CPListTemplate] = [continueTab, downloadedTab, libraryTab]
        // Podcast-Tab nur, wenn Abos vorhanden sind (Queue/Fortsetzen/Sendungen).
        if let podcasts = await podcastTab() { templates.append(podcasts) }

        let tabBar = CPTabBarTemplate(templates: templates)
        interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Podcasts

    /// Quellen-übergreifende Show-Liste (RSS + aktive ABS), über die
    /// normalisierte Feed-URL dedupliziert (ABS bevorzugt).
    private func dedupedPodcastShows() -> [PodcastShow] {
        let abs = AppStorageKeys.absPodcastsEnabledValue ? ABSPodcastProvider.shared.activeShows : []
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = PodcastSubscriptions.shared.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    /// „Als Nächstes" (Queue) · „Fortsetzen" (angespielt) · „Sendungen"
    /// (Drill-down zu den Folgen). Nil, wenn keine Podcasts abonniert sind.
    private func podcastTab() async -> CPListTemplate? {
        let shows = dedupedPodcastShows()
        guard !shows.isEmpty else { return nil }

        let queue = PodcastQueue.shared.ids.compactMap { AppSession.shared.libraryItem(forId: $0) }

        var continueItems: [(item: LibraryItem, date: Double)] = []
        for show in shows {
            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                if case .inProgress = podcastPlayState(for: item) {
                    continueItems.append((item, item.addedAt ?? 0))
                }
            }
        }
        let cont = continueItems.sorted { $0.date > $1.date }.prefix(20).map { $0.item }

        let cap = Int(CPListTemplate.maximumItemCount)
        var sections: [CPListSection] = []
        if !queue.isEmpty {
            var items: [CPListItem] = []
            for it in queue.prefix(cap) { items.append(await playableItem(it)) }
            sections.append(CPListSection(items: items, header: String(localized: "Up Next"), sectionIndexTitle: nil))
        }
        if !cont.isEmpty {
            var items: [CPListItem] = []
            for it in cont.prefix(cap) { items.append(await playableItem(it)) }
            sections.append(CPListSection(items: items, header: String(localized: "Continue"), sectionIndexTitle: nil))
        }
        var showItems: [CPListItem] = []
        for show in shows.prefix(cap) {
            let coverURL = show.artworkURL.flatMap { URL(string: $0) }
            let image = coverURL != nil ? await ImageCache.shared.thumbnail(for: coverURL!) : nil
            let li = CPListItem(text: show.title, detailText: show.author, image: image)
            li.accessoryType = .disclosureIndicator
            li.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.pushShowEpisodes(show)
                    completion()
                }
            }
            showItems.append(li)
        }
        sections.append(CPListSection(items: showItems, header: String(localized: "Shows"), sectionIndexTitle: nil))

        let template = CPListTemplate(title: String(localized: "Podcasts"), sections: sections)
        template.tabImage = UIImage(systemName: "mic")
        return template
    }

    /// Folgen einer Show als eigenes CarPlay-Listen-Template pushen.
    private func pushShowEpisodes(_ show: PodcastShow) async {
        let episodes = show.episodes.sorted { $0.pubDate > $1.pubDate }
            .prefix(Int(CPListTemplate.maximumItemCount))
        var items: [CPListItem] = []
        for ep in episodes {
            items.append(await playableItem(podcastLibraryItem(show: show, episode: ep)))
        }
        let template = CPListTemplate(title: show.title, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    /// Abspielbare Podcast-Zeile: Tap startet die Folge über den Coordinator.
    private func playableItem(_ item: LibraryItem) async -> CPListItem {
        let coverURL = AppSession.shared.coverURL(forItemId: item.id)
        let image = coverURL != nil ? await ImageCache.shared.thumbnail(for: coverURL!) : nil
        let li = CPListItem(text: item.title, detailText: item.media?.metadata?.authorName, image: image)
        li.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                await AppSession.shared.playerCoordinator.open(item: item)
                self?.showNowPlaying()
                completion()
            }
        }
        return li
    }

    /// Baut eine Buchliste; Cover kommen aus der Thumbnail-Stufe des
    /// ImageCache (bereits klein dekodiert — fürs Auto genau richtig).
    private func listTemplate(title: String, systemImage: String, entries: [LibraryEntry]) async -> CPListTemplate {
        // CarPlay-Listen sind hart limitiert; mehr als das zeigt das System
        // ohnehin nicht an, und jede Zeile kostet einen Thumbnail-Decode.
        let limited = entries.prefix(Int(CPListTemplate.maximumItemCount))
        var items: [CPListItem] = []
        for entry in limited {
            let coverURL = AppSession.shared.coverURL(forItemId: entry.id)
            var image: UIImage?
            if let coverURL {
                image = await ImageCache.shared.thumbnail(for: coverURL)
            }
            let item = CPListItem(
                text: entry.item.title,
                detailText: entry.item.author,
                image: image
            )
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await AppSession.shared.playerCoordinator.open(item: entry.item)
                    self?.showNowPlaying()
                    completion()
                }
            }
            items.append(item)
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        template.tabImage = UIImage(systemName: systemImage)
        template.emptyViewTitleVariants = [String(localized: "No books here yet.")]
        return template
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        // Nicht doppelt pushen, wenn Now Playing schon oben liegt.
        if interfaceController.topTemplate != nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }
}
