// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CarPlay
import UIKit

/// CarPlay scene: three tabs (Continue / Downloaded / Library) as lists;
/// selecting starts playback via the SHARED PlayerCoordinator (AppSession) and
/// shows the Now Playing screen. Its content/buttons come automatically from
/// MPNowPlayingInfoCenter/RemoteCommands, already wired for the lock screen.
///
/// Works on a COLD START in the car (phone in the pocket): the library loads
/// here itself (falls back to the disk cache offline).
///
/// Explicitly @MainActor: CPInterfaceController is main-thread-only. The
/// project's default isolation already isolates this class, but templates
/// touching the interface controller is an invariant worth stating. It must
/// survive a future change of the default (Swift-6 migration). The
/// `Task { @MainActor in }` hops inside the CPListItem handlers stay: the
/// handler property is a nonisolated block, so the hop is the type-safe way
/// back onto the actor.
@MainActor
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
        // Podcast subscriptions load asynchronously at app start. On a CarPlay
        // cold start (car scene only, no UI) wait for them, or the podcast tab
        // would silently be missing. Same for the download scan (Downloaded tab).
        await PodcastSubscriptions.shared.ensureLoaded()
        await DownloadManager.shared.ensureScanned()
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
        // Podcast tab only when subscriptions exist (queue/continue/shows).
        if let podcasts = await podcastTab() { templates.append(podcasts) }
        // Music tab only when a music source is configured + enabled.
        if let music = await musicTab() { templates.append(music) }

        let tabBar = CPTabBarTemplate(templates: templates)
        interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Podcasts

    /// Cross-source show list (RSS + active ABS), deduplicated by the
    /// normalised feed URL (ABS preferred).
    private func dedupedPodcastShows() -> [PodcastShow] {
        let abs = AppStorageKeys.absPodcastsActive ? ABSPodcastProvider.shared.activeShows : []
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        let rssOnly = PodcastSubscriptions.shared.shows.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
        return abs + rssOnly
    }

    /// "Up Next" (queue) · "Continue" (in progress) · "Shows" (drill-down to
    /// episodes). Nil when no podcasts are subscribed.
    private func podcastTab() async -> CPListTemplate? {
        let shows = dedupedPodcastShows()
        guard !shows.isEmpty else { return nil }

        // The fourth surface of the "not in memory means does not exist"
        // class: a cold catalogue entry stays IN the car's queue and plays on
        // tap (open resolves it); until then it carries the placeholder title.
        // Dropping it would show a queue that lies about its content.
        let queue = PlayQueue.shared.ids.compactMap { AppSession.shared.playableItem(forId: $0) }

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
            let image = coverURL != nil ? await Artwork.thumbnail(for: coverURL!) : nil
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

    // MARK: - Music

    /// "Recently Added" + "Albums"; tapping an album plays it. Nil when no
    /// music source is configured/enabled.
    private func musicTab() async -> CPListTemplate? {
        // "Reachable" is not "feeds music": a source whose second mode has no
        // library yet is live (so its setup can be finished) but serves no tab.
        guard AppSession.shared.musicProvider.isAvailable,
              AppSession.shared.musicProvider.mediaTypes.contains(.music) else { return nil }
        let cap = Int(CPListTemplate.maximumItemCount)
        let newest = (try? await AppSession.shared.musicProvider.albumShelf(shelf: .newest, size: 20)) ?? []
        // The music tab asks for MUSIC. A source that also serves audiobooks
        // must not put books in the car's album list.
        let all = (try? await AppSession.shared.musicProvider.fetchLibraryItems(for: .music)) ?? []

        var sections: [CPListSection] = []
        if !newest.isEmpty {
            var items: [CPListItem] = []
            for album in newest.prefix(cap) { items.append(await playableItem(album)) }
            sections.append(CPListSection(items: items, header: String(localized: "Recently Added"), sectionIndexTitle: nil))
        }
        if !all.isEmpty {
            var items: [CPListItem] = []
            for album in all.prefix(cap) { items.append(await playableItem(album)) }
            sections.append(CPListSection(items: items, header: String(localized: "Albums"), sectionIndexTitle: nil))
        }
        guard !sections.isEmpty else { return nil }

        let template = CPListTemplate(title: String(localized: "Music"), sections: sections)
        template.tabImage = UIImage(systemName: "music.note")
        return template
    }

    /// Push a show's episodes as their own CarPlay list template.
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

    /// Playable podcast row: tap starts the episode via the coordinator.
    private func playableItem(_ item: LibraryItem) async -> CPListItem {
        let coverURL = AppSession.shared.coverURL(forItemId: item.id)
        let image = coverURL != nil ? await Artwork.thumbnail(for: coverURL!) : nil
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

    /// Builds a book list; covers come from the ImageCache thumbnail tier
    /// (already decoded small. Just right for the car).
    private func listTemplate(title: String, systemImage: String, entries: [LibraryEntry]) async -> CPListTemplate {
        // CarPlay lists are hard-limited; the system won't show more anyway,
        // and every row costs a thumbnail decode.
        let limited = entries.prefix(Int(CPListTemplate.maximumItemCount))
        var items: [CPListItem] = []
        for entry in limited {
            let coverURL = AppSession.shared.coverURL(forItemId: entry.id)
            var image: UIImage?
            if let coverURL {
                image = await Artwork.thumbnail(for: coverURL)
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
        // Don't push twice if Now Playing is already on top.
        if interfaceController.topTemplate != nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }
}
