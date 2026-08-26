// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine

/// A feed episode (parsed raw from the server) that is not yet in the library
/// and can be downloaded server-side. `raw` is passed 1:1 to
/// `download-episodes` (the server expects its own feed format).
struct FeedEpisode: Identifiable {
    let id: String
    let title: String
    let publishedAt: Double
    let duration: Double
    let enclosureUrl: String
    let raw: [String: Any]
}

/// Audiobookshelf podcasts as their own source of type `.podcasts`. Unlike the
/// main ABS provider (audiobooks, raw ids) this provider namespaces its ids with
/// `abspod:<libraryItemId>:<episodeId>`. An episode is the playable unit. Uses
/// the shared `APIClient` (network/auth) and hooks into the existing sync
/// machinery via `.progressSync` → progress/played per episode sync server-side
/// across all devices.
@MainActor
final class ABSPodcastProvider: ObservableObject, AudioProvider {
    static let shared = ABSPodcastProvider()
    private init() {
        archivedShowIds = Set(UserDefaults.standard.stringArray(forKey: Self.archiveKey) ?? [])
    }

    private static let archiveKey = "abspod.archivedShows"

    private var client: APIClient { AppSession.shared.apiClient }

    /// Loaded shows with their episodes (for the podcast UI). Filled by
    /// `refresh()`.
    @Published private(set) var shows: [PodcastShow] = []
    /// Whether the server has podcast libraries. Drives tab visibility. Only
    /// true after a successful `refresh()`.
    @Published private(set) var hasPodcasts = false {
        // Availability flips must reach the tab bar live (the toggle's
        // refresh() probes and sets this on ANY of its paths).
        didSet { if oldValue != hasPodcasts { AppSession.shared.notifySourcesChanged() } }
    }
    /// Server progress per episode (key = `abspod:<item>:<episode>`). Basis for
    /// the played state of ABS episodes (there is nothing local for it).
    @Published private(set) var episodeProgress: [String: BookProgress] = [:]

    /// Bridge via the original feed `guid`: `abspod:` episode id ↔ `rss:` id of
    /// the same episode. So the RSS and ABS copy of an episode share one
    /// listening history (display bridge + server push).
    private var absToRSS: [String: String] = [:]
    private var rssToABS: [String: String] = [:]
    /// Counts changes (shows/progress). Used as a `.task` id in the UI so
    /// "Up Next"/"Downloaded" recompute after an ABS load or "played".
    @Published private(set) var changeToken = 0
    /// Archived shows (client-side): "end subscription" only hides, without
    /// deleting on the server. Show + history stay, reactivatable.
    @Published private(set) var archivedShowIds: Set<String> = []

    /// Shows without archived ones (for the active sections).
    var activeShows: [PodcastShow] { shows.filter { !archivedShowIds.contains($0.id) } }
    /// Only the archived shows (to reactivate).
    var archivedShows: [PodcastShow] { shows.filter { archivedShowIds.contains($0.id) } }

    /// Archive/reactivate a show (persisted, NO server interaction).
    func setArchived(_ showId: String, _ archived: Bool) {
        if archived { archivedShowIds.insert(showId) } else { archivedShowIds.remove(showId) }
        UserDefaults.standard.set(Array(archivedShowIds), forKey: Self.archiveKey)
        changeToken += 1
    }

    // MARK: - AudioProvider

    var providerId: String { "abspod" }
    var mediaTypes: Set<MediaType> { [.podcasts] }
    var capabilities: ProviderCapabilities { [.progressSync, .downloadable] }
    var streamAuthHeaders: [String: String] { client.streamAuthHeaders }
    /// Only when the user explicitly enabled ABS as a podcast source.
    var isAvailable: Bool { AppStorageKeys.absPodcastsActive && hasPodcasts }

    func fetchLibraries() async throws -> [ABSLibrary] {
        try await client.fetchPodcastLibraries()
    }

    /// Library items here are the shows (not directly playable). The podcast UI
    /// loads via `refresh()`; this method is only the contract.
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        try await client.fetchLibraryItems(libraryId: libraryId)
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        let (showId, episodeId) = Self.split(itemId)
        guard let episodeId else { throw NSError(domain: "abspod", code: 400) }
        let detail = try await client.fetchItemDetail(itemId: showId)
        guard let episode = detail.media.episodes?.first(where: { $0.id == episodeId }) else {
            throw NSError(domain: "abspod", code: 404)
        }
        return Self.episodeDetail(itemId: itemId, show: detail, episode: episode)
    }

    func coverURL(forItemId itemId: String) -> URL? {
        client.coverURL(forItemId: Self.split(itemId).show)   // Cover der Show
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        client.streamURL(forContentPath: contentPath)
    }

    func fetchAllProgress() async throws -> [String: BookProgress] {
        try await client.fetchPodcastEpisodeProgress()
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        let (showId, episodeId) = Self.split(itemId)
        guard let episodeId else { return }
        try await client.updateEpisodeProgress(
            libraryItemId: showId, episodeId: episodeId,
            currentTime: currentTime, duration: duration, isFinished: isFinished
        )
    }

    // ABS podcasts use no (book) bookmarks.
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Loading for the UI

    /// Only check whether podcast libraries exist (1 request). Drives tab
    /// visibility without loading all shows. Error/no login → false.
    func refreshAvailability() async {
        // ABS is opt-in as a podcast source. Without it enabled do NOT query the
        // server and do not assume podcasts exist.
        guard AppStorageKeys.absPodcastsActive else {
            if hasPodcasts { hasPodcasts = false }
            return
        }
        // Update ONLY on a successful response. A transient error (no net/brief
        // hiccup) must not flip `hasPodcasts` to false. Otherwise the podcast
        // tab disappears or goes empty.
        guard let libs = try? await client.fetchPodcastLibraries() else { return }
        hasPodcasts = !libs.isEmpty
    }

    /// Timestamp of the last successful refresh. Basis for the throttle below.
    private var lastRefreshAt: Date?

    /// Throttled refresh for frequent, implicit callers (the podcast tab's
    /// mount task): skips when the catalog was loaded recently. Pull-to-refresh
    /// keeps calling `refresh()` directly for an unconditional reload.
    func refreshIfStale(maxAge: TimeInterval = 300) async {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < maxAge { return }
        await refresh()
    }

    /// Load shows + episodes of all podcast libraries. Best effort: individual
    /// failed shows are skipped, the rest stays usable.
    func refresh() async {
        // ABS is opt-in as a podcast source. Without it enabled load nothing and
        // clear the existing state (the user then uses ABS for audiobooks only).
        guard AppStorageKeys.absPodcastsActive else {
            if hasPodcasts || !shows.isEmpty { hasPodcasts = false; shows = []; changeToken += 1 }
            return
        }
        // Retry queued played-writes first (failed offline). The refresh is
        // the natural reconnect point.
        await flushPendingPlayedWrites()
        // Failed library fetch → KEEP the existing state, don't clear (this
        // refresh runs on every tab switch; a brief net hiccup would otherwise
        // empty the whole podcast tab).
        guard let libraries = try? await client.fetchPodcastLibraries() else { return }
        guard !libraries.isEmpty else {
            // The server really has no podcast library.
            hasPodcasts = false
            shows = []
            return
        }
        hasPodcasts = true
        // Progress of all episodes in one go (for the played state).
        episodeProgress = (try? await client.fetchPodcastEpisodeProgress()) ?? episodeProgress

        // Collect show items per library (few requests).
        var itemIds: [String] = []
        for library in libraries {
            if let items = try? await client.fetchLibraryItems(libraryId: library.id) {
                itemIds.append(contentsOf: items.map(\.id))
            }
        }

        // Detail fetches in PARALLEL, batched (max ~5 at once). Serial was
        // noticeably slow with many shows. Concurrency is enough (each request
        // suspends at the net await), order irrelevant → sort at the end.
        let client = self.client
        var loaded: [PodcastShow] = []
        var newAbsToRSS: [String: String] = [:]
        var newRSSToABS: [String: String] = [:]
        var i = 0
        while i < itemIds.count {
            let batch = itemIds[i..<min(i + 5, itemIds.count)]
            i += 5
            let details = await withTaskGroup(of: LibraryItemDetail?.self) { group in
                for id in batch {
                    group.addTask { try? await client.fetchItemDetail(itemId: id) }
                }
                var out: [LibraryItemDetail] = []
                for await detail in group { if let detail { out.append(detail) } }
                return out
            }
            for detail in details {
                loaded.append(podcastShow(from: detail))
                // Build the feed-guid bridge → both ids (for shared history).
                let feedURL = detail.media.metadata?.feedUrl ?? ""
                guard !feedURL.isEmpty else { continue }
                let feedKey = PodcastSubscriptions.feedKey(feedURL)
                for ep in detail.media.episodes ?? [] {
                    guard let orig = ep.guid ?? ep.enclosure?.url, !orig.isEmpty else { continue }
                    let rssId = "rss:\(feedKey):\(orig)"
                    let absId = "abspod:\(detail.id):\(ep.id)"
                    newAbsToRSS[absId] = rssId
                    newRSSToABS[rssId] = absId
                }
            }
        }

        // Only adopt if something was actually loaded. Otherwise (all detail
        // fetches failed) keep the previous state.
        if !loaded.isEmpty || shows.isEmpty {
            shows = loaded
            absToRSS = newAbsToRSS
            rssToABS = newRSSToABS
            changeToken += 1
        }
        lastRefreshAt = Date()
    }

    /// Equivalent ids of the same episode across both sources (self + bridge).
    func equivalentIds(_ id: String) -> [String] {
        if id.hasPrefix("abspod:"), let rss = absToRSS[id] { return [id, rss] }
        if id.hasPrefix("rss:"), let abs = rssToABS[id] { return [id, abs] }
        return [id]
    }

    /// The matching `abspod:` server episode for an `rss:` episode (if on server).
    func bridgedABSId(forRSS id: String) -> String? { rssToABS[id] }

    /// Push local (RSS) listening history to the matching server episodes. Only
    /// where the local state is newer than the server. Idempotent. Re-pull the
    /// server progress after the push. Applies only to episodes that exist on
    /// the server (downloaded); older ones stay via local+iCloud.
    func pushLocalHistoryToServer() async {
        var didPush = false
        for (absId, rssId) in absToRSS {
            guard let arr = ListeningStore.backup(rssId),
                  arr.count >= 2 else { continue }
            let localTime = arr[0], localTs = arr[1]
            let serverTs = episodeProgress[absId]?.lastUpdate ?? -1
            guard localTs > serverTs else { continue }

            let (showId, episodeId) = Self.split(absId)
            guard let episodeId,
                  let ep = shows.first(where: { $0.id == "abspod:\(showId)" })?
                      .episodes.first(where: { $0.guid == absId }) else { continue }
            let duration = ep.duration
            let isFinished = ProgressMark.isPlayed(stored: arr, currentDuration: duration)
            try? await client.updateEpisodeProgress(
                libraryItemId: showId, episodeId: episodeId,
                currentTime: localTime, duration: duration, isFinished: isFinished
            )
            didPush = true
        }
        if didPush { await refreshProgress() }
    }

    /// Only re-pull the server progress (after playback/"mark as played").
    func refreshProgress() async {
        // A1b: a failed request (offline!) must KEEP the cached server state.
        // `?? [:]` wiped the progress of every episode right after a failed
        // mark-played, with no automatic reload on reconnect.
        episodeProgress = (try? await client.fetchPodcastEpisodeProgress()) ?? episodeProgress
        changeToken += 1
    }

    // MARK: - Pending played-writes (offline retry)

    /// Server writes that failed (usually offline). itemId → target state.
    /// Persisted so the intent survives an app kill; flushed on the next
    /// catalog refresh (tab entry / reconnect path).
    private var pendingPlayedWrites: [String: Bool] {
        get { (UserDefaults.standard.dictionary(forKey: AppStorageKeys.absPendingPlayedWrites) as? [String: Bool]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: AppStorageKeys.absPendingPlayedWrites) }
    }

    /// Retry queued played-writes; successful ones leave the queue.
    func flushPendingPlayedWrites() async {
        let pending = pendingPlayedWrites
        guard !pending.isEmpty else { return }
        var remaining = pending
        for (itemId, played) in pending {
            let (showId, episodeId) = Self.split(itemId)
            guard let episodeId else { remaining[itemId] = nil; continue }
            let duration = libraryItem(forEpisodeId: itemId)?.media?.duration ?? 0
            do {
                try await client.updateEpisodeProgress(
                    libraryItemId: showId, episodeId: episodeId,
                    currentTime: played ? duration : 0, duration: duration, isFinished: played
                )
                remaining[itemId] = nil
            } catch {
                // Still unreachable. Keep it queued.
            }
        }
        pendingPlayedWrites = remaining
        if remaining.count != pending.count { await refreshProgress() }
    }

    // MARK: - Management (create / remove subscription)

    /// Subscribe to a podcast on the server (feed → create → reload). Returns
    /// `nil` on success, otherwise an error message with the failed step (so
    /// there's no blind guessing at the untested endpoint).
    /// - Parameter coverURL: optional high-resolution feed cover (our
    ///   `itunes:image`). Set server-side after creation because ABS often takes
    ///   the smaller RSS `<image>` on import.
    func subscribeOnServer(feedURL: String, coverURL: String? = nil,
                           autoDownload: Bool = true) async -> String? {
        do {
            guard let library = try await client.fetchPodcastLibraries().first else {
                return "Keine Podcast-Bibliothek auf dem Server."
            }
            let metadata: PodcastFeedMetadata
            do { metadata = try await client.fetchPodcastFeed(rssFeed: feedURL) }
            catch { return "Feed (podcasts/feed): \(Self.msg(error))" }

            // Folders usually come with the list endpoint; otherwise detail.
            var folders = library.folders ?? []
            if folders.isEmpty {
                do { folders = try await client.fetchLibraryFolders(libraryId: library.id) }
                catch { return "Ordner (libraries/id): \(Self.msg(error))" }
            }
            guard let folder = folders.first, let folderPath = folder.fullPath else {
                return "Kein Ordner in der Podcast-Bibliothek."
            }

            let title = Self.sanitizePathComponent(metadata.title ?? "Podcast")
            let path = (folderPath as NSString).appendingPathComponent(title)
            do {
                try await client.createPodcast(libraryId: library.id, folderId: folder.id,
                                               path: path, metadata: metadata, autoDownload: autoDownload)
            } catch { return "Anlegen (POST podcasts): \(Self.msg(error))" }

            await refresh()
            // Push the high-resolution feed cover (prefer our itunes:image;
            // otherwise the one from the server feed response).
            await pushHighResCover(feedURL: feedURL, cover: coverURL ?? metadata.imageUrl)
            return nil
        } catch {
            return "Bibliotheken: \(Self.msg(error))"
        }
    }

    /// Lift the cover of an existing server show to a high-resolution feed
    /// cover. Best effort.
    func updateShowCover(showId: String, coverURL: String) async {
        guard showId.hasPrefix("abspod:"), !coverURL.isEmpty else { return }
        let itemId = String(showId.dropFirst("abspod:".count))
        try? await client.updateItemCover(itemId: itemId, coverURL: coverURL)
    }

    /// Apply the given cover to the freshly created show (found again by feed
    /// URL). Best effort. If it fails, the ABS cover stays.
    private func pushHighResCover(feedURL: String, cover: String?) async {
        guard let cover, !cover.isEmpty else { return }
        let norm = PodcastSubscriptions.normalizeFeedURL(feedURL)
        guard let show = shows.first(where: {
            PodcastSubscriptions.normalizeFeedURL($0.feedURL) == norm
        }) else { return }
        let itemId = String(show.id.dropFirst("abspod:".count))
        try? await client.updateItemCover(itemId: itemId, coverURL: cover)
    }

    private static func msg(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Feed episodes of an ABS show that are NOT yet on the server (loadable).
    /// Matched by title (the library episodes carry the feed titles).
    func availableEpisodes(for show: PodcastShow) async -> [FeedEpisode] {
        guard !show.feedURL.isEmpty,
              let raw = try? await client.fetchFeedEpisodes(rssFeed: show.feedURL) else { return [] }
        let existing = Set(show.episodes.map { $0.title })
        return raw.compactMap { dict -> FeedEpisode? in
            let title = (dict["title"] as? String) ?? ""
            let enclosure = ((dict["enclosure"] as? [String: Any])?["url"] as? String) ?? ""
            guard !title.isEmpty, !enclosure.isEmpty, !existing.contains(title) else { return nil }
            let id = (dict["guid"] as? String) ?? enclosure
            let publishedAt = (dict["publishedAt"] as? Double)
                ?? (dict["publishedAt"] as? Int).map(Double.init) ?? 0
            let duration = (dict["duration"] as? Double)
                ?? (dict["duration"] as? Int).map(Double.init) ?? 0
            return FeedEpisode(id: id, title: title, publishedAt: publishedAt,
                               duration: duration, enclosureUrl: enclosure, raw: dict)
        }
        .sorted { $0.publishedAt < $1.publishedAt }   // oldest first ("from the start")
    }

    /// Have a selected feed episode downloaded server-side. `nil` = ok.
    func downloadEpisode(showId: String, episode: FeedEpisode) async -> String? {
        do {
            try await client.downloadEpisodes(libraryItemId: Self.split(showId).show, episodes: [episode.raw])
            return nil
        } catch {
            return Self.msg(error)
        }
    }

    /// After a server download: find the (now existing) server episode id for a
    /// feed title. The server `audioURL` is the ABS path URL, not the origin
    /// enclosure → match by title.
    func serverEpisodeId(showId: String, title: String) -> String? {
        shows.first { $0.id == showId }?
            .episodes.first { $0.title == title }?.guid
    }

    /// DELETE a show on the server (removes everything server-side incl.
    /// history. Only for the explicit "delete permanently" action, not archive).
    func deleteShowOnServer(showId: String) async -> Bool {
        do {
            try await client.deleteLibraryItem(itemId: Self.split(showId).show)
            await refresh()
            return true
        } catch {
            return false
        }
    }

    /// Replace invalid path characters for the server folder name.
    private static func sanitizePathComponent(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = s.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Podcast" : cleaned
    }

    /// Mark an episode (un)played on the server and re-pull progress.
    func setPlayed(_ item: LibraryItem, _ played: Bool) async {
        let (showId, episodeId) = Self.split(item.id)
        guard let episodeId else { return }
        let duration = item.media?.duration ?? 0
        do {
            try await client.updateEpisodeProgress(
                libraryItemId: showId, episodeId: episodeId,
                currentTime: played ? duration : 0, duration: duration, isFinished: played
            )
            pendingPlayedWrites[item.id] = nil
        } catch {
            // Offline/server down: queue the intent. It is retried on the next
            // refresh instead of silently disappearing (A1b).
            pendingPlayedWrites[item.id] = played
        }
        await refreshProgress()
    }

    /// Played state of an ABS episode from the server progress.
    func state(forEpisodeId itemId: String, duration: Double) -> EpisodePlayState {
        guard let bp = episodeProgress[itemId] else { return .unplayed }
        if bp.isFinished { return .played }
        if bp.fraction > 0.001 {
            let remaining = duration > 0 ? duration * (1 - bp.fraction) : 0
            return .inProgress(fraction: min(max(bp.fraction, 0), 1), remaining: remaining)
        }
        return .unplayed
    }

    /// Single episode as a LibraryItem from the loaded cache (for
    /// resume/restore). Synchronous, no network.
    func libraryItem(forEpisodeId itemId: String) -> LibraryItem? {
        for show in shows {
            if let episode = show.episodes.first(where: { $0.guid == itemId }) {
                return Self.libraryItem(show: show, episode: episode)
            }
        }
        return nil
    }

    // MARK: - Mapping

    /// Split `abspod:<showId>:<episodeId>`. ABS ids contain no colons, so
    /// maxSplits 2 is unambiguous.
    private static func split(_ itemId: String) -> (show: String, episode: String?) {
        let parts = itemId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "abspod" else { return (itemId, nil) }
        return (String(parts[1]), parts.count >= 3 ? String(parts[2]) : nil)
    }

    private func podcastShow(from detail: LibraryItemDetail) -> PodcastShow {
        let meta = detail.media.metadata
        let episodes = (detail.media.episodes ?? []).map { ep in
            PodcastEpisode(
                guid: "abspod:\(detail.id):\(ep.id)",
                title: ep.title ?? String(localized: "Untitled Episode"),
                audioURL: ep.audioTrack?.contentUrl ?? "",
                pubDate: ep.publishedAt ?? 0,
                duration: ep.duration ?? ep.audioTrack?.duration ?? 0,
                description: ep.description,
                imageURL: nil
            )
        }
        return PodcastShow(
            id: "abspod:\(detail.id)",
            title: meta?.title ?? "",
            author: meta?.authorName,
            // Cover goes via coverURL(forItemId:). Pass it as a string here too
            // so the pure URL accesses of the RSS UI (ShowTile) work as well.
            artworkURL: client.coverURL(forItemId: detail.id)?.absoluteString,
            description: meta?.description,
            feedURL: meta?.feedUrl ?? "",
            episodes: episodes
        )
    }

    /// PodcastEpisode → LibraryItem (track = episode audio file).
    private static func libraryItem(show: PodcastShow, episode: PodcastEpisode) -> LibraryItem {
        LibraryItem(
            id: episode.guid,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: episode.title,
                    authorName: show.title,
                    narratorName: nil,
                    seriesName: show.title,
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

    /// Server detail of a show + episode → LibraryItemDetail of the episode.
    private static func episodeDetail(itemId: String, show: LibraryItemDetail, episode: ABSPodcastEpisode) -> LibraryItemDetail {
        let track = episode.audioTrack.map {
            ABSAudioTrack(index: 0, startOffset: nil,
                          duration: episode.duration ?? $0.duration,
                          contentUrl: $0.contentUrl, metadata: $0.metadata)
        }
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: episode.title,
                authorName: show.media.metadata?.title,   // show title as "author"
                narratorName: nil,
                seriesName: show.media.metadata?.title,
                genres: nil,
                publishedYear: nil,
                description: episode.description
            ),
            duration: episode.duration ?? track?.duration,
            chapters: episode.chapters,   // chapters delivered by the server
            tracks: track.map { [$0] }
        )
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
    }
}
