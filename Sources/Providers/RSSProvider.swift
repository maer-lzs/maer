// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Podcast source via RSS/Atom feeds. Episodes are mapped to `LibraryItem` (one
/// track = the enclosure URL) so player, downloads, sleep timer, widget and
/// CarPlay use them unchanged. Same pattern as `LocalProvider`: the core knows
/// neither the feed store nor `rss:` ids (except the router in AppSession).
@MainActor
final class RSSProvider: AudioProvider {
    static let shared = RSSProvider()
    private let subs = PodcastSubscriptions.shared

    private init() {}

    var providerId: String { "rss" }
    var mediaTypes: Set<MediaType> { [.podcasts] }
    /// Only show the podcast tab once at least one feed is subscribed AND the
    /// RSS source is effectively active (podcast tab ∧ RSS on). TF bib-toggles.
    var isAvailable: Bool { AppStorageKeys.rssActive && subs.hasSubscriptions }
    /// Episodes can be downloaded for offline; no server sync, no server
    /// bookmarks.
    var capabilities: ProviderCapabilities { [.downloadable] }
    var streamAuthHeaders: [String: String] { [:] }
    /// Private/premium feeds: per-feed Basic auth (from the `feedKey` of the item id).
    func streamAuthHeaders(forItemId itemId: String) -> [String: String] {
        PodcastFeedAuth.authHeader(forItemId: itemId)
    }

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "podcasts", name: String(localized: "Podcasts"))]
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        subs.allEpisodes().map { libraryItem(show: $0.show, episode: $0.episode) }
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        // The subscription stock first. It is the one truth for what we own.
        // Then the session store of browsed shows: an episode listed in a feed
        // is playable whether it is subscribed or not. The 404 came from this
        // lookup, never from the source.
        if let found = subs.episode(guid: itemId)
            ?? BrowsedEpisodes.shared.episode(guid: itemId) {
            return await detail(show: found.show, episode: found.episode)
        }
        // After a restart the session store is empty; the row written down for
        // a listened episode then carries the resolution, so its position
        // yields a tile with a name instead of an orphan.
        if let kept = BrowsedEpisodes.shared.listened(guid: itemId) {
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: LibraryItemMetadata(
                        title: kept.episodeTitle, authorName: kept.showTitle,
                        narratorName: nil, seriesName: nil, genres: nil,
                        publishedYear: nil, description: nil),
                    duration: kept.duration > 0 ? kept.duration : nil,
                    chapters: nil,
                    tracks: [ABSAudioTrack(index: 0, startOffset: 0,
                                           duration: kept.duration,
                                           contentUrl: kept.audioURL,
                                           metadata: nil)]),
                userMediaProgress: nil)
        }
        throw NSError(domain: "RSSProvider", code: 404)
    }

    private func detail(show: PodcastShow, episode: PodcastEpisode) async -> LibraryItemDetail {
        let found = (show: show, episode: episode)
        let item = libraryItem(show: found.show, episode: found.episode)
        var media = item.media ?? emptyMedia
        // Lazily load Podcasting 2.0 chapters (only when opening the episode).
        if let raw = found.episode.chaptersURL, let url = URL(string: raw),
           let chapters = await Self.loadChapters(url: url, duration: found.episode.duration) {
            media = LibraryItemMedia(metadata: media.metadata, duration: media.duration,
                                     chapters: chapters, tracks: media.tracks)
        }
        return LibraryItemDetail(id: item.id, media: media, userMediaProgress: nil)
    }

    // MARK: - Chapters (Podcasting 2.0)

    private struct PC20ChapterList: Decodable { let chapters: [PC20Chapter] }
    private struct PC20Chapter: Decodable { let startTime: Double; let title: String? }

    /// Load chapter JSON and map it to `[ABSChapter]` (end = next start, episode
    /// duration for the last). Error → nil (episode plays without chapters).
    static func loadChapters(url: URL, duration: Double) async -> [ABSChapter]? {
        guard let (data, _) = try? await RequestRetryPolicy.fetch(URLRequest(url: url)),
              let list = try? JSONDecoder().decode(PC20ChapterList.self, from: data),
              !list.chapters.isEmpty else { return nil }
        let sorted = list.chapters.sorted { $0.startTime < $1.startTime }
        return sorted.enumerated().map { i, c in
            let end = i + 1 < sorted.count ? sorted[i + 1].startTime
                : (duration > 0 ? duration : c.startTime)
            return ABSChapter(id: i, start: c.startTime, end: end,
                              title: c.title ?? String(localized: "Chapter \(i + 1)"))
        }
    }

    func coverURL(forItemId itemId: String) -> URL? {
        guard let found = subs.episode(guid: itemId) else { return nil }
        let raw = found.episode.imageURL ?? found.show.artworkURL
        return raw.flatMap { URL(string: $0) }
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        // For podcasts the contentPath is already the full audio URL.
        URL(string: contentPath)
    }

    // Progress purely local (no server). Like LocalProvider.
    func fetchAllProgress() async throws -> [String: BookProgress] {
        var map: [String: BookProgress] = [:]
        for (show, episode) in subs.allEpisodes() {
            let item = libraryItem(show: show, episode: episode)
            guard let duration = item.media?.duration, duration > 0,
                  let stored = ListeningStore.backup(item.id),
                  stored.count >= 2 else { continue }
            let time = stored[0]
            map[item.id] = BookProgress(
                fraction: min(max(time / duration, 0), 1),
                isFinished: ProgressMark.isPlayed(stored: stored, currentDuration: duration),
                lastUpdate: ProgressMark.timestamp(stored) ?? 0,
                currentTime: time
            )
        }
        return map
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - For the podcast view (synchronous)

    /// Single episode as a LibraryItem via the guid index (O(1)). For
    /// resume/restore, instead of building all episodes.
    func libraryItem(forEpisodeId id: String) -> LibraryItem? {
        guard let found = subs.episode(guid: id) else { return nil }
        return libraryItem(show: found.show, episode: found.episode)
    }

    /// Show for an episode (for the show badge and show linking).
    func show(forEpisodeId id: String) -> PodcastShow? {
        subs.episode(guid: id)?.show
    }

    /// All of a show's episodes as LibraryItems (newest first). For linking
    /// episode page → show page.
    func showItems(for show: PodcastShow) -> [LibraryItem] {
        show.episodes
            .sorted { $0.pubDate > $1.pubDate }
            .map { libraryItem(show: show, episode: $0) }
    }

    // MARK: - Mapping Episode → LibraryItem

    private func libraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
        LibraryItem(
            id: episode.guid,   // already "rss:<feed>:<guid>"
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: episode.title,
                    authorName: show.title,     // show as "author" → display "Show — Episode"
                    narratorName: nil,
                    seriesName: show.title,      // groups episodes under the show
                    genres: nil,
                    publishedYear: nil,
                    description: episode.description
                ),
                duration: episode.duration,
                chapters: nil,
                tracks: [ABSAudioTrack(index: 0, startOffset: nil, duration: episode.duration,
                                       contentUrl: episode.audioURL, metadata: nil)]
            ),
            addedAt: episode.pubDate
        )
    }

    private var emptyMedia: LibraryItemMedia {
        LibraryItemMedia(metadata: nil, duration: 0, chapters: nil, tracks: nil)
    }
}
