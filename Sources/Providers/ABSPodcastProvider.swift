// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

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
        archivedShowIds = Set(AppStorageKeys.stringArray(Self.archiveKey) ?? [])
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
    /// The feed's own handles of each episode (guid and enclosure as the
    /// feed carries them), by `abspod:` id. A foreign import matches its
    /// states on them; the episode's own fields are the server's.
    private(set) var episodeHandles: [String: ServerEpisodeHandle] = [:]
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
        AppStorageKeys.set(Array(archivedShowIds), for: Self.archiveKey)
        changeToken += 1
    }

    // MARK: - AudioProvider

    var providerId: String { "abspod" }
    var mediaTypes: Set<MediaType> { [.podcasts] }
    var keepsMarksOnDevice: Bool { false }
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
        guard let episodeId else { throw ItemNotHere.episodeNotOnServer }
        let detail = try await client.fetchItemDetail(itemId: showId)
        guard let episode = detail.media.episodes?.first(where: { $0.id == episodeId }) else {
            throw ItemNotHere.episodeNotOnServer
        }
        return Self.episodeDetail(itemId: itemId, show: detail, episode: episode)
    }

    func coverURL(forItemId itemId: String) -> URL? {
        client.coverURL(forItemId: Self.split(itemId).show)   // the show's cover
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
        // tab disappears or goes empty. The failure is logged.
        let libs: [ABSLibrary]
        do {
            libs = try await client.fetchPodcastLibraries()
        } catch {
            Logger.library.error("ABSPOD availability failed, kept: \(FailureReason.of(error), privacy: .public)")
            return
        }
        hasPodcasts = !libs.isEmpty
    }

    /// Timestamp of the last refresh that adopted the server's answer.
    /// Basis for the throttle below: a run that kept the stock because a
    /// fetch failed does not stamp it, so the next mount asks again.
    private var lastRefreshAt: Date?
    /// When the last refresh failed without adopting an answer: the
    /// implicit callers wait out its holdback instead of asking again.
    private var failedAt: Date?

    /// Whether the server's answer about its shows was adopted in this
    /// session. The shows are not stored, so before that an empty list
    /// says nothing about the server (`ServerHolding.unread`).
    var showsRead: Bool { lastRefreshAt != nil }

    /// After a read that answered: the shows the person subscribed here
    /// while this server could not be read are settled against it.
    private func afterShowsRead() {
        Task { await PodcastSubscriptions.shared.settleUnchecked() }
    }

    /// The ONE way the shows change: the bridge with them, the episode
    /// handles, and the token the podcast tab recomputes on. Every caller
    /// names the handles, so shows and handles never part.
    private func replaceShows(_ next: [PodcastShow], absToRSS: [String: String], rssToABS: [String: String],
                              handles: [String: ServerEpisodeHandle]) {
        shows = next
        self.absToRSS = absToRSS
        self.rssToABS = rssToABS
        episodeHandles = handles
        changeToken += 1
    }

    /// Throttled refresh for frequent, implicit callers (the podcast tab's
    /// mount task): skips when the catalog was loaded recently. Pull-to-refresh
    /// keeps calling `refresh()` directly for an unconditional reload.
    func refreshIfStale(maxAge: TimeInterval = 300) async {
        guard ABSPodcastRefreshRule.mayRefresh(lastRefreshAt: lastRefreshAt, failedAt: failedAt,
                                               now: Date(), maxAge: maxAge) else { return }
        await refresh()
    }

    /// Load shows + episodes of all podcast libraries. Best effort: individual
    /// failed shows are skipped, the rest stays usable. A pull that fails
    /// starts the same holdback as an implicit run, on purpose: it is the
    /// same evidence that the server does not answer now, and the tab's
    /// implicit runs wait as after any failed run.
    func refresh() async {
        // ABS is opt-in as a podcast source. Without it enabled load nothing and
        // clear the existing state (the user then uses ABS for audiobooks only).
        guard AppStorageKeys.absPodcastsActive else {
            if hasPodcasts || !shows.isEmpty {
                hasPodcasts = false
                replaceShows([], absToRSS: [:], rssToABS: [:], handles: [:])
            }
            return
        }
        // Retry queued played-writes first (failed offline). The refresh is
        // the natural reconnect point.
        await flushPendingPlayedWrites()
        // Failed library fetch → KEEP the existing state, don't clear (this
        // refresh runs on every tab switch; a brief net hiccup would otherwise
        // empty the whole podcast tab). The failure is logged.
        let libraries: [ABSLibrary]
        do {
            libraries = try await client.fetchPodcastLibraries()
        } catch {
            Logger.library.error("ABSPOD libraries failed, shows kept: \(FailureReason.of(error), privacy: .public)")
            if FetchHoldback.starts(after: error) { failedAt = Date() }
            return
        }
        guard !libraries.isEmpty else {
            // The server really has no podcast library: an answer, adopted.
            hasPodcasts = false
            replaceShows([], absToRSS: [:], rssToABS: [:], handles: [:])
            lastRefreshAt = Date()
            afterShowsRead()
            return
        }
        hasPodcasts = true
        // Progress of all episodes in one go (for the played state); a
        // failure keeps the progress held and is logged.
        do {
            episodeProgress = try await client.fetchPodcastEpisodeProgress()
        } catch {
            Logger.library.error("ABSPOD progress failed, kept: \(FailureReason.of(error), privacy: .public)")
        }

        let client = self.client
        let fetched = await Self.fetchShows(
            libraryIds: libraries.map(\.id),
            items: { try await client.fetchLibraryItems(libraryId: $0).map(\.id) },
            detail: { try await client.fetchItemDetail(itemId: $0) })
        var loaded: [PodcastShow] = []
        var newAbsToRSS: [String: String] = [:]
        var newRSSToABS: [String: String] = [:]
        var newHandles: [String: ServerEpisodeHandle] = [:]
        for detail in fetched.details {
            loaded.append(podcastShow(from: detail))
            // Build the feed-guid bridge → both ids (for shared history).
            let feedURL = detail.media.metadata?.feedUrl ?? ""
            guard !feedURL.isEmpty else { continue }
            let feedKey = PodcastSubscriptions.feedKey(feedURL)
            for ep in detail.media.episodes ?? [] {
                newHandles["abspod:\(detail.id):\(ep.id)"] = ServerEpisodeHandle(guid: ep.guid, enclosure: ep.enclosure?.url)
                guard let orig = ep.guid ?? ep.enclosure?.url, !orig.isEmpty else { continue }
                let rssId = "rss:\(feedKey):\(orig)"
                let absId = "abspod:\(detail.id):\(ep.id)"
                newAbsToRSS[absId] = rssId
                newRSSToABS[rssId] = absId
            }
        }

        if ABSPodcastRefreshRule.adopts(everyFetchAnswered: fetched.failures == 0,
                                        loadedAny: !loaded.isEmpty, holdsShows: !shows.isEmpty) {
            replaceShows(loaded, absToRSS: newAbsToRSS, rssToABS: newRSSToABS, handles: newHandles)
            lastRefreshAt = Date()
            afterShowsRead()
            failedAt = nil
        } else if fetched.holdsBack {
            // Fetches failed and nothing came back: the stock stays, and the
            // loops that ask per feed wait out the holdback. Only a failure
            // that earns it starts one, by the same rule as the library list
            // above (`FetchHoldback.starts`); a cancellation is no failure.
            // A show deleted on the server is no failure either but an
            // answer (`FetchedShows.gone`), so a run of absences alone is
            // adopted above and never ends in neither.
            failedAt = Date()
        }
    }

    /// What one refresh fetched: the show details that came back, how many
    /// fetches (item lists and details) failed, how many answered that
    /// their library or show is gone, and whether one of the failures earns
    /// a holdback (`FetchHoldback.starts`). A gone fetch is an answer, not a
    /// failure: the server said what it holds.
    nonisolated struct FetchedShows: Sendable {
        var details: [LibraryItemDetail]
        var failures: Int
        var holdsBack = false
        var gone = 0
    }

    /// The item ids of every library, then their details in parallel,
    /// batched (at most five at once; serial was noticeably slow with many
    /// shows). Every failed fetch is logged with its reason and counted, so
    /// an empty answer can be told from "nothing came through"; a fetch that
    /// answers "gone" counts as an answer (`gone`).
    nonisolated static func fetchShows(
        libraryIds: [String],
        items: @escaping @Sendable (String) async throws -> [String],
        detail: @escaping @Sendable (String) async throws -> LibraryItemDetail
    ) async -> FetchedShows {
        var failures = 0
        var holdsBack = false
        var gone = 0
        var itemIds: [String] = []
        for libraryId in libraryIds {
            do {
                itemIds.append(contentsOf: try await items(libraryId))
            } catch {
                if FreeCatalog.isGone(error) { gone += 1 } else { failures += 1 }
                if FetchHoldback.starts(after: error) { holdsBack = true }
                Logger.library.error("ABSPOD items failed library=\(libraryId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
            }
        }
        var details: [LibraryItemDetail] = []
        var i = 0
        while i < itemIds.count {
            let batch = itemIds[i..<min(i + 5, itemIds.count)]
            i += 5
            let results = await withTaskGroup(of: (String, Result<LibraryItemDetail, Error>).self) { group in
                for id in batch {
                    group.addTask {
                        do { return (id, .success(try await detail(id))) } catch { return (id, .failure(error)) }
                    }
                }
                var out: [(String, Result<LibraryItemDetail, Error>)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (id, result) in results {
                switch result {
                case .success(let loaded):
                    details.append(loaded)
                case .failure(let error):
                    if FreeCatalog.isGone(error) { gone += 1 } else { failures += 1 }
                    if FetchHoldback.starts(after: error) { holdsBack = true }
                    Logger.library.error("ABSPOD detail failed item=\(id, privacy: .public): \(FailureReason.of(error), privacy: .public)")
                }
            }
        }
        return FetchedShows(details: details, failures: failures, holdsBack: holdsBack, gone: gone)
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
            let localTs = arr[1]
            let serverTs = episodeProgress[absId]?.lastUpdate ?? -1
            guard localTs > serverTs else { continue }

            let (showId, episodeId) = Self.split(absId)
            guard let episodeId,
                  let ep = shows.first(where: { $0.id == "abspod:\(showId)" })?
                      .episodes.first(where: { $0.guid == absId }) else { continue }
            let duration = ep.duration
            // The one form of a write to the server, as the import sends it.
            let write = ForeignServerProgress.write(arr, duration: duration)
            do {
                try await client.updateEpisodeProgress(
                    libraryItemId: showId, episodeId: episodeId,
                    currentTime: write.time, duration: duration, isFinished: write.finished
                )
                didPush = true
            } catch {
                Logger.library.error("ABSPOD history push failed item=\(absId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
            }
        }
        if didPush { await refreshProgress() }
    }

    /// Only re-pull the server progress (after playback/"mark as played").
    func refreshProgress() async {
        _ = await freshEpisodeProgress()
    }

    /// The server progress read now, or nil when the read failed. A failed
    /// request (offline!) KEEPS the cached server state and does not count
    /// the token: the surface would show the old state as a fresh one.
    func freshEpisodeProgress() async -> [String: BookProgress]? {
        do {
            episodeProgress = try await client.fetchPodcastEpisodeProgress()
            changeToken += 1
            return episodeProgress
        } catch {
            Logger.library.error("ABSPOD progress refresh failed, kept: \(FailureReason.of(error), privacy: .public)")
            return nil
        }
    }

    /// Writes one episode's progress, for a foreign import.
    func writeEpisodeProgress(_ itemId: String, time: Double, duration: Double, finished: Bool) async throws {
        let (showId, episodeId) = Self.split(itemId)
        guard let episodeId else { throw ForeignServerSideError.notAServerEpisode }
        try await client.updateEpisodeProgress(libraryItemId: showId, episodeId: episodeId,
                                               currentTime: time, duration: duration, isFinished: finished)
    }

    // MARK: - Pending played-writes (offline retry)

    /// Server writes that failed (usually offline). itemId → target state.
    /// Persisted so the intent survives an app kill; flushed on the next
    /// catalog refresh (tab entry / reconnect path).
    private var pendingPlayedWrites: [String: Bool] {
        get { (AppStorageKeys.dictionary(AppStorageKeys.absPendingPlayedWrites) as? [String: Bool]) ?? [:] }
        set { AppStorageKeys.set(newValue, for: AppStorageKeys.absPendingPlayedWrites) }
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
                // A network outage, a server error, a pause or a sign-in
                // problem keeps the entry; a refusal for good (the episode is
                // gone, the write is rejected) drops it, said in the log. The
                // person's mark stays on this device either way.
                if !ABSPlayedWriteRetry.keeps(status: Self.refusalStatus(error)) { remaining[itemId] = nil }
                Logger.library.error("ABSPOD played write failed item=\(itemId, privacy: .public) kept=\(ABSPlayedWriteRetry.keeps(status: Self.refusalStatus(error)), privacy: .public): \(FailureReason.of(error), privacy: .public)")
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
            catch {
                Logger.library.error("ABSPOD new show feed failed: \(FailureReason.of(error), privacy: .public)")
                return "Feed (podcasts/feed): \(Self.msg(error))"
            }

            // Folders usually come with the list endpoint; otherwise detail.
            var folders = library.folders ?? []
            if folders.isEmpty {
                do { folders = try await client.fetchLibraryFolders(libraryId: library.id) }
                catch {
                    Logger.library.error("ABSPOD new show folders failed: \(FailureReason.of(error), privacy: .public)")
                    return "Ordner (libraries/id): \(Self.msg(error))"
                }
            }
            guard let folder = folders.first, let folderPath = folder.fullPath else {
                return "Kein Ordner in der Podcast-Bibliothek."
            }

            let title = Self.sanitizePathComponent(metadata.title ?? "Podcast")
            let path = (folderPath as NSString).appendingPathComponent(title)
            do {
                try await client.createPodcast(libraryId: library.id, folderId: folder.id,
                                               path: path, metadata: metadata, autoDownload: autoDownload)
            } catch {
                Logger.library.error("ABSPOD new show create failed: \(FailureReason.of(error), privacy: .public)")
                return "Anlegen (POST podcasts): \(Self.msg(error))"
            }

            await refresh()
            // Push the high-resolution feed cover (prefer our itunes:image;
            // otherwise the one from the server feed response).
            await pushHighResCover(feedURL: feedURL, cover: coverURL ?? metadata.image)
            return nil
        } catch {
            Logger.library.error("ABSPOD libraries for a new show failed: \(FailureReason.of(error), privacy: .public)")
            return "Bibliotheken: \(Self.msg(error))"
        }
    }

    /// Lift the cover of an existing server show to a high-resolution feed
    /// cover. Best effort.
    func updateShowCover(showId: String, coverURL: String) async {
        guard showId.hasPrefix("abspod:"), !coverURL.isEmpty else { return }
        let itemId = String(showId.dropFirst("abspod:".count))
        do {
            try await client.updateItemCover(itemId: itemId, coverURL: coverURL)
        } catch {
            Logger.library.notice("ABSPOD cover not lifted show=\(itemId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
        }
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
        do {
            try await client.updateItemCover(itemId: itemId, coverURL: cover)
        } catch {
            Logger.library.notice("ABSPOD cover not pushed show=\(itemId, privacy: .public): \(FailureReason.of(error), privacy: .public)")
        }
    }

    private static func msg(_ error: Error) -> String {
        ErrorSentence.of(error)
    }

    /// The HTTP status of a refusal by the server, nil when no answer came.
    nonisolated static func refusalStatus(_ error: Error) -> Int? {
        if case APIError.http(let status, _) = error { return status }
        return nil
    }

    /// Feed episodes of an ABS show that are NOT yet on the server (loadable).
    /// Matched by title (the library episodes carry the feed titles).
    func availableEpisodes(for show: PodcastShow) async -> [FeedEpisode] {
        guard !show.feedURL.isEmpty else { return [] }
        let raw: [[String: Any]]
        do {
            raw = try await client.fetchFeedEpisodes(rssFeed: show.feedURL)
        } catch {
            Logger.library.error("ABSPOD feed episodes failed: \(FailureReason.of(error), privacy: .public)")
            return []
        }
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
            Logger.library.error("ABSPOD episode download failed: \(FailureReason.of(error), privacy: .public)")
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
    /// Nil when the server took it; otherwise the error, so the page can stay
    /// and say why instead of closing as if it were gone.
    func deleteShowOnServer(showId: String) async -> Error? {
        do {
            try await client.deleteLibraryItem(itemId: Self.split(showId).show)
            await refresh()
            return nil
        } catch {
            Logger.library.error("ABSPOD show delete failed: \(FailureReason.of(error), privacy: .public)")
            return error
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
            // Offline or server down: the intent is queued and retried on the
            // next refresh; a refusal for good is said and not queued. The
            // mark itself stands on this device either way.
            let keeps = ABSPlayedWriteRetry.keeps(status: Self.refusalStatus(error))
            if keeps { pendingPlayedWrites[item.id] = played }
            Logger.library.error("ABSPOD mark played failed item=\(item.id, privacy: .public) queued=\(keeps, privacy: .public): \(FailureReason.of(error), privacy: .public)")
        }
        await refreshProgress()
    }

    /// Played state of an ABS episode from the server progress.
    /// `tail` nil is the person's own; 0 asks for the true end (the
    /// server's finished flag still counts).
    func state(forEpisodeId itemId: String, duration: Double, tail: Double? = nil) -> EpisodePlayState {
        guard let bp = episodeProgress[itemId] else { return .unplayed }
        return ProgressMark.serverState(isFinished: bp.isFinished, fraction: bp.fraction, duration: duration,
                                        tail: tail ?? PlayedTail.seconds(forItemId: itemId))
    }

    /// Single episode as a LibraryItem from the loaded cache (for
    /// resume/restore). Synchronous, no network.
    func libraryItem(forEpisodeId itemId: String) -> LibraryItem? {
        for show in shows {
            if let episode = show.episodes.first(where: { $0.guid == itemId }) {
                return podcastLibraryItem(show: show, episode: episode)
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
