// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

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

    /// X16b: set by the library screen — called when an item is (re)started from
    /// the beginning so the library can clear its local 'finished' flag.
    var onItemRestarted: ((String) -> Void)?

    /// Remembers the last played item id across app restarts so the book is
    /// ready in the mini-player right away on the next launch.
    private let lastItemKey = AppStorageKeys.lastPlayedItemId

    init(provider: any AudioProvider) {
        self.provider = provider
    }

    #if DEBUG
    /// UI-test only (X14): install a PRESENTATION-ONLY session — a view model
    /// with item/chapters set but no AVPlayer — so the harness can open the full
    /// player and screenshot its title/chapter layout without a real audio
    /// stream. Must live here because `viewModel`/`activeItem` are `private(set)`.
    func _seedActivePlayerForUITest(item: LibraryItem, detail: LibraryItemDetail,
                                    chapters: [ABSChapter], currentChapterIndex: Int,
                                    isFallback: Bool) {
        let vm = PlayerViewModel(provider: provider)
        vm.item = detail
        vm.chapters = chapters
        vm.currentChapter = chapters.indices.contains(currentChapterIndex) ? chapters[currentChapterIndex] : nil
        vm.chaptersAreFallback = isFallback
        vm.duration = detail.media.duration ?? 0
        vm.currentTime = vm.currentChapter?.start ?? 0
        viewModel = vm
        activeItem = item
    }
    #endif

    /// Opens a book. If it is already active, nothing happens except possibly
    /// resuming playback. If another book is active, its session is cleanly ended
    /// (incl. a final sync) before the new one is loaded.
    /// - Parameter autoplay: true on a deliberate open by the user (starts
    ///   playback right after loading), false on a silent restore after app
    ///   start (stays paused).
    /// X16: whether opening a title starts from the beginning. An explicit
    /// restart always does; a finished title does when it is a deliberate play
    /// (autoplay) — there is nothing to resume; a silent restore never does (it
    /// must not reset a finished book's position just by relaunching).
    nonisolated static func resolvesToRestart(explicitRestart: Bool, autoplay: Bool, isFinished: Bool) -> Bool {
        explicitRestart || (autoplay && isFinished)
    }

    /// X19: a running FIXED-minutes sleep timer carries across an item change
    /// (auto-continue / manual open) — it means "stop after X min of listening",
    /// independent of the title. A position-based mode (until chapter/track end)
    /// is bound to the current item and does not carry (it fires at that boundary).
    nonisolated static func carriedSleepRemaining(remaining: TimeInterval?, untilChapterEnd: Bool,
                                                  untilTrackEnd: Bool) -> TimeInterval? {
        guard let remaining, remaining > 0, !untilChapterEnd, !untilTrackEnd else { return nil }
        return remaining
    }

    /// 🔴 P15: every `open()` draws a GENERATION. After each await the call
    /// asks "am I still the current one?" — a stale return cleans itself up
    /// (including a player it already built) instead of starting a second
    /// audio track. Without this, hammering play on a bad connection queued
    /// several calls in the network timeouts, and when the connection came
    /// back they ALL returned and started: overlapping playback. The
    /// `viewModel?.stop()` at the top cannot help there, because the racers
    /// are long past it.
    private var openGate = OpenGate()

    private var openGeneration: Int { openGate.current }

    func open(item: LibraryItem, autoplay: Bool = true, restart: Bool = false) async {
        // Coalesce + draw a generation — the rule itself lives in `OpenGate`
        // (pure, tested): the same title already on its way answers nil.
        guard let generation = openGate.begin(itemId: item.id, restart: restart) else { return }
        defer { openGate.finish(generation) }
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

        // X19: capture a running fixed-minutes sleep timer BEFORE tearing down the
        // old session, so it can continue on the next title.
        let carriedSleep = Self.carriedSleepRemaining(
            remaining: viewModel?.sleepTimerRemaining,
            untilChapterEnd: viewModel?.sleepUntilChapterEnd ?? false,
            untilTrackEnd: viewModel?.sleepUntilTrackEnd ?? false)

        viewModel?.stop()
        viewModel = nil
        activeItem = item
        loadError = nil
        isLoading = true
        defer { isLoading = false }

        // Determine the item's source (server vs. local files) — the injected
        // `provider` is the default source, local items are routed away.
        let itemProvider = AppSession.shared.provider(for: item.id)
        // 🔴 P15 (2): DOWNLOADED means LOCAL FIRST — always, not only when
        // the monitor says "offline". The degraded case (connected but
        // unusable, one bar of LTE) ran into the network timeouts although
        // the book AND its detail were on the device. This is no new code
        // path: the offline route becomes the DOWNLOAD route, and the
        // network state only decides whether a background reconciliation
        // follows.
        if DownloadManager.shared.isDownloaded(itemId: item.id),
           let cached = DownloadManager.shared.loadCachedDetail(forItemId: item.id) {
            // 5f4fdee: if the cached detail carries NO progress, the local
            // route would show a confident "00:00" until someone presses play
            // — and that invitation is the dangerous one. So ask the server
            // FIRST in that case, with the same 1.5 s patience the play path
            // uses. Only the silent case pays the wait; a cached detail with a
            // position opens as immediately as before.
            var detail = cached
            if cached.userMediaProgress == nil,
               itemProvider.capabilities.contains(.progressSync),
               let fresh = await Self.boundedDetail(provider: itemProvider, itemId: item.id) {
                detail = fresh
                DownloadManager.shared.updateCachedProgress(
                    itemId: item.id, progress: fresh.userMediaProgress ?? MediaProgress(
                        currentTime: 0, duration: nil, progress: nil,
                        isFinished: nil, lastUpdate: nil))
            }
            guard generation == openGeneration else { return }
            await start(detail: detail, item: item, provider: itemProvider,
                        offlineFallback: true, autoplay: autoplay, restart: restart,
                        carriedSleep: carriedSleep, generation: generation)
            // The server side follows AFTERWARDS and corrects the position
            // through the existing server-wins/echo-guard mechanics — it must
            // never hard-jump a RUNNING playback (that rule lives in
            // `playWithServerCheck`, which is exactly what runs here).
            return
        }
        do {
            let detail = try await itemProvider.fetchItemDetail(itemId: item.id)
            guard generation == openGeneration else { return }
            await start(detail: detail, item: item, provider: itemProvider,
                        offlineFallback: false, autoplay: autoplay, restart: restart,
                        carriedSleep: carriedSleep, generation: generation)
        } catch {
            // Server unreachable (e.g. offline on the go) — if the book is
            // downloaded, continue with the book details saved at download time
            // instead of failing entirely. Without this even a long-downloaded
            // book would need a working server connection just to open.
            guard generation == openGeneration else { return }
            if let cached = DownloadManager.shared.loadCachedDetail(forItemId: item.id) {
                await start(detail: cached, item: item, provider: itemProvider,
                            offlineFallback: true, autoplay: autoplay, restart: restart,
                            carriedSleep: carriedSleep, generation: generation)
            } else {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                activeItem = nil
            }
        }
    }

    /// The server answer with a deadline — same 1.5 s as `playWithServerCheck`,
    /// same reason: an unreachable server must not hold the player hostage.
    /// nil means "did not answer in time", never "there is no progress".
    private static func boundedDetail(provider: any AudioProvider,
                                      itemId: String) async -> LibraryItemDetail? {
        await withTaskGroup(of: LibraryItemDetail?.self) { group in
            group.addTask { try? await provider.fetchItemDetail(itemId: itemId) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The ONE start path for both routes (server detail and local detail) —
    /// it was duplicated before, which is why the generation check would have
    /// had to be written twice. Every await is followed by the generation
    /// question: a stale return stops the player it built instead of leaving
    /// a second track running.
    private func start(detail: LibraryItemDetail, item: LibraryItem,
                       provider: any AudioProvider, offlineFallback: Bool,
                       autoplay: Bool, restart: Bool,
                       carriedSleep: TimeInterval?, generation: Int) async {
        let newViewModel = PlayerViewModel(provider: provider)
        // X16: a finished title has nothing left to resume — its saved
        // position is the end. A deliberate play (autoplay) therefore restarts
        // from the beginning via the existing restart mechanic; a silent
        // restore (autoplay == false) leaves it untouched.
        let effectiveRestart = Self.resolvesToRestart(
            explicitRestart: restart, autoplay: autoplay,
            isFinished: detail.userMediaProgress?.isFinished == true)
        await newViewModel.load(item: detail, isOfflineFallback: offlineFallback,
                                restart: effectiveRestart)
        guard generation == openGeneration else { newViewModel.stop(); return }
        if effectiveRestart { onItemRestarted?(item.id) }   // X16b: clear the local finished flag
        attachBookEndHandler(to: newViewModel)
        viewModel = newViewModel
        UserDefaults.standard.set(item.id, forKey: lastItemKey)
        if let carriedSleep { newViewModel.startSleepTimer(minutes: carriedSleep / 60) }
        if autoplay {
            await newViewModel.playWithServerCheck()
            guard generation == openGeneration else { newViewModel.stop(); return }
        }
    }

    /// Shuffle-play a set of playable items in random order. Regel 2: the whole
    /// music library, a playlist and an album all funnel here — each supplies its
    /// own pool, the shared `MediaShuffle` sets the order. The first item starts
    /// now; the shuffled tail becomes the Up-Next context and plays through the
    /// existing cross-media auto-continue. An empty pool is a no-op.
    func shufflePlay(items: [LibraryItem]) async {
        await playInOrder(items: MediaShuffle.shuffled(items))
    }

    /// Play a set of items in the ORDER given — the shared tail of every
    /// "play this collection" surface: the first item starts now, the rest
    /// becomes the Up-Next context and plays through the existing
    /// auto-continue. Shuffle is the same path with a shuffled order, so the
    /// two do not drift apart. An empty set is a no-op.
    func playInOrder(items: [LibraryItem]) async {
        guard let first = items.first else { return }
        // The tail replaces Up Next; open() also drops `first` if it lingers.
        PlayQueue.shared.setUpNext(items.dropFirst().map(\.id))
        await open(item: first, restart: true)
    }

    /// Auto-continue when an item plays to its end. Order:
    /// 1. The global "Up Next" queue, CROSS-MEDIA and in order (a queued book,
    ///    episode or album plays next regardless of what just finished).
    /// 2. Queue empty → type-specific fallback: podcasts binge on (next unheard
    ///    of the same show, then other subs); audiobooks continue the series
    ///    (only if the setting is on).
    private func attachBookEndHandler(to viewModel: PlayerViewModel) {
        viewModel.onBookFinished = { [weak self] finishedItemId in
            self?.advanceAfterFinish(finishedItemId: finishedItemId)
        }
        // The headphone title button's queue hop. SKIPPING IS NOT FINISHING:
        // the natural-end path above finalises the item as heard — a skip must
        // not, or every skipped song joins the freshly healed class anew. This
        // path shares the RESOLUTION (nextPlayableQueueItem) and nothing else;
        // the skipped item keeps its position and its unheard state.
        viewModel.onQueueSkipRequested = { [weak self] in
            guard let self, let next = self.nextPlayableQueueItem() else { return false }
            Task { await self.open(item: next) }
            return true
        }
    }

    /// The natural-end advance, shared by the real end-of-item handler and the
    /// manual "mark as played" (X16c). The finished item leaves the queue, then
    /// the next playable item starts.
    private func advanceAfterFinish(finishedItemId: String) {
        // Invariant "heard = flies out": the finished item leaves the queue.
        // It was already removed when it started, but a restored-session item
        // (never opened via `open`) would otherwise linger.
        PlayQueue.shared.markedPlayed(finishedItemId)

        // 1. Cross-media queue: the next PLAYABLE entry, any type.
        if let next = nextPlayableQueueItem() {
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
              let next = nextInSeriesProvider?(finishedItemId) else { return }
        Task { await self.open(item: next) }
    }

    /// X16c/X16d: mark the ACTIVE item as played AS IF it ended naturally —
    /// playback stops (its progress is finalized as finished so the stop's final
    /// sync writes "finished", not the current position) and the auto-continue
    /// logic advances to the next item (or the session just ends if there is
    /// none). A NON-active item is a no-op here: the callers already drop it from
    /// the queue themselves, and advancing would interrupt whatever is playing.
    func markPlayedAndAdvance(itemId: String) {
        guard activeItem?.id == itemId, let vm = viewModel else { return }
        vm.finalizeAsFinished()
        vm.stop()
        viewModel = nil
        activeItem = nil
        advanceAfterFinish(finishedItemId: itemId)
    }

    /// First queue entry that can actually start now, scanning in order. A3:
    /// offline only downloaded items are candidates — an undownloaded handoff
    /// would be rejected mid-transition and read like a crash. Entries that no
    /// longer resolve to a library item are skipped.
    private func nextPlayableQueueItem() -> LibraryItem? {
        let offline = !NetworkMonitor.shared.isConnected
        let ids = PlayQueue.shared.ids
        guard let id = QueueContinuation.nextPlayable(
            ids: ids,
            isPlayable: { !offline || DownloadManager.shared.isDownloaded(itemId: $0) },
            // Resolution on demand: a catalogue id is self-describing, the
            // session cache is only a shortcut — a cache miss made the
            // advancer end silently on entries it could have fetched.
            resolves: { AppSession.shared.playableItem(forId: $0) != nil }
        ) else {
            // The end has a REASON, and it is told apart: an empty queue is
            // normal, entries that cannot start now are a finding.
            if !ids.isEmpty {
                Logger.library.notice("QUEUE advance ends: \(ids.count) entries, none playable (offline=\(offline))")
            }
            return nil
        }
        return AppSession.shared.playableItem(forId: id)
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
