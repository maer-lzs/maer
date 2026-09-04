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
            // Same reason as above, one level further: a tile reading
            // `viewModel.icyDisplayLine` while observing only THIS object never
            // hears the title arrive. A nested ObservableObject publishes to
            // its own observers, not to ours. Measured: the mini bar carried
            // the running title while every tile line stayed empty, and the
            // line only appeared once something else redrew the row. That is
            // exactly "we get new info at the moment we click".
            icyCancellable = viewModel?.$icyStreamTitle.sink { [weak self] raw in
                // The INCOMING value through the shared derivation: a sink runs
                // before the property is set, so reading `icyDisplayLine` back
                // here would publish the previous song.
                self?.nowPlayingLine = PlayerViewModel.displayLine(fromStreamTitle: raw)
            }
            if viewModel == nil { isPlaying = false; nowPlayingLine = nil }
        }
    }

    /// The running ICY line of the active item, mirrored for list surfaces
    /// (radio tiles/cards) that must not each observe the nested view model.
    @Published private(set) var nowPlayingLine: String?
    @Published private(set) var activeItem: LibraryItem?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published var loadError: String?

    private var isPlayingCancellable: AnyCancellable?
    private var icyCancellable: AnyCancellable?
    private var standbyCancellable: AnyCancellable?

    let provider: any AudioProvider

    /// Set by the library screen (owner of the series data): returns the
    /// next unfinished book of the same series. Basis for the auto-play-
    /// next setting when a book finishes.
    var nextInSeriesProvider: ((String) -> LibraryItem?)?

    /// X16b: set by the library screen. Called when an item is (re)started from
    /// the beginning so the library can clear its local 'finished' flag.
    var onItemRestarted: ((String) -> Void)?

    /// Remembers the last played item id across app restarts so the book is
    /// ready in the mini-player right away on the next launch.
    private let lastItemKey = AppStorageKeys.lastPlayedItemId

    init(provider: any AudioProvider) {
        self.provider = provider
        // Takeover: a foreign claim on the item THIS device is
        // playing means another device took over on explicit play. This
        // side stands down by itself and pushes its final state (pause()
        // force-syncs). No remote control, no locks; the claim age in the
        // log line is the latency witness for the device pair.
        PlaybackClaimSync.shared.onForeignClaim = { [weak self] claim in
            guard let self else { return }
            let nowMs = Date().timeIntervalSince1970 * 1000
            let age = Int((nowMs - claim.t) / 1000)
            let held = self.viewModel?.isPlaying == true ? self.activeItem?.id : nil
            // Second witness: the own fresh claim. Written only while
            // playing, so it says "this device plays X" even when the
            // coordinator's view of itself does not.
            let sync = PlaybackClaimSync.shared
            let playing = PlaybackClaimRules.playingItem(
                held: held, ownClaim: sync.lastOwnClaim,
                ownDeviceId: SyncHistoryStore.deviceId, nowMs: nowMs)
            let pause = PlaybackClaimRules.shouldPause(
                claim: claim, ownDeviceId: SyncHistoryStore.deviceId,
                playingItemId: playing, nowMs: nowMs)
            // Every foreign claim leaves a line, above all the ones that
            // change nothing: a takeover that never stops this device is
            // invisible otherwise, and the age is the latency witness.
            let verdict = pause ? "takeover"
                : claim.released ? "released"
                : playing == nil ? "not playing"
                : claim.itemId != playing ? "other item"
                : "stale"
            // The three inputs of `playing`, spelled out: which view model
            // this coordinator holds, whether it says it plays, and which
            // item is active. A takeover that never stops this device is
            // decided in one of these three, and the verdict alone cannot
            // say which.
            let heldVM = self.viewModel.map { PlaybackClaimSync.instanceTag($0) } ?? "nil"
            Logger.player.notice("CLAIM seen item=\(claim.itemId, privacy: .public) age=\(age)s playing=\(playing ?? "-", privacy: .public) verdict=\(verdict, privacy: .public) device=\(claim.deviceId.prefix(8), privacy: .public) vm=\(heldVM, privacy: .public) vmPlaying=\(self.viewModel?.isPlaying == true) active=\(self.activeItem?.id ?? "nil", privacy: .public) coord=\(PlaybackClaimSync.instanceTag(self), privacy: .public)")
            guard pause else {
                // The other side's final stand, arriving after this device
                // took over: catch up when it is more than a few seconds
                // away, so the two devices agree on where the episode is.
                if let vm = self.viewModel, vm.isPlaying,
                   let target = PlaybackClaimRules.catchUpPosition(
                       claim: claim, playingItemId: playing,
                       ownDeviceId: SyncHistoryStore.deviceId,
                       startedAtMs: vm.lastClaimAtMs, currentTime: vm.currentTime) {
                    Logger.player.notice("CLAIM catch-up item=\(claim.itemId, privacy: .public) from=\(Int(vm.currentTime)) to=\(Int(target))")
                    Task { await vm.seek(to: target, userInitiated: false) }
                }
                return
            }
            // The pause goes to whoever wrote the claim: that is the view
            // model that plays. The held one is the fallback, never the
            // only target.
            let writer = sync.lastWriter as? PlayerViewModel
            guard let target = writer ?? self.viewModel else { return }
            Logger.player.notice("CLAIM pause via=\(writer != nil ? "writer" : "held", privacy: .public) vm=\(PlaybackClaimSync.instanceTag(target), privacy: .public)")
            target.pause()
        }
        // The standby follows the fresh truth while the app runs. A
        // pointer adoption and every deliberate progress change re-ask the
        // standby question (both fire rarely; the refresh guards itself).
        NotificationCenter.default.addObserver(
            self, selector: #selector(choicesAdoptedForStandby),
            name: .userChoicesAdopted, object: nil)
        standbyCancellable = PodcastProgressStore.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refreshStandbyFromTruth() }
            }
    }

    @objc private nonisolated func choicesAdoptedForStandby(_ note: Notification) {
        let adopted = note.userInfo?["keys"] as? [String] ?? []
        guard !adopted.isEmpty else { return }
        Task { @MainActor in
            guard adopted.contains(AppStorageKeys.lastPlayedItemId) else { return }
            await self.refreshStandbyFromTruth()
        }
    }

    #if DEBUG
    /// UI-test only (X14): install a PRESENTATION-ONLY session. A view model
    /// with item/chapters set but no AVPlayer. So the harness can open the full
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
    /// Whether opening a title starts from the beginning. An explicit
    /// restart always does; a finished title does when it is a deliberate play
    /// (autoplay). There is nothing to resume; a silent restore never does (it
    /// must not reset a finished book's position just by relaunching).
    nonisolated static func resolvesToRestart(explicitRestart: Bool, autoplay: Bool, isFinished: Bool) -> Bool {
        explicitRestart || (autoplay && isFinished)
    }

    /// A running FIXED-minutes sleep timer carries across an item change
    /// (auto-continue / manual open). It means "stop after X min of listening",
    /// independent of the title. A position-based mode (until chapter/track end)
    /// is bound to the current item and does not carry (it fires at that boundary).
    nonisolated static func carriedSleepRemaining(remaining: TimeInterval?, untilChapterEnd: Bool,
                                                  untilTrackEnd: Bool) -> TimeInterval? {
        guard let remaining, remaining > 0, !untilChapterEnd, !untilTrackEnd else { return nil }
        return remaining
    }

    /// 🔴 Every `open()` draws a GENERATION. After each await the call
    /// asks "am I still the current one?". A stale return cleans itself up
    /// (including a player it already built) instead of starting a second
    /// audio track. Without this, hammering play on a bad connection queued
    /// several calls in the network timeouts, and when the connection came
    /// back they ALL returned and started: overlapping playback. The
    /// `viewModel?.stop()` at the top cannot help there, because the racers
    /// are long past it.
    private var openGate = OpenGate()

    private var openGeneration: Int { openGate.current }

    /// `preservesContext`: true only where the start is NOT a fresh user
    /// intent: the auto-advance (it consumes the context), the collection
    /// start itself (it replaces it right after), and the session restore
    /// (an overnight album keeps its rest). Every other open is a user
    /// start and kills the old context; the orders are never touched.
    func open(item: LibraryItem, autoplay: Bool = true, restart: Bool = false,
              preservesContext: Bool = false) async {
        // Coalesce + draw a generation. The rule itself lives in `OpenGate`
        // (pure, tested): the same title already on its way answers nil.
        guard let generation = openGate.begin(itemId: item.id, restart: restart) else { return }
        defer { openGate.finish(generation) }
        if !preservesContext { PlaybackContext.shared.clear() }
        // Whatever you START playing leaves the global "Up Next" queue AND
        // the context. The currently playing item is never in either
        // ("launchpad, not playlist"). Covers audiobooks, podcasts and
        // music alike.
        PlayQueue.shared.remove(item.id)
        PlaybackContext.shared.remove(item.id)
        // A restart must reload (start at 0) even if it's the active item. Don't
        // take the "already open, just resume" shortcut.
        if !restart, activeItem?.id == item.id, viewModel != nil {
            if autoplay { await viewModel?.playWithServerCheck() }
            return
        }

        // Launch window: playing right after a cold start (session restore,
        // CarPlay) must not race the startup download scan. An empty id set
        // would make a downloaded book stream (or fail offline) instead of
        // playing its local files. No-op once the scan has merged.
        await DownloadManager.shared.ensureScanned()

        // Offline, a title that is not on the device cannot play. Say
        // so clearly, and BEFORE tearing anything down: the running session
        // (mini player) must survive the rejected tap, otherwise it looks like
        // a crash. The hint is rendered both in the player and as a banner in
        // the library (the player screen may not be mounted).
        if !NetworkMonitor.shared.isConnected,
           !DownloadManager.shared.isDownloaded(itemId: item.id) {
            loadError = String(localized: "Offline — this title is not downloaded.")
            return
        }

        // Capture a running fixed-minutes sleep timer BEFORE tearing down the
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

        // Determine the item's source (server vs. local files). The injected
        // `provider` is the default source, local items are routed away.
        let itemProvider = AppSession.shared.provider(for: item.id)
        // 🔴 DOWNLOADED means LOCAL FIRST. Not only when
        // the monitor says "offline". The degraded case (connected but
        // unusable, one bar of LTE) ran into the network timeouts although
        // the book AND its detail were on the device. This is no new code
        // path: the offline route becomes the DOWNLOAD route, and the
        // network state only decides whether a background reconciliation
        // follows.
        if DownloadManager.shared.isDownloaded(itemId: item.id),
           let cached = DownloadManager.shared.loadCachedDetail(forItemId: item.id) {
            // If the cached detail carries NO progress, the local
            // route would show a confident "00:00" until someone presses play.
            // And that invitation is the dangerous one. So ask the server
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
            // through the existing server-wins/echo-guard mechanics. It must
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
            // The playback start is where liveness is LEARNED. When the
            // source says the title is gone, that is recorded, otherwise the
            // dead item stands in the row again tomorrow. A mere transport
            // error records NOTHING: a dead spot is no verdict about the
            // title.
            if FreeCatalog.isGone(error), FreeCatalog.isCatalogId(item.id) {
                DeadCatalogItems.note(.dead, for: item.id)
                Logger.player.notice("FREECAT play \(item.id, privacy: .public) → weg")
            }
            // Server unreachable (e.g. offline on the go). If the book is
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

    /// The server answer with a deadline. Same 1.5 s as `playWithServerCheck`,
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

    /// The ONE start path for both routes (server detail and local detail).
    /// It was duplicated before, which is why the generation check would have
    /// had to be written twice. Every await is followed by the generation
    /// question: a stale return stops the player it built instead of leaving
    /// a second track running.
    private func start(detail: LibraryItemDetail, item: LibraryItem,
                       provider: any AudioProvider, offlineFallback: Bool,
                       autoplay: Bool, restart: Bool,
                       carriedSleep: TimeInterval?, generation: Int) async {
        let newViewModel = PlayerViewModel(provider: provider)
        // A finished title has nothing left to resume. Its saved
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
        // Choice family: opening an item IS the user event the standby
        // pointer travels on (a POINTER. Adoption never auto-plays).
        UserChoiceCloudSync.shared.noteScalar(key: lastItemKey, value: item.id)
        if let carriedSleep { newViewModel.startSleepTimer(minutes: carriedSleep / 60) }
        if autoplay {
            await newViewModel.playWithServerCheck()
            guard generation == openGeneration else { newViewModel.stop(); return }
            // THE point at which something is deliberately being listened to.
            // After the generation guard, so a start that was superseded does
            // not leave a mark. A source that keeps play statistics books here;
            // resolving a detail must never count, because the same resolution
            // also serves restore, refresh and the bounded server check.
            provider.notePlaybackStarted(itemId: item.id)
        }
    }

    /// Shuffle-play a set of playable items in random order. The whole
    /// music library, a playlist and an album all funnel here. Each supplies its
    /// own pool, the shared `MediaShuffle` sets the order. The first item starts
    /// now; the shuffled tail becomes the Up-Next context and plays through the
    /// existing cross-media auto-continue. An empty pool is a no-op.
    func shufflePlay(items: [LibraryItem], contextSource: String? = nil) async {
        await playInOrder(items: MediaShuffle.shuffled(items),
                          contextSource: contextSource ?? String(localized: "Shuffle"))
    }

    /// Play a set of items in the ORDER given. The shared tail of every
    /// "play this collection" surface: the first item starts now, the rest
    /// becomes the CONTEXT (never the queue: a collection start used to
    /// overwrite the hand-placed orders, and hours-old music won against
    /// the next episode). Shuffle is the same path with a shuffled order,
    /// so the two do not drift apart. An empty set is a no-op.
    func playInOrder(items: [LibraryItem], contextSource: String? = nil) async {
        guard let first = items.first else { return }
        await open(item: first, restart: true, preservesContext: true)
        PlaybackContext.shared.replace(ids: items.dropFirst().map(\.id),
                                       source: contextSource)
    }

    /// Auto-continue when an item plays to its end. Order:
    /// 1. The ORDERS ("Up Next"), CROSS-MEDIA and in order (a queued book,
    ///    episode or album plays next regardless of what just finished).
    /// 2. The CONTEXT of what was running (the rest of a collection start).
    /// 3. Both empty → type-specific fallback: podcasts binge on (next unheard
    ///    of the same show, then other subs); audiobooks continue the series
    ///    (only if the setting is on).
    private func attachBookEndHandler(to viewModel: PlayerViewModel) {
        viewModel.onBookFinished = { [weak self] finishedItemId in
            self?.advanceAfterFinish(finishedItemId: finishedItemId)
        }
        // The headphone title button's queue hop. SKIPPING IS NOT FINISHING:
        // the natural-end path above finalises the item as heard. A skip must
        // not, or every skipped song joins the freshly healed class anew. This
        // path shares the RESOLUTION (nextPlayableQueueItem) and nothing else;
        // the skipped item keeps its position and its unheard state.
        viewModel.onQueueSkipRequested = { [weak self] in
            guard let self, let next = self.nextPlayableQueueItem() else { return false }
            // A hop is a user start: the abandoned title's context dies
            // with it (open's default), the orders stay untouched.
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
        // The natural finish is a truth change the mounted Continue rows must
        // see WITHOUT a tab switch. One deliberate bump; every surface
        // recomputes through its existing scope/revision.
        PodcastProgressStore.shared.reload()

        PlaybackContext.shared.remove(finishedItemId)

        // The WHOLE cascade (orders, context, medium continuation) is the
        // ONE rule shared with the player's what-plays-next line. The jump
        // preserves the context: an advance is consumption, never a fresh
        // user intent.
        guard let next = resolveAdvance(after: finishedItemId) else { return }
        Task { await self.open(item: next, preservesContext: true) }
    }

    /// The ONE resolution of "what plays after this title". The advance
    /// OPENS its answer, the player line NAMES it; both call this, so the
    /// line can never promise something the end would not play.
    func resolveAdvance(after finishedId: String) -> LibraryItem? {
        let offline = !NetworkMonitor.shared.isConnected
        let queueIds = PlayQueue.shared.ids
        let contextIds = PlaybackContext.shared.ids
        // Stage 3 answers ITEMS (binge/series providers); the pure rule
        // speaks ids. The memo carries the resolved items across.
        var memo: [String: LibraryItem] = [:]
        let hit = PlaybackAdvance.resolveNext(
            after: finishedId,
            queueIds: queueIds,
            contextIds: contextIds,
            isPlayable: { !offline || DownloadManager.shared.isDownloaded(itemId: $0) },
            resolves: { AppSession.shared.playableItem(forId: $0) != nil },
            isPodcast: { $0.hasPrefix("rss:") || $0.hasPrefix("abspod:") },
            bingeNext: { id in
                guard let item = PodcastAutoContinue.next(after: id) else { return nil }
                memo[item.id] = item
                return item.id
            },
            seriesEnabled: UserDefaults.standard.bool(forKey: AppStorageKeys.autoPlayNextInSeries),
            seriesNext: { [weak self] id in
                guard let item = self?.nextInSeriesProvider?(id) else { return nil }
                memo[item.id] = item
                return item.id
            })
        guard let hit else {
            // The end has a REASON, and it is told apart: empty lists are
            // normal, entries that cannot start now are a finding.
            if !queueIds.isEmpty || !contextIds.isEmpty {
                Logger.library.notice("ADVANCE ends: orders=\(queueIds.count) context=\(contextIds.count), none playable (offline=\(offline))")
            }
            return nil
        }
        return memo[hit.id] ?? AppSession.shared.playableItem(forId: hit.id)
    }

    /// What plays after the ACTIVE title, for the player line. Same rule,
    /// no consumption.
    func upNextPreview() -> LibraryItem? {
        guard let active = activeItem else { return nil }
        return resolveAdvance(after: active.id)
    }

    /// X16c/X16d: mark the ACTIVE item as played AS IF it ended naturally.
    /// Playback stops (its progress is finalized as finished so the stop's final
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
    /// offline only downloaded items are candidates. An undownloaded handoff
    /// would be rejected mid-transition and read like a crash. Entries that no
    /// longer resolve to a library item are skipped.
    private func nextPlayableQueueItem() -> LibraryItem? {
        let offline = !NetworkMonitor.shared.isConnected
        let ids = PlayQueue.shared.ids
        guard let id = QueueContinuation.nextPlayable(
            ids: ids,
            isPlayable: { !offline || DownloadManager.shared.isDownloaded(itemId: $0) },
            // Resolution on demand: a catalogue id is self-describing, the
            // session cache is only a shortcut. A cache miss made the
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

    /// Restores the last played session on app start. Paused, so nothing plays
    /// by itself. The book appears right in the mini-player. Called from the
    /// library once the list is available (so we have the matching LibraryItem).
    func restoreLastSession(from entries: [LibraryEntry]) async {
        guard viewModel == nil, activeItem == nil else { return }
        guard let lastId = UserDefaults.standard.string(forKey: lastItemKey) else { return }
        // The mini player offers NOTHING that is
        // finished by its own knowledge. The continue rule, applied to the
        // standby. Judged by the NUMBERS (the one derived finished rule),
        // never only a flag; an empty standby is honest. The event gate is
        // untouched. This path still writes no position.
        if Self.standbyCountsAsFinished(ListeningStore.mark(lastId)) {
            UserDefaults.standard.removeObject(forKey: lastItemKey)
            Logger.player.notice("STANDBY cleared: \(lastId, privacy: .public) counts as finished")
            return
        }
        if let item = await resolveStandbyItem(lastId, entries: entries) {
            await open(item: item, autoplay: false, preservesContext: true)
        }
    }

    /// The standby pointer's resolution chain, shared by the start restore and
    /// the live refresh.
    private func resolveStandbyItem(_ lastId: String,
                                    entries: [LibraryEntry] = []) async -> LibraryItem? {
        // Podcast episodes resolve through the subscriptions' episode index,
        // which loads asynchronously at startup. Wait for it, otherwise a
        // cold-start restore of a podcast episode races the disk load.
        if lastId.hasPrefix("rss:") || lastId.hasPrefix("abspod:") {
            await PodcastSubscriptions.shared.ensureLoaded()
        }
        // The last played item can come from ANY source. Podcast episodes are
        // NOT in the audiobook list, only in the RSS provider.
        if let item = entries.first(where: { $0.id == lastId })?.item
            ?? AppSession.shared.libraryItem(forId: lastId) {
            return item
        }
        // Ids without a local index entry (sub: albums/songs)
        // still resolve over their provider. Restore from a light item built
        // out of the fetched detail. A successful open() re-writes lastItemKey,
        // healing the stale value for the next launch.
        if let detail = try? await AppSession.shared.provider(for: lastId)
            .fetchItemDetail(itemId: lastId) {
            return LibraryItem(id: detail.id, media: detail.media, addedAt: nil)
        }
        // The episode fell out of its feed (rotating news
        // feeds). Restore the SHOW context with its newest episode instead of
        // silently showing no mini player at all.
        if let showId = Self.showId(forEpisodeId: lastId),
           let show = PodcastSubscriptions.shared.shows.first(where: { $0.id == showId }) {
            let items = AppSession.shared.rssProvider.showItems(for: show)
            return items.max(by: { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) })
        }
        return nil
    }

    /// Under the MIRROR rule two devices at rest show the SAME piece
    /// within one reconcile beat. A fresher foreign pointer swaps the paused
    /// mini player (the choice family already decided by event time; the
    /// mirror follows), a held pointer that turned finished clears it. Only a
    /// PLAYING session is untouchable (it claims, and its own open-note wins
    /// the merge anyway). Never auto-plays. The finished-clear stays silent
    /// mechanics (each device derives it; the adoption guard is the twin).
    func refreshStandbyFromTruth() async {
        if let vm = viewModel, vm.isPlaying { return }
        let stored = UserDefaults.standard.string(forKey: lastItemKey)
        if let held = activeItem?.id {
            if stored == held {
                if Self.standbyCountsAsFinished(ListeningStore.mark(held)) {
                    viewModel?.stop(); viewModel = nil; activeItem = nil
                    UserDefaults.standard.removeObject(forKey: lastItemKey)
                    Logger.player.notice("STANDBY cleared live: \(held, privacy: .public) counts as finished")
                }
                return
            }
            if stored == nil {
                // Foreign tombstone adopted. "nothing on standby" travels.
                viewModel?.stop(); viewModel = nil; activeItem = nil
                Logger.player.notice("STANDBY cleared live: foreign tombstone")
                return
            }
        }
        guard let stored, stored != activeItem?.id else { return }
        guard !Self.standbyCountsAsFinished(ListeningStore.mark(stored)) else { return }
        if let item = await resolveStandbyItem(stored) {
            Logger.player.notice("STANDBY swapped live: \(stored, privacy: .public)")
            await open(item: item, autoplay: false)
        }
    }

    /// The standby question, pure: finished by local knowledge? Duration
    /// unknown = not finished (a standby is only cleared on evidence).
    nonisolated static func standbyCountsAsFinished(_ mark: ListeningStore.Mark?) -> Bool {
        guard let mark, let duration = mark.duration else { return false }
        return SyncRules.isFinished(currentTime: mark.position, duration: duration)
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
        // Choice family: closing is a deliberate "nothing on standby". The
        // tombstone travels. The derived finished-clear in restoreLastSession
        // deliberately does NOT note: it is mechanics, each device derives it
        // from the synced numbers itself (adoption carries the same guard).
        UserChoiceCloudSync.shared.noteScalar(key: lastItemKey, value: nil)
    }
}
