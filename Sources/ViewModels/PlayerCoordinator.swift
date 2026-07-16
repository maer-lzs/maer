import Foundation
import Combine

/// Holds the currently running playback session, regardless of whether the full
/// player screen is visible or not. This is the prerequisite for the mini-player
/// bar: the player used to stop when leaving the screen, now it keeps running
/// until the user explicitly closes it or opens another book.
@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published private(set) var viewModel: PlayerViewModel? {
        didSet {
            // Mirror the active session's play state so list rows (e.g. podcast
            // episode rows) can show a live play/pause button without each
            // observing the nested view model.
            isPlayingCancellable = viewModel?.$isPlaying.sink { [weak self] in self?.isPlaying = $0 }
            if viewModel == nil { isPlaying = false }
        }
    }
    @Published private(set) var activeItem: LibraryItem?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published var loadError: String?

    private var isPlayingCancellable: AnyCancellable?

    let provider: any AudioProvider

    /// Set by the library screen (owner of the series data): returns the
    /// next unfinished book of the same series. Basis for the auto-play-
    /// next setting when a book finishes.
    var nextInSeriesProvider: ((String) -> LibraryItem?)?

    /// Remembers the last played item id across app restarts so the book is
    /// ready in the mini-player right away on the next launch.
    private let lastItemKey = AppStorageKeys.lastPlayedItemId

    init(provider: any AudioProvider) {
        self.provider = provider
    }

    /// Opens a book. If it is already active, nothing happens except possibly
    /// resuming playback. If another book is active, its session is cleanly ended
    /// (incl. a final sync) before the new one is loaded.
    /// - Parameter autoplay: true on a deliberate open by the user (starts
    ///   playback right after loading), false on a silent restore after app
    ///   start (stays paused).
    func open(item: LibraryItem, autoplay: Bool = true, restart: Bool = false) async {
        // Whatever you START playing leaves the global "Up Next" queue — the
        // currently playing item is never in it ("launchpad, not playlist").
        // Covers audiobooks, podcasts and music alike.
        PlayQueue.shared.remove(item.id)
        // A restart must reload (start at 0) even if it's the active item — don't
        // take the "already open, just resume" shortcut.
        if !restart, activeItem?.id == item.id, viewModel != nil {
            if autoplay { await viewModel?.playWithServerCheck() }
            return
        }

        // Launch window: playing right after a cold start (session restore,
        // CarPlay) must not race the startup download scan — an empty id set
        // would make a downloaded book stream (or fail offline) instead of
        // playing its local files. No-op once the scan has merged.
        await DownloadManager.shared.ensureScanned()

        // B2/A2: offline, a title that is not on the device cannot play — say
        // so clearly, and BEFORE tearing anything down: the running session
        // (mini player) must survive the rejected tap, otherwise it looks like
        // a crash. The hint is rendered both in the player and as a banner in
        // the library (the player screen may not be mounted).
        if !NetworkMonitor.shared.isConnected,
           !DownloadManager.shared.isDownloaded(itemId: item.id) {
            loadError = String(localized: "Offline — this title is not downloaded.")
            return
        }

        viewModel?.stop()
        viewModel = nil
        activeItem = item
        loadError = nil
        isLoading = true
        defer { isLoading = false }

        // Determine the item's source (server vs. local files) — the injected
        // `provider` is the default source, local items are routed away.
        let itemProvider = AppSession.shared.provider(for: item.id)
        do {
            let detail = try await itemProvider.fetchItemDetail(itemId: item.id)
            let newViewModel = PlayerViewModel(provider: itemProvider)
            await newViewModel.load(item: detail, restart: restart)
            attachBookEndHandler(to: newViewModel)
            viewModel = newViewModel
            UserDefaults.standard.set(item.id, forKey: lastItemKey)
            if autoplay {
                await newViewModel.playWithServerCheck()
            }
        } catch {
            // Server unreachable (e.g. offline on the go) — if the book is
            // downloaded, continue with the book details saved at download time
            // instead of failing entirely. Without this even a long-downloaded
            // book would need a working server connection just to open.
            if let cached = DownloadManager.shared.loadCachedDetail(forItemId: item.id) {
                let newViewModel = PlayerViewModel(provider: itemProvider)
                await newViewModel.load(item: cached, isOfflineFallback: true)
                attachBookEndHandler(to: newViewModel)
                viewModel = newViewModel
                UserDefaults.standard.set(item.id, forKey: lastItemKey)
                if autoplay {
                    await newViewModel.playWithServerCheck()
                }
            } else {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                activeItem = nil
            }
        }
    }

    /// Auto-continue when an item plays to its end. Order:
    /// 1. The global "Up Next" queue, CROSS-MEDIA and in order (a queued book,
    ///    episode or album plays next regardless of what just finished).
    /// 2. Queue empty → type-specific fallback: podcasts binge on (next unheard
    ///    of the same show, then other subs); audiobooks continue the series
    ///    (only if the setting is on).
    private func attachBookEndHandler(to viewModel: PlayerViewModel) {
        viewModel.onBookFinished = { [weak self] finishedItemId in
            guard let self else { return }
            // Invariant "heard = flies out": the finished item leaves the queue.
            // It was already removed when it started, but a restored-session item
            // (never opened via `open`) would otherwise linger.
            PlayQueue.shared.markedPlayed(finishedItemId)

            // 1. Cross-media queue: the next PLAYABLE entry, any type.
            if let next = self.nextPlayableQueueItem() {
                Task { await self.open(item: next) }
                return
            }

            // 2a. Podcast binge fallback.
            if finishedItemId.hasPrefix("rss:") || finishedItemId.hasPrefix("abspod:") {
                if let next = PodcastAutoContinue.next(after: finishedItemId) {
                    Task { await self.open(item: next) }
                }
                return
            }
            // 2b. Audiobooks: next book in the series (only if the setting is on).
            guard UserDefaults.standard.bool(forKey: AppStorageKeys.autoPlayNextInSeries),
                  let next = self.nextInSeriesProvider?(finishedItemId) else { return }
            Task { await self.open(item: next) }
        }
    }

    /// First queue entry that can actually start now, scanning in order. A3:
    /// offline only downloaded items are candidates — an undownloaded handoff
    /// would be rejected mid-transition and read like a crash. Entries that no
    /// longer resolve to a library item are skipped.
    private func nextPlayableQueueItem() -> LibraryItem? {
        let offline = !NetworkMonitor.shared.isConnected
        for id in PlayQueue.shared.ids {
            guard !offline || DownloadManager.shared.isDownloaded(itemId: id) else { continue }
            if let item = AppSession.shared.libraryItem(forId: id) { return item }
        }
        return nil
    }

    /// Restores the last played session on app start — paused, so nothing plays
    /// by itself. The book appears right in the mini-player. Called from the
    /// library once the list is available (so we have the matching LibraryItem).
    func restoreLastSession(from entries: [LibraryEntry]) async {
        guard viewModel == nil, activeItem == nil else { return }
        guard let lastId = UserDefaults.standard.string(forKey: lastItemKey) else { return }
        // Podcast episodes resolve through the subscriptions' episode index,
        // which now loads asynchronously at startup — wait for it, otherwise a
        // cold-start restore of a podcast episode races the disk load.
        if lastId.hasPrefix("rss:") || lastId.hasPrefix("abspod:") {
            await PodcastSubscriptions.shared.ensureLoaded()
        }
        // The last played item can come from ANY source — podcast episodes are
        // NOT in the audiobook list, only in the RSS provider.
        if let item = entries.first(where: { $0.id == lastId })?.item
            ?? AppSession.shared.libraryItem(forId: lastId) {
            await open(item: item, autoplay: false)
            return
        }
        // N1 fallback 1: ids without a local index entry (sub: albums/songs)
        // still resolve over their provider — restore from a light item built
        // out of the fetched detail. A successful open() re-writes lastItemKey,
        // healing the stale value for the next launch.
        if let detail = try? await AppSession.shared.provider(for: lastId)
            .fetchItemDetail(itemId: lastId) {
            await open(item: LibraryItem(id: detail.id, media: detail.media, addedAt: nil),
                       autoplay: false)
            return
        }
        // N1 fallback 2: the episode fell out of its feed (rotating news
        // feeds) — restore the SHOW context with its newest episode instead of
        // silently showing no mini player at all.
        if let showId = Self.showId(forEpisodeId: lastId),
           let show = PodcastSubscriptions.shared.shows.first(where: { $0.id == showId }) {
            let items = AppSession.shared.rssProvider.showItems(for: show)
            if let newest = items.max(by: { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) }) {
                await open(item: newest, autoplay: false)
            }
        }
    }

    /// "rss:<feedKey>:<originalGuid>" → the show id "feed:<feedKey>" used by
    /// the subscriptions store. Original guids may contain ':' (URLs), so at
    /// most the first two separators split.
    nonisolated static func showId(forEpisodeId id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "rss", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return "feed:\(parts[1])"
    }

    /// Stops playback completely (the mini bar disappears).
    func close() {
        viewModel?.stop()
        viewModel = nil
        activeItem = nil
        loadError = nil
        UserDefaults.standard.removeObject(forKey: lastItemKey)
    }
}
