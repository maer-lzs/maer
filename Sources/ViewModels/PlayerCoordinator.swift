// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Whether a model plays without a mini player for it, pure: it sounds
/// while it is not the session, or while the session names no title (the
/// bar draws only with both).
nonisolated enum SoundWithoutBar {
    static func strays(isPlaying: Bool, isSession: Bool, hasTitle: Bool) -> Bool {
        isPlaying && !(isSession && hasTitle)
    }
}

/// A model the coordinator watches without keeping it alive.
struct WeakPlayerModel {
    weak var model: PlayerViewModel?
}

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
            // Another title, or none, takes the old one's stopping error with
            // it. FIRST, before the new model's notices arrive: the sink
            // below delivers the notice standing at the attach at once, and a
            // stopping error of the new title's load must outlive the change.
            if viewModel !== oldValue { notices.titleChanged() }
            // Every notice the model says goes into the one channel, which
            // keeps the pill, its timer and the log; every start of playback
            // lets a stopping error fall there. The value present at the
            // attach counts too: the model is attached after its load, and a
            // notice of the load (position adopted, title not playable)
            // stands there already.
            hintCancellable = viewModel?.$sourceHint.compactMap { $0 }.sink { [weak self] notice in
                self?.notices.show(notice, title: self?.viewModel?.item?.media.metadata?.title)
            }
            startsCancellable = viewModel?.playbackStarts.sink { [weak self] in self?.notices.played() }
            // A wait on the stream goes to the channel as a state; the
            // channel times the hint and lets it go when the wait ends.
            waitCancellable = viewModel?.$waitsOnTheStream.removeDuplicates().sink { [weak self] waits in
                self?.notices.streamWaits(waits, title: self?.viewModel?.item?.media.metadata?.title)
            }
            if viewModel == nil { isPlaying = false; nowPlayingLine = nil }
            listenForSoundWithoutBar()
        }
    }

    /// The one channel of playback notices (pill above the mini bar, pill in
    /// the full player, the log).
    let notices: PlaybackNotices

    /// The running ICY line of the active item, mirrored for list surfaces
    /// (radio tiles/cards) that must not each observe the nested view model.
    @Published private(set) var nowPlayingLine: String?
    @Published private(set) var activeItem: LibraryItem? {
        didSet { listenForSoundWithoutBar() }
    }
    /// The models this run built, newest last, each with its play state
    /// watched: a model that sounds while the bar shows no session for it
    /// is a line (`SoundWithoutBar`). Seen on a device: music played on
    /// after a title change and the mini player stayed gone.
    private var builtModels: [(model: WeakPlayerModel, watch: AnyCancellable)] = []
    private var soundWithoutBarSaid: ObjectIdentifier?
    /// The songs this session played before the running one, newest last:
    /// the title button's way back. In memory only, never saved, never shown;
    /// the queue itself keeps no played titles.
    private(set) var songsBefore: [LibraryItem] = []
    static let songsBeforeLimit = 50
    /// Set while the way back opens its song, so that song's leaving title
    /// is not remembered as the one before it.
    private var goingBack = false
    /// The orders, reached in one place.
    private var orders: PlayQueue { PlayQueue.shared }
    @Published private(set) var isLoading = false
    /// Set while the end of a title opens the next one, across the titles
    /// it skips (`advance(to:)`).
    @Published private(set) var isAdvancing = false
    /// A title is on its way: what shows a session holds the one it showed.
    var isChangingTitle: Bool { isLoading || isAdvancing }
    /// The titles in a row the advance skips when they do not start.
    static let unstartedSkipLimit = 3
    @Published private(set) var isPlaying = false
    @Published var loadError: String?

    private var isPlayingCancellable: AnyCancellable?
    private var icyCancellable: AnyCancellable?
    private var hintCancellable: AnyCancellable?
    private var startsCancellable: AnyCancellable?
    private var waitCancellable: AnyCancellable?
    private var standbyCancellable: AnyCancellable?
    /// One progress refresh per foreign-claimed library item, then one
    /// per minute at most (see `ClaimRefreshThrottle`).
    private var claimRefresh = ClaimRefreshThrottle()

    let provider: any AudioProvider

    /// Set by the library screen (owner of the series data): returns the
    /// next unfinished book of the same series. Basis for the auto-play-
    /// next setting when a book finishes.
    var nextInSeriesProvider: ((String) -> LibraryItem?)?

    /// Set by the library screen. Called when an item is (re)started from
    /// the beginning so the library can clear its local 'finished' flag.
    var onItemRestarted: ((String) -> Void)?

    /// Remembers the last played item id across app restarts so the book is
    /// ready in the mini-player right away on the next launch.
    private let lastItemKey = AppStorageKeys.lastPlayedItemId
    /// The pointer as it stood before the running open attempt, kept only
    /// until that attempt is decided. `Optional<Optional<String>>` would be
    /// the honest type for "nothing pending" against "there was no
    /// pointer"; the empty string is not a pointer, so nil for either is
    /// enough and the witness drives both.
    private var pointerBeforeOpen: String??

    /// `notices`: a witness hands in a channel of its own (own log file).
    init(provider: any AudioProvider, notices: PlaybackNotices? = nil) {
        self.provider = provider
        if let notices {
            self.notices = notices
        } else {
            // The app's channel follows the account like the families: built
            // with the coordinator at launch, enrolled, and handed to the
            // account signed in now.
            let own = AccessFollowers.enrolled(PlaybackNotices(shelf: MaerDatabase.restingShelf))
            own.followAtStart()
            self.notices = own
        }
        // A load failure that stopped playback is built anew once the
        // network carries again, without starting: the next play then plays.
        NetworkMonitor.shared.onChange { [weak self] path in
            self?.viewModel?.rebuildAfterPathChange(path)
        }
        // Takeover: a foreign claim on the item THIS device is
        // playing means another device took over on explicit play. This
        // side stands down by itself and pushes its final state (pause()
        // force-syncs). No remote control, no locks; the claim age in the
        // log line is the latency witness for the device pair.
        let sync = PlaybackClaimSync.shared
        sync.onForeignClaim = { [weak self] claim in
            guard let self else { return }
            let nowMs = Date().timeIntervalSince1970 * 1000
            let age = Int((nowMs - claim.t) / 1000)
            let held = self.viewModel?.isPlaying == true ? self.activeItem?.id : nil
            // Second witness: the own fresh claim. Written only while
            // playing, so it says "this device plays X" even when the
            // coordinator's view of itself does not.
            let playing = PlaybackClaimRules.playingItem(
                held: held, ownClaim: sync.lastOwnClaim,
                ownDeviceId: SyncHistoryStore.deviceId, nowMs: nowMs)
            // The start of THIS playback, from whoever plays: the writer
            // of the own claim first, the held view model as fallback.
            let ownStart = ((sync.lastWriter as? PlayerViewModel) ?? self.viewModel)?
                .playbackStartedAtMs ?? 0
            let pause = PlaybackClaimRules.shouldPause(
                claim: claim, ownDeviceId: SyncHistoryStore.deviceId,
                playingItemId: playing, nowMs: nowMs, ownStartedAtMs: ownStart)
            // Every foreign claim leaves a line, above all the ones that
            // change nothing: a takeover that never stops this device is
            // invisible otherwise, and the age is the latency witness.
            let verdict = pause ? "takeover"
                : claim.released ? "released"
                : playing == nil ? "not playing"
                : claim.playTime <= ownStart ? "older play"
                : "stale"
            // The three inputs of `playing`, spelled out: which view model
            // this coordinator holds, whether it says it plays, and which
            // item is active. A takeover that never stops this device is
            // decided in one of these three, and the verdict alone cannot
            // say which.
            let heldVM = self.viewModel.map { PlaybackClaimSync.instanceTag($0) } ?? "nil"
            // Item ids are listening behaviour: hashed in the persistent
            // log, still comparable between the lines of one archive.
            Logger.player.notice("CLAIM seen item=\(claim.itemId, privacy: .private(mask: .hash)) age=\(age)s playing=\(playing ?? "-", privacy: .private(mask: .hash)) verdict=\(verdict, privacy: .public) device=\(claim.deviceId.prefix(8), privacy: .public) vm=\(heldVM, privacy: .public) vmPlaying=\(self.viewModel?.isPlaying == true) active=\(self.activeItem?.id ?? "nil", privacy: .private(mask: .hash)) coord=\(PlaybackClaimSync.instanceTag(self), privacy: .public)")
            // A foreign claim on a LIBRARY item (a book, a server podcast
            // episode): its stand lives on the server, and the listening
            // rows see it only after the progress refresh the scene runs
            // when it becomes active. The claim runs that refresh now, one
            // per claimed item and then one per minute at most, so the
            // heartbeat never becomes a server round trip per beat; a
            // second pass fifteen seconds later catches the other device's
            // push when it landed after the first; the revision bump
            // afterwards lets every row follow.
            if !claim.released, claim.deviceId != SyncHistoryStore.deviceId,
               let library = ClaimRefreshThrottle.library(of: claim.itemId) {
                let pass = self.claimRefresh.admittedPass(itemId: claim.itemId, nowMs: nowMs)
                Logger.player.notice("CLAIM refresh library=\(String(describing: library), privacy: .public) admitted=\(pass != nil) pass=\(pass ?? 0)")
                if pass != nil {
                    Task { @MainActor in
                        switch library {
                        case .books: await AppSession.shared.libraryViewModel.refreshProgress()
                        case .serverPodcasts: await ABSPodcastProvider.shared.refreshProgress()
                        }
                        ListeningRevision.shared.bump("claim refresh")
                    }
                }
            }
            // No catch-up once playing: a jump while listening is the
            // disturbance, a few seconds heard twice are not. The start
            // takes the freshest stand known at that moment, and that is it.
            guard pause else { return }
            // The pause goes to whoever wrote the claim: that is the view
            // model that plays. The held one is the fallback, never the
            // only target.
            let writer = sync.lastWriter as? PlayerViewModel
            guard let target = writer ?? self.viewModel else { return }
            Logger.player.notice("CLAIM pause via=\(writer != nil ? "writer" : "held", privacy: .public) vm=\(PlaybackClaimSync.instanceTag(target), privacy: .public)")
            target.pause(caller: "takeover")
        }
        // The standby follows the fresh truth while the app runs. A
        // pointer adoption and every deliberate progress change re-ask the
        // standby question (both fire rarely; the refresh guards itself).
        NotificationCenter.default.addObserver(
            self, selector: #selector(choicesAdoptedForStandby),
            name: .userChoicesAdopted, object: nil)
        // The listening revision carries every store event (the podcast
        // store's bumps included), so the standby follows all of them.
        standbyCancellable = ListeningRevision.shared.objectWillChange
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
    /// UI-test only: install a PRESENTATION-ONLY session. A view model
    /// with item/chapters set but no AVPlayer. So the harness can open the full
    /// player and screenshot its title/chapter layout without a real audio
    /// stream. Must live here because `viewModel`/`activeItem` are `private(set)`.
    /// `openedHere` makes the seeded session count as opened on this
    /// device, like a gesture would. The UI harness needs that: the standby
    /// refresh reads a held title without an own opening and without a
    /// pointer as a foreign tombstone and stops it (measured 17.09.2026:
    /// "STANDBY cleared live: foreign tombstone" a second after the seed).
    /// The standby witnesses leave it false, because they build exactly that
    /// foreign shape on purpose.
    func _seedActivePlayerForUITest(item: LibraryItem, detail: LibraryItemDetail,
                                    chapters: [ABSChapter], currentChapterIndex: Int,
                                    isFallback: Bool, openedHere: Bool = false,
                                    noticeBeforeAttach: PlaybackNotice? = nil) {
        let vm = PlayerViewModel(provider: provider)
        vm.item = detail
        vm.chapters = chapters
        vm.currentChapter = chapters.indices.contains(currentChapterIndex) ? chapters[currentChapterIndex] : nil
        vm.chaptersAreFallback = isFallback
        vm.duration = detail.media.duration ?? 0
        vm.currentTime = vm.currentChapter?.start ?? 0
        // As in `start(detail:)`: a notice of the load is said before the
        // model is attached.
        if let noticeBeforeAttach { vm.showSourceHint(noticeBeforeAttach) }
        viewModel = vm
        activeItem = item
        if openedHere { ownOpenedAtMs = Date().timeIntervalSince1970 * 1000 }
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

    /// Whether a title counts as finished when it opens. The server's word
    /// wins where it has one. Where it has none (a Jellyfin or Navidrome
    /// song, a catalogue item), the LOCAL mark decides, the same witness the
    /// player takes its start position from (the backup, else the flushed
    /// one). Asking only the server let a heard song open at its end
    /// position and end at once: `at=272`, then `item ended at=272`.
    nonisolated static func isFinishedAtOpen(serverFinished: Bool?, localMark: [Double]?,
                                             duration: Double) -> Bool {
        if let serverFinished { return serverFinished }
        guard let localMark else { return false }
        // The TRUE end: a title that only counts as played by the person's
        // tail resumes where it stood, so the last minute can be heard.
        return ProgressMark.reachedEnd(stored: localMark, currentDuration: duration)
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
    /// Where an open comes from. Only a GESTURE (the person tapped:
    /// library, row, queue, CarPlay, widget, deep link) is a user event
    /// the standby pointer travels on; the mirror's swap and the restore
    /// at start are mechanics and never note (mechanics never stamp "now",
    /// or a tombstone from the other device loses).
    enum OpenOrigin: Equatable, Sendable {
        case gesture
        case restore
        case mirror

        /// Whether a failed open is said to the person. Only a gesture is:
        /// the mirror and the restore run without anyone asking, and a
        /// sentence then answers a question nobody put. Measured on an iPad
        /// that only stood ready for the other device's episode and showed
        /// an error for it.
        nonisolated var saysFailure: Bool {
            switch self {
            case .gesture: return true
            case .restore, .mirror: return false
            }
        }
    }

    /// The one exit of a failed open: always a line, a sentence only after
    /// a gesture. The sentence is the channel's pill, like every other
    /// notice; `loadError` carries it for the full player's screen as long.
    private func openFailed(_ sentence: String, reason: String, item: LibraryItem, origin: OpenOrigin,
                            cause: NoticeCause) {
        Logger.player.notice("OPEN failed origin=\(String(describing: origin), privacy: .public) reason=\(reason, privacy: .public) item=\(item.id, privacy: .private(mask: .hash))")
        guard origin.saysFailure else { return }
        sayOpenFailure(sentence, cause: cause, title: item.title)
    }

    /// A tap that opens nothing says why, in the channel; the full player's
    /// screen shows the same sentence for the pill's time.
    func sayOpenFailure(_ sentence: String, cause: NoticeCause, title: String?) {
        notices.show(.openFailed(sentence, cause), title: title)
        loadError = sentence
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.loadError == sentence { self?.loadError = nil }
        }
    }

    /// Opens an id through the one resolver (the seam); a view need not
    /// hold the session for it. Nothing plays when nothing resolves, and a
    /// line says so: a tap that starts nothing is otherwise without a trace.
    func open(itemId: String) async {
        guard let item = await AppSession.shared.resolveItem(forId: itemId) else {
            Logger.player.notice("OPEN unresolved item=\(itemId, privacy: .private(mask: .hash)), nothing plays")
            return
        }
        await open(item: item)
    }

    func open(item: LibraryItem, autoplay: Bool = true, restart: Bool = false,
              preservesContext: Bool = false, origin: OpenOrigin = .gesture) async {
        // Coalesce + draw a generation. The rule itself lives in `OpenGate`
        // (pure, tested): the same title already on its way answers nil.
        guard let generation = openGate.begin(itemId: item.id, restart: restart) else { return }
        defer { openGate.finish(generation) }
        // A restart must reload (start at 0) even if it's the active item. Don't
        // take the "already open, just resume" shortcut.
        if !restart, activeItem?.id == item.id, viewModel != nil {
            takeOver(item.id, preservesContext: preservesContext)
            if autoplay { await viewModel?.playWithServerCheck() }
            return
        }

        // Launch window: playing right after a cold start (session restore,
        // CarPlay) must not race the startup download scan. An empty id set
        // would make a downloaded book stream (or fail offline) instead of
        // playing its local files. No-op once the scan has merged.
        let downloads = DownloadManager.shared
        await downloads.ensureScanned()

        // Offline, a title that is not on the device cannot play. Say
        // so clearly, and BEFORE tearing anything down: the running session
        // (mini player) must survive the rejected tap, otherwise it looks like
        // a crash. The hint is rendered both in the player and as a banner in
        // the library (the player screen may not be mounted).
        // The one question before the network (`Reachability`): in the app
        // the path monitor's answer, and a witness can ask the offline side.
        let connected = await Reachability.isConnected()
        if MediaAvailability.offlineUnavailable(
            isConnected: connected,
            isDownloaded: downloads.isDownloaded(itemId: item.id)) {
            openFailed(String(localized: "Offline. This title is not downloaded."),
                       reason: "offlineNotDownloaded", item: item, origin: origin, cause: .network)
            return
        }
        // The lists are taken over only where the open stands (`start`): a
        // tap turned away here, a detail that cannot be fetched or an open
        // overtaken by a newer one leaves the context and Up Next as they were.

        // Capture a running fixed-minutes sleep timer BEFORE tearing down the
        // old session, so it can continue on the next title.
        let carriedSleep = Self.carriedSleepRemaining(
            remaining: viewModel?.sleepTimerRemaining,
            untilChapterEnd: viewModel?.sleepUntilChapterEnd ?? false,
            untilTrackEnd: viewModel?.sleepUntilTrackEnd ?? false)

        viewModel?.stop()
        viewModel = nil
        beginOwnSession(item, origin: origin)
        loadError = nil
        isLoading = true
        // Only the CURRENT open ends the loading. A stale one returning
        // while a newer one still loads left the player with no session,
        // no load and no error, which is "nothing", and the player closes
        // on nothing.
        defer { if openGate.isCurrent(generation) { isLoading = false } }

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
        if downloads.isDownloaded(itemId: item.id),
           let cached = downloads.loadCachedDetail(forItemId: item.id) {
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
                await downloads.updateCachedProgress(
                    itemId: item.id, progress: fresh.userMediaProgress ?? MediaProgress(
                        currentTime: 0, duration: nil, progress: nil,
                        isFinished: nil, lastUpdate: nil))
            }
            guard generation == openGeneration else { return }
            await start(detail: detail, item: item, provider: itemProvider,
                        offlineFallback: true, autoplay: autoplay, restart: restart,
                        carriedSleep: carriedSleep, preservesContext: preservesContext, generation: generation)
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
                        carriedSleep: carriedSleep, preservesContext: preservesContext, generation: generation)
        } catch {
            // The playback start is where liveness is LEARNED, when the
            // detail is fetched fresh; a catalogue detail answered from the
            // session store throws nothing and learns nothing (a failed
            // playback forgets that answer, so the next start asks again).
            // When the source says the title is gone, that is recorded,
            // otherwise the dead item stands in the row again tomorrow. A
            // mere transport error records NOTHING: a dead spot is no
            // verdict about the title.
            if FreeCatalog.isGone(error), FreeCatalog.isCatalogId(item.id) {
                DeadCatalogItems.note(.dead, for: item.id)
                Logger.player.notice("FREECAT play \(item.id, privacy: .public) → weg")
            }
            // Server unreachable (e.g. offline on the go). If the book is
            // downloaded, continue with the book details saved at download time
            // instead of failing entirely. Without this even a long-downloaded
            // book would need a working server connection just to open.
            guard generation == openGeneration else { return }
            if let cached = downloads.loadCachedDetail(forItemId: item.id) {
                await start(detail: cached, item: item, provider: itemProvider,
                            offlineFallback: true, autoplay: autoplay, restart: restart,
                            carriedSleep: carriedSleep, preservesContext: preservesContext, generation: generation)
            } else {
                openFailed(ErrorSentence.of(error),
                           reason: FailureReason.of(error), item: item, origin: origin,
                           cause: NoticeCause.of(error, online: await Reachability.isConnected()))
                activeItem = nil
                // The item never opened, so the pointer that went out at
                // the gesture is withdrawn with it. `activeItem` was
                // already cleared here; the pointer was not, and it is the
                // half that reached the other devices.
                withdrawOwnSession()
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
                       carriedSleep: TimeInterval?, preservesContext: Bool, generation: Int) async {
        let newViewModel = PlayerViewModel(provider: provider)
        // A finished title has nothing left to resume. Its saved
        // position is the end. A deliberate play (autoplay) therefore restarts
        // from the beginning via the existing restart mechanic; a silent
        // restore (autoplay == false) leaves it untouched.
        let effectiveRestart = Self.resolvesToRestart(
            explicitRestart: restart, autoplay: autoplay,
            isFinished: Self.isFinishedAtOpen(
                serverFinished: detail.userMediaProgress?.isFinished,
                localMark: ListeningStore.backup(item.id) ?? ListeningStore.flushed(item.id),
                duration: detail.media.duration ?? 0))
        await newViewModel.load(item: detail, isOfflineFallback: offlineFallback,
                                restart: effectiveRestart)
        guard generation == openGeneration else { newViewModel.stop(); return }
        // The one point where the open stands: only here are the lists
        // taken over (`takeOver`), never before a refusal or a failed fetch.
        takeOver(item.id, preservesContext: preservesContext)
        if effectiveRestart { onItemRestarted?(item.id) }   // clear the local finished flag
        attachBookEndHandler(to: newViewModel)
        viewModel = newViewModel
        watchForSoundWithoutBar(newViewModel)
        // The open stands. What the pointer said before it is no longer
        // needed, and the next gesture starts again from a title that
        // really played.
        confirmOwnSession()
        // The pointer and its note went out at `beginOwnSession`, for a
        // gesture only; nothing is re-noted here.
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
        // The title button's hop to the next title. SKIPPING IS NOT FINISHING:
        // the natural-end path above finalises the item as heard. A skip must
        // not, or every skipped song joins the freshly healed class anew. This
        // path shares the first two stages of the end's resolution (the
        // orders, then the context) and nothing else; the skipped item keeps
        // its position and its unheard state.
        viewModel.onQueueSkipRequested = { [weak self] in
            guard let self, let next = self.nextPlayableTitle() else { return false }
            // A hop into the orders is a user start: the abandoned title's
            // context dies with it. A hop along the context keeps it, so a
            // shuffled list or an album played song by song goes on.
            Task { await self.open(item: next.item, preservesContext: next.fromContext) }
            return true
        }
        // The way back, as in the system's music app: the song this session
        // played before starts from its beginning, and the album or list it
        // belonged to stays as it is. The song it left waits at the front of
        // the orders, so "next" brings it back.
        viewModel.hasSongBefore = { [weak self] in !(self?.songsBefore.isEmpty ?? true) }
        viewModel.onSongBeforeRequested = { [weak self] in
            guard let self, let previous = self.songsBefore.popLast() else { return false }
            let left = self.activeItem?.id
            Task {
                self.goingBack = true
                defer { self.goingBack = false }
                await self.open(item: previous, restart: true, preservesContext: true)
                self.orders.returnForNext(leaving: left)
            }
            return true
        }
    }

    /// What starting a title does to the lists: a start that brings no
    /// context of its own ends the old one, and whatever you START playing
    /// leaves both lists (audiobooks, podcasts and music alike). Called where
    /// the open stands (`start`, and the shortcut for the title already
    /// open), never before a refusal, a failed fetch or an overtaken open.
    private func takeOver(_ id: String, preservesContext: Bool) {
        if !preservesContext { PlaybackContext.shared.clear() }
        leaveBothLists(id)
    }

    /// What starts or finishes leaves BOTH lists, the orders and the
    /// context: the running title is never in either ("launchpad, not
    /// playlist"), and what already ran is never offered again. The start
    /// and the end call this one door, so the invariant is written once.
    private func leaveBothLists(_ id: String) {
        orders.remove(id)
        PlaybackContext.shared.remove(id)
    }

    /// The natural-end advance, shared by the real end-of-item handler and the
    /// manual "mark as played". The finished item leaves the queue, then
    /// the next playable item starts.
    private func advanceAfterFinish(finishedItemId: String) {
        // Invariant "heard = flies out": the finished item leaves both lists.
        // It was already removed when it started, but a restored-session item
        // (never opened via `open`) would otherwise linger.
        leaveBothLists(finishedItemId)
        // The natural finish is a truth change the mounted Continue rows must
        // see WITHOUT a tab switch. One deliberate bump; every surface
        // recomputes through its existing scope/revision.
        PodcastProgressStore.shared.reload()

        // The WHOLE cascade (orders, context, medium continuation) is the
        // ONE rule shared with the player's what-plays-next line. The jump
        // preserves the context: an advance is consumption, never a fresh
        // user intent.
        guard let next = resolveAdvance(after: finishedItemId) else { return }
        Task { await self.advance(to: next) }
    }

    /// Watches a model this run attached; the last four are kept, an older
    /// one was stopped long before.
    private func watchForSoundWithoutBar(_ model: PlayerViewModel) {
        let watch = model.$isPlaying.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.listenForSoundWithoutBar() } }
        builtModels.append((WeakPlayerModel(model: model), watch))
        if builtModels.count > 4 { builtModels.removeFirst() }
    }

    /// One line per model that sounds while the bar shows no session for it.
    private func listenForSoundWithoutBar() {
        let stray = builtModels.lazy.compactMap(\.model.model).first {
            SoundWithoutBar.strays(isPlaying: $0.isPlaying, isSession: $0 === self.viewModel,
                                   hasTitle: self.activeItem != nil)
        }
        guard let stray else { soundWithoutBarSaid = nil; return }
        guard soundWithoutBarSaid != ObjectIdentifier(stray) else { return }
        soundWithoutBarSaid = ObjectIdentifier(stray)
        Logger.player.error("PLAYER sound without bar vm=\(PlaybackClaimSync.instanceTag(stray), privacy: .public) session=\(stray === self.viewModel ? "this" : (self.viewModel.map { PlaybackClaimSync.instanceTag($0) } ?? "none"), privacy: .public) title=\(self.activeItem == nil ? "none" : "set", privacy: .public) loading=\(self.isChangingTitle)")
    }

    /// Opens what the end of a title resolved. A title that does not start
    /// ends nothing: its open said why, it leaves both lists and the
    /// advance goes on to the one after it, at most `unstartedSkipLimit`
    /// in a row. Measured: one dead catalogue title ended a shuffle with
    /// seven titles left, and the mini player with it.
    private func advance(to first: LibraryItem) async {
        isAdvancing = true
        defer { isAdvancing = false }
        await Self.advance(from: first, limit: Self.unstartedSkipLimit,
                           open: { item in
                               await self.open(item: item, preservesContext: true)
                               // Started, or a newer open owns the session.
                               return self.activeItem != nil || self.viewModel != nil || self.isLoading
                           },
                           leave: { self.leaveBothLists($0) },
                           after: { self.resolveAdvance(after: $0) })
    }

    /// The advance's walk, apart from the session so a witness can drive
    /// it: open, and on a title that did not start, leave it and open the
    /// one after it until one starts, none follows or `limit` titles in a
    /// row did not start. Answers the ids that did not start.
    @discardableResult
    static func advance(from first: LibraryItem, limit: Int,
                        open: (LibraryItem) async -> Bool,
                        leave: (String) -> Void,
                        after: (String) -> LibraryItem?) async -> [String] {
        var next = first
        var unstarted: [String] = []
        while !(await open(next)) {
            unstarted.append(next.id)
            leave(next.id)
            guard unstarted.count < limit else {
                Logger.player.notice("ADVANCE stops: \(unstarted.count) titles in a row did not start")
                return unstarted
            }
            guard let following = after(next.id) else { return unstarted }
            Logger.player.notice("ADVANCE skips unstarted item=\(next.id, privacy: .private(mask: .hash)) next=\(following.id, privacy: .private(mask: .hash))")
            next = following
        }
        return unstarted
    }

    /// The ONE resolution of "what plays after this title". The advance
    /// OPENS its answer, the player line NAMES it; both call this, so the
    /// line can never promise something the end would not play.
    func resolveAdvance(after finishedId: String) -> LibraryItem? {
        let inputs = advanceInputs()
        let queueIds = inputs.queueIds
        let contextIds = inputs.contextIds
        let offline = inputs.offline
        // Stage 3 answers ITEMS (binge/series providers); the pure rule
        // speaks ids. The memo carries the resolved items across.
        var memo: [String: LibraryItem] = [:]
        let hit = PlaybackAdvance.resolveNext(
            after: finishedId,
            queueIds: queueIds,
            contextIds: contextIds,
            isPlayable: inputs.isPlayable,
            resolves: inputs.resolves,
            isPodcast: ItemNamespace.isPodcastEpisode,
            bingeNext: { id in
                guard let item = PodcastAutoContinue.next(after: id) else { return nil }
                memo[item.id] = item
                return item.id
            },
            seriesEnabled: AppStorageKeys.autoPlayNextInSeriesValue,
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
        return memo[hit.id] ?? inputs.item(hit.id)
    }

    /// What both resolutions read: the orders, the context, and the questions
    /// every candidate answers. One place, so the skip and the end of a
    /// title cannot read different lists.
    private func advanceInputs() -> (queueIds: [String], contextIds: [String], offline: Bool,
                                     isPlayable: (String) -> Bool, resolves: (String) -> Bool,
                                     item: (String) -> LibraryItem?) {
        let offline = !NetworkMonitor.shared.isConnected
        let session = AppSession.shared
        let downloads = DownloadManager.shared
        return (orders.ids, PlaybackContext.shared.ids, offline,
                { MediaAvailability.canPlayNow(isConnected: !offline,
                                               isDownloaded: downloads.isDownloaded(itemId: $0)) },
                // Resolution on demand: a catalogue id and a music server song
                // are self-describing (`SyncCarried.resolvesOnDemand`), the
                // session cache is only a shortcut; `open` fetches the detail.
                { session.playableItem(forId: $0) != nil },
                { session.playableItem(forId: $0) })
    }

    /// What plays after the ACTIVE title, for the player line. Same rule,
    /// no consumption.
    func upNextPreview() -> LibraryItem? {
        guard let active = activeItem else { return nil }
        return resolveAdvance(after: active.id)
    }

    /// Mark the ACTIVE item as played AS IF it ended naturally.
    /// Playback stops (its progress is finalized as finished so the stop's final
    /// sync writes "finished", not the current position) and the auto-continue
    /// logic advances to the next item (or the session just ends if there is
    /// none). A NON-active item is a no-op here: the callers already drop it from
    /// the queue themselves, and advancing would interrupt whatever is playing.
    ///
    /// When something follows, the stopped session stays on screen until the
    /// next open replaces it, as at a natural end: the full player closes on
    /// an empty session, and marking a title from inside it must hand over
    /// to the next one, not close.
    func markPlayedAndAdvance(itemId: String) {
        guard activeItem?.id == itemId, let vm = viewModel else { return }
        vm.finalizeAsFinished()
        vm.stop()
        // Out of both lists FIRST, so the question below never answers the
        // finished title itself.
        leaveBothLists(itemId)
        if resolveAdvance(after: itemId) == nil {
            viewModel = nil
            activeItem = nil
        }
        advanceAfterFinish(finishedItemId: itemId)
    }

    /// The title a skip goes to: the first entry of the orders that can start
    /// now, else the first of the context, by the same rule as the end of a
    /// title (`PlaybackAdvance.next`). The context is where a shuffled list
    /// or an album started song by song keeps its rest; reading only the
    /// orders made "next song" do nothing there. Offline only downloaded
    /// entries are candidates (an undownloaded handoff would be rejected
    /// mid-transition and read like a crash); entries that do not resolve
    /// are skipped.
    private func nextPlayableTitle() -> (item: LibraryItem, fromContext: Bool)? {
        let inputs = advanceInputs()
        guard let hit = PlaybackAdvance.next(queueIds: inputs.queueIds, contextIds: inputs.contextIds,
                                             isPlayable: inputs.isPlayable, resolves: inputs.resolves),
              let item = inputs.item(hit.id) else {
            // The end has a REASON, and it is told apart: empty lists are
            // normal, entries that cannot start now are a finding.
            if !inputs.queueIds.isEmpty || !inputs.contextIds.isEmpty {
                Logger.library.notice("SKIP ends: orders=\(inputs.queueIds.count) context=\(inputs.contextIds.count), none playable (offline=\(inputs.offline))")
            }
            return nil
        }
        return (item, hit.origin == .context)
    }

    /// Restores the last played session on app start. Paused, so nothing plays
    /// by itself. The book appears right in the mini-player. Called from the
    /// library once the list is available (so we have the matching LibraryItem).
    func restoreLastSession(from entries: [LibraryEntry]) async {
        guard viewModel == nil, activeItem == nil else { return }
        guard let lastId = AppStorageKeys.lastPlayedItemIdValue else { return }
        // The mini player offers NOTHING that is
        // finished by its own knowledge. The continue rule, applied to the
        // standby. Judged by the NUMBERS (the one derived finished rule),
        // never only a flag; an empty standby is honest. The event gate is
        // untouched. This path still writes no position.
        if Self.standbyCountsAsFinished(ListeningStore.mark(lastId)) {
            AppStorageKeys.lastPlayedItemIdValue = nil
            Logger.player.notice("STANDBY cleared: \(lastId, privacy: .public) counts as finished")
            return
        }
        if let item = await resolveStandbyItem(lastId, entries: entries, allowsShowNewest: true) {
            await open(item: item, autoplay: false, preservesContext: true, origin: .restore)
        }
    }

    /// The standby pointer's resolution chain, shared by the start restore,
    /// the live refresh and the play on a foreign claim. Every exit writes
    /// one line: what was asked, what was taken, by which rung.
    private func resolveStandbyItem(_ lastId: String,
                                    entries: [LibraryEntry] = [],
                                    allowsShowNewest: Bool) async -> LibraryItem? {
        // Podcast episodes resolve through the subscriptions' episode index,
        // which loads asynchronously at startup. Wait for it, otherwise a
        // cold-start restore of a podcast episode races the disk load.
        if ItemNamespace.isPodcastEpisode(lastId) {
            await PodcastSubscriptions.shared.ensureLoaded()
        }
        let (item, via) = await standbyLadder(lastId, entries: entries, allowsShowNewest: allowsShowNewest)
        Logger.player.notice("STANDBY open claim=\(lastId, privacy: .public) resolved=\(item?.id ?? "none", privacy: .public) via=\(via, privacy: .public)")
        return item
    }

    private func standbyLadder(_ lastId: String, entries: [LibraryEntry],
                               allowsShowNewest: Bool) async -> (LibraryItem?, String) {
        // The last played item can come from ANY source. The loaded library
        // list answers first (it carries the freshest progress), then THE
        // resolver of the session: the seam, and a detail fetch for an id
        // the session cache does not carry (sub: albums and songs). A
        // successful open() re-writes lastItemKey, healing a stale value.
        if let item = entries.first(where: { $0.id == lastId })?.item { return (item, "library") }
        if let item = await AppSession.shared.resolveItem(forId: lastId) { return (item, "seam") }
        guard ItemNamespace.isRSS(lastId) else { return (nil, "none") }
        let subscriptions = PodcastSubscriptions.shared
        // The same episode followed here under another feed key (the show
        // moved hosts, a premium twin): the twin is the same episode.
        if let twin = PodcastSubscriptions.twinEpisodeId(for: lastId, among: subscriptions.allEpisodes().map(\.episode.guid)),
           let item = await AppSession.shared.resolveItem(forId: twin) {
            return (item, "twin")
        }
        guard let showId = Self.showId(forEpisodeId: lastId),
              let show = subscriptions.shows.first(where: { $0.id == showId }) else { return (nil, "none") }
        // The show is followed here, the episode not fetched yet (the other
        // device refreshed first): one fetch of that feed names it.
        var fetched: LibraryItem?
        if let url = PodcastFeedAddress.requestURL(show.feedURL),
           let fresh = await PodcastSubscriptions.fetchAndParse(feedURL: url) {
            fetched = fresh.episodes.first(where: { $0.guid == lastId }).map { podcastLibraryItem(show: fresh, episode: $0) }
            // What the fetch found goes into the stock the resolver reads,
            // so the open that follows asks the network no second time.
            // Measured: the ladder found the episode, the resolver did not,
            // and the iPad showed an error for an episode it had in hand.
            if fetched != nil { await subscriptions.absorb(fresh, showId: showId) }
        }
        // Not in the feed: the show's older episodes, the same way the
        // person's "load more" goes, before anything is called missing.
        if fetched == nil, let added = await subscriptions.loadFullHistory(showId: showId), added > 0,
           let found = subscriptions.episode(guid: lastId) {
            return (podcastLibraryItem(show: found.show, episode: found.episode), "history")
        }
        let items = show.episodes.map { podcastLibraryItem(show: show, episode: $0) }
        let newest = items.max(by: { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) })
        return Self.standbyTail(fetched: fetched, showNewest: newest, allowsShowNewest: allowsShowNewest)
    }

    /// The tail of the ladder, pure. The fetched episode is the episode. A
    /// neighbour (the show's newest) is taken ONLY by the start restore,
    /// for an episode that left a rotating feed; the mirror and the play on
    /// a foreign claim never take one (otherwise the takeover plays the
    /// episode next to the one the other device played).
    nonisolated static func standbyTail(fetched: LibraryItem?, showNewest: LibraryItem?,
                                        allowsShowNewest: Bool) -> (LibraryItem?, String) {
        if let fetched { return (fetched, "feed") }
        if allowsShowNewest, let showNewest { return (showNewest, "show-newest") }
        return (nil, "none")
    }

    /// The claim this device could not name, for the mini player's line.
    @Published private(set) var claimNotKnownHere: String?

    /// Play in the mini player: while another device plays something else,
    /// the tap opens EXACTLY that episode at the claim's stand; otherwise
    /// it toggles the session on the bar.
    func miniPlayTapped(_ viewModel: PlayerViewModel) {
        let action = PlaybackClaimRules.miniPlayAction(
            claim: PlaybackClaimSync.shared.hint, ownDeviceId: SyncHistoryStore.deviceId,
            ownItemId: viewModel.item?.id, isPlaying: viewModel.isPlaying,
            nowMs: Date().timeIntervalSince1970 * 1000)
        switch action {
        case .toggle:
            viewModel.togglePlayPause()
        case .openClaim(let itemId):
            Task { await self.playForeignClaim(itemId) }
        }
    }

    /// Opens the claimed episode through the ladder without the neighbour
    /// rung; an episode this device cannot name is said, not replaced.
    func playForeignClaim(_ itemId: String) async {
        claimNotKnownHere = nil
        if let item = await resolveStandbyItem(itemId, allowsShowNewest: false) {
            await open(item: item, autoplay: true, origin: .gesture)
        } else {
            claimNotKnownHere = itemId
        }
    }

    /// Under the MIRROR rule two devices at rest show the SAME piece
    /// within one reconcile beat. A fresher foreign pointer swaps the paused
    /// mini player (the choice family already decided by event time; the
    /// mirror follows), a held pointer that turned finished clears it. Only a
    /// PLAYING session is untouchable (it claims, and its own open-note wins
    /// the merge anyway). Never auto-plays. The finished-clear stays silent
    /// mechanics (each device derives it; the adoption guard is the twin).
    func refreshStandbyFromTruth() async {
        let stored = AppStorageKeys.lastPlayedItemIdValue
        let held = activeItem?.id
        // Unknown stamps are not a missing stamp: the standby stays as it is.
        guard let stamps = UserChoiceCloudSync.shared.localStamps() else {
            Logger.player.notice("STANDBY kept: the stamps of the choices are not read")
            return
        }
        let verdict = Self.standbyVerdict(
            stored: stored, held: held,
            isPlaying: viewModel?.isPlaying == true,
            ownOpenedAtMs: ownOpenedAtMs,
            foreignStampMs: stamps[lastItemKey],
            heldFinished: held.map { Self.standbyCountsAsFinished(ListeningStore.mark($0)) } ?? false,
            storedFinished: stored.map { Self.standbyCountsAsFinished(ListeningStore.mark($0)) } ?? false)
        switch verdict {
        case .keep:
            return
        case .clearFinished:
            viewModel?.stop(); viewModel = nil; activeItem = nil
            AppStorageKeys.lastPlayedItemIdValue = nil
            Logger.player.notice("STANDBY cleared live: \(held ?? "-", privacy: .public) counts as finished")
        case .clearTombstone:
            // Foreign tombstone adopted. "nothing on standby" travels.
            viewModel?.stop(); viewModel = nil; activeItem = nil
            Logger.player.notice("STANDBY cleared live: foreign tombstone")
        case .swap(let target):
            if let item = await resolveStandbyItem(target, allowsShowNewest: false) {
                Logger.player.notice("STANDBY swapped live: \(target, privacy: .public)")
                await open(item: item, autoplay: false, origin: .mirror)
            }
        }
    }

    /// What the mirror does, pure. `stored` is the adopted pointer, `held`
    /// the session on the mini player.
    enum StandbyVerdict: Equatable {
        case keep
        case clearFinished
        case clearTombstone
        case swap(String)
    }

    /// The mirror's decision. A PLAYING session is untouchable. A session
    /// this run opened itself is untouchable too, as long as its open is
    /// younger than the adopted foreign pointer's stamp: a start that
    /// still waits for the server is this device's session, not a paused
    /// standby (otherwise the mirror can swap the book against the other
    /// device's episode in the 1.5 s before `play()`, and it never starts).
    nonisolated static func standbyVerdict(stored: String?, held: String?, isPlaying: Bool,
                                           ownOpenedAtMs: Double?, foreignStampMs: Double?,
                                           heldFinished: Bool, storedFinished: Bool) -> StandbyVerdict {
        if isPlaying { return .keep }
        if let held {
            if stored == held { return heldFinished ? .clearFinished : .keep }
            // Own open younger than (or unstamped against) the foreign
            // pointer: the session is this device's, waiting or paused.
            if let ownOpenedAtMs, (foreignStampMs ?? 0) <= ownOpenedAtMs { return .keep }
            if stored == nil { return .clearTombstone }
        }
        guard let stored, stored != held else { return .keep }
        guard !storedFinished else { return .keep }
        return .swap(stored)
    }

    /// The moment this run last opened a session itself (ms since 1970);
    /// nil until the first own open.
    private(set) var ownOpenedAtMs: Double?

    /// The session becomes ours HERE, before any wait for the server. A
    /// gesture notes the pointer and its stamp at once (no revision
    /// burst between here and `play()` may read the adopted foreign
    /// pointer as the fresher truth); the mirror and the restore only take
    /// the item and note nothing, and `ownOpenedAtMs` stays as it was, so a
    /// fresher foreign pointer still swaps a restored, paused standby.
    /// The standby pointer, kept and sent in one move.
    ///
    /// Three places wrote these two lines by hand (the gesture, its
    /// withdrawal, the close), and the pair has to stay a pair: a value
    /// kept here and not sent leaves the other devices on the old title, a
    /// value sent and not kept leaves this one.
    private func setStandbyPointer(_ id: String?) {
        AppStorageKeys.lastPlayedItemIdValue = id
        UserChoiceCloudSync.shared.noteScalar(key: lastItemKey, value: id)
    }

    func beginOwnSession(_ item: LibraryItem, origin: OpenOrigin) {
        if !goingBack, RemoteCommandRule.remembersForBack(leaving: activeItem?.id, starting: item.id),
           let previous = activeItem {
            songsBefore.append(previous)
            if songsBefore.count > Self.songsBeforeLimit { songsBefore.removeFirst() }
        }
        activeItem = item
        guard origin == .gesture else { return }
        ownOpenedAtMs = Date().timeIntervalSince1970 * 1000
        // What the pointer said before this attempt. The note goes out
        // BEFORE the item is loaded (the other devices must learn of
        // the takeover at the gesture, not when the bytes arrive), and an
        // attempt that fails has to take it back. Otherwise the standby
        // pointer of EVERY device names a title that never played.
        // Only when nothing is pending. A gesture that OVERTAKES another
        // would otherwise make the overtaken title into "what stood
        // before", and that title never played either: A plays, a gesture
        // on B moves the pointer, a gesture on C overtakes B, C fails, and
        // the standby of every device would name B.
        if pointerBeforeOpen == nil { pointerBeforeOpen = AppStorageKeys.lastPlayedItemIdValue }
        setStandbyPointer(item.id)
    }

    /// The open stands: the withdrawal has nothing left to take back.
    func confirmOwnSession() { pointerBeforeOpen = nil }

    /// The open failed: the pointer says again what it said before.
    ///
    /// Not nil, which would be a second wrong statement: the title before
    /// is still the honest standby, it was played. Noted again so the other
    /// devices hear the correction, on the same channel that carried the
    /// claim out.
    func withdrawOwnSession() {
        guard let before = pointerBeforeOpen else { return }
        pointerBeforeOpen = nil
        setStandbyPointer(before)
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
        // Choice family: closing is a deliberate "nothing on standby". The
        // tombstone travels. The derived finished-clear in restoreLastSession
        // deliberately does NOT note: it is mechanics, each device derives it
        // from the synced numbers itself (adoption carries the same guard).
        setStandbyPointer(nil)
    }
}
