// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit
import OSLog

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {

    /// Shown when the app would write a noticeably LOWER progress to the server
    /// than was last saved. This is the central safeguard against exactly the
    /// reset-to-0 problem.
    struct ServerConflict: Identifiable {
        let serverTime: Double
        let localTime: Double
        var id: Double { localTime }
    }

    /// Shown when several fast jumps came IN A ROW via the lock screen/control
    /// center — a typical pattern for accidental pocket contact, since iOS has no
    /// palm detection there. Affects lock-screen jumps only, never buttons within
    /// the app itself.
    struct SuspiciousLockscreenJump: Identifiable {
        let beforeTime: Double
        let afterTime: Double
        var id: Double { afterTime }
    }

    /// Visible sync status in the player — makes it clear at a glance whether the
    /// current progress is really safely saved. Precisely because this app is
    /// defined by reliable sync, this should not happen out of sight.
    enum SyncStatus: Equatable {
        case synced
        /// Offline — sits in the SyncQueue, sent automatically later.
        case queued
        /// Connection lost, current state NOT written yet — but nothing is (yet)
        /// in the queue (no syncProgress failure).
        case offline
        /// Real error (not a pure offline problem).
        case failed

        var label: String {
            switch self {
            case .synced: return String(localized: "Synced")
            case .queued: return String(localized: "Offline — queued for sync")
            case .offline: return String(localized: "Offline")
            case .failed: return String(localized: "Sync failed")
            }
        }

        var systemImage: String {
            switch self {
            case .synced: return "checkmark.icloud"
            case .queued: return "icloud.and.arrow.up"
            case .offline: return "icloud.slash"
            case .failed: return "exclamationmark.icloud"
            }
        }
    }

    /// Short, transient hint (icon + text) about where the current state comes
    /// from or how it is saved. Fixed, checked labels instead of free text —
    /// shown as a global glass pill.
    enum SourceHint: Equatable {
        case saved
        case serverAdopted
        case localUsed
        case queued
        case offline
        case conflict
        case trackFailed
        case streamFailed

        var label: String {
            switch self {
            case .saved: return String(localized: "Progress saved")
            case .serverAdopted: return String(localized: "Adopted server position")
            case .localUsed: return String(localized: "Using local position")
            case .queued: return String(localized: "Offline — queued for sync")
            case .offline: return String(localized: "Offline — progress saved locally")
            case .conflict: return String(localized: "Conflict detected")
            case .trackFailed: return String(localized: "Playback error — track unavailable")
            case .streamFailed: return String(localized: "Stream unavailable — the station could not be reached")
            }
        }

        var icon: String {
            switch self {
            case .saved: return "checkmark.icloud"
            case .serverAdopted: return "arrow.down.circle"
            case .localUsed: return "internaldrive"
            case .queued: return "icloud.and.arrow.up"
            case .offline: return "icloud.slash"
            case .conflict: return "exclamationmark.triangle"
            case .trackFailed: return "exclamationmark.triangle"
            case .streamFailed: return "exclamationmark.triangle"
            }
        }
    }

    @Published var syncStatus: SyncStatus = .synced
    /// Short hint about where the progress came from on open — fades out by
    /// itself after a few seconds.
    @Published var sourceHint: SourceHint?

    @Published var isPlaying = false
    /// Absolute position in the WHOLE book, in seconds — regardless of whether
    /// the book consists of a single M4B file or several tracks.
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var chapters: [ABSChapter] = []
    @Published var currentChapter: ABSChapter?
    /// S19b: true when `chapters` is a track/rest fallback (the server's chapters
    /// didn't cover the book) — the selector shows a discreet hint.
    @Published var chaptersAreFallback = false
    @Published var playbackRate: Float = 1.0
    /// When the current pause started — basis for Smart Rewind on resume.
    private var pausedAt: Date?
    /// Skip interval in seconds (15/30/60), remembered app-wide.
    @Published var skipInterval: Double =
        UserDefaults.standard.object(forKey: AppStorageKeys.skipInterval) as? Double ?? 30
    @Published var sleepTimerRemaining: TimeInterval?
    /// F2: raw ICY StreamTitle from the live stream (radio) — parsed for
    /// display via `icyNowPlaying`; reset on every item switch.
    @Published var icyStreamTitle: String?
    /// Teil 2: the resolved now-playing cover for the CURRENT ICY song (nil =
    /// show the station logo). Drives the in-app player cover; the lock screen
    /// uses `artworkImage`. Reset on every item switch.
    @Published var icySongArtwork: UIImage?
    /// Keeps the metadata-output delegate alive (the output holds it weakly).
    private var icyCollector: ICYMetadataCollector?
    /// True while the sleep timer runs in "until end of chapter" mode (for the
    /// menu display).
    @Published var sleepUntilChapterEnd = false
    /// True while the sleep timer runs in "until end of track" mode.
    @Published var sleepUntilTrackEnd = false
    @Published var errorMessage: String?
    @Published var pendingServerConflict: ServerConflict?
    @Published var suspiciousLockscreenJump: SuspiciousLockscreenJump?
    /// True while the player is rebuffering (e.g. after a brief signal drop) —
    /// the view then shows a "Loading…" state instead of a rigid error.
    @Published var isBuffering = false
    /// Mirrors whether the book counts as finished (for the "mark as played"
    /// button, which then changes to "mark as unplayed").
    @Published var isFinished = false

    /// AVQueuePlayer instead of AVPlayer so multi-file books (several audio files
    /// instead of one M4B) play back-to-back seamlessly. All existing AVPlayer
    /// calls (rate, pause, …) work unchanged, AVQueuePlayer is a subclass.
    var player: AVQueuePlayer?
    private var timeObserverToken: Any?
    // `nonisolated(unsafe)`: these opaque NotificationCenter tokens are assigned
    // only on the main actor (setup) and read again on the main actor (stop) or
    // in the nonisolated `deinit`, which runs after the last reference is gone —
    // so there is never concurrent access. Lets `deinit` remove the observers
    // without a non-Sendable data-race error.
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaResetObserver: NSObjectProtocol?
    /// True if playback was running when an interruption (Siri, navigation
    /// prompt, phone call) began — resume once it ends.
    private var resumeAfterInterruption = false
    nonisolated(unsafe) private var trackAdvanceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var trackFailureObserver: NSObjectProtocol?
    /// KVO on each queued item's `status`: an unreachable or ATS-blocked stream
    /// sets `.failed` WITHOUT ever firing `AVPlayerItemFailedToPlayToEndTime`
    /// (playback never begins) — it would stall silently. Rebuilt per queue.
    private var itemStatusObservers: [NSKeyValueObservation] = []
    /// Track indices that already got their ONE automatic recovery attempt —
    /// guards against a rebuild loop on a persistently broken track.
    private var trackRetryAttempts: Set<Int> = []
    var sleepTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?

    let provider: any AudioProvider
    var item: LibraryItemDetail?
    /// Called once when the book plays to its END (not on manual "mark
    /// finished") — the coordinator uses it for auto-play-next-in-series.
    var onBookFinished: ((String) -> Void)?
    var artworkImage: UIImage?
    /// Teil 2: the station logo (favicon) for live radio — the fallback the ICY
    /// now-playing cover reverts to when a song has no Cover Art Archive match.
    /// Set by `loadArtwork`, read by `refreshICYArtwork` (both in +NowPlaying).
    var stationArtwork: UIImage?

    /// All tracks of the book, sorted. Exactly one for a normal M4B book,
    /// several for multi-file books.
    private var tracks: [ABSAudioTrack] = []
    /// Index of the track currently active in the player.
    private var currentTrackIndex: Int = 0
    /// AVPlayerItem → track index. Source of truth for the absolute time math:
    /// the index is DERIVED per tick from the currently playing item instead of
    /// counted via notification — missed/late track-change notifications can no
    /// longer distort the book time (false backward jump → false conflict dialog).
    private var itemTrackIndex: [ObjectIdentifier: Int] = [:]
    /// Local files of a downloaded book, keyed by track index — strict
    /// mapping, immune to stray files in the folder.
    private var localTrackFiles: [Int: URL] = [:]

    /// True while a write to the server is in flight.
    var syncInFlight = false
    /// A force sync arrived while one was running — re-run once afterwards.
    var syncFollowUpRequested = false

    /// Seconds before the timer end over which the volume fades gently — no hard
    /// stop mid-sentence.
    /// Y12: seconds of volume fade before the sleep timer pauses — a named
    /// knob for tuning; 8 s felt too abrupt, doubled to 16 s.
    let sleepFadeDuration: Double = 16

    /// Last value successfully written to the server.
    var lastSyncedTime: Double = 0
    /// UserDefaults key of this book's per-second position backup. Closes the
    /// 30s loss window on crash/force-quit: [time, ms-epoch].
    var localPositionKey: String? {
        item.map { AppStorageKeys.localPosition($0.id) }
    }

    /// Last write time of the local position backup (throttle).
    private var lastLocalSaveAt: TimeInterval = 0

    /// lastUpdate timestamp of the last SEEN server entry (ms epoch). A newer
    /// entry comes from another device (or our own write) — basis for the device
    /// reconcile.
    var lastKnownServerUpdate: Double = 0
    /// Set when the user jumped DELIBERATELY (scrubber, chapter, ±30s, lock
    /// screen). A deliberate backward jump is legitimate and triggers no warning
    /// dialog. Only a drop WITHOUT user action is dangerous (e.g. player reset to
    /// 0) — exactly the reset scenario.
    var suppressConflictForNextSync = false

    /// Threshold above which a non-user-initiated backward jump counts as
    /// suspicious.
    let suspiciousDropThreshold: Double = 120

    // MARK: - Pocket-contact protection for lock-screen jumps

    /// Timestamps of the recent jumps via the lock screen/control center — only
    /// THIS path is affected, not the buttons in the app itself (see
    /// `skipFromLockscreen`).
    private var recentLockscreenSkipTimestamps: [Date] = []
    /// State before the currently running jump series began — the return point
    /// if the series turns out to be unwanted.
    private var lockscreenSkipBaseline: Double?
    /// Time window within which several jumps count as "one series".
    private let lockscreenSkipWindow: TimeInterval = 4
    /// From this many jumps within the window the series counts as suspicious
    /// (typical pocket-contact pattern, not deliberate multiple tapping).
    private let lockscreenSkipSuspicionCount = 5

    init(provider: any AudioProvider) {
        self.provider = provider
        super.init()
        configureAudioSession()
        observeInterruptions()
        observeRouteChanges()
        observeMediaServicesReset()
    }

    /// Headphones/Bluetooth disconnected: pause instead of blasting the
    /// speaker (Apple guideline for .oldDeviceUnavailable).
    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // Drive mode: every route change re-evaluates the remembered car
            // route (auto-enter on connect, exit on disconnect).
            Task { @MainActor in DriveModeController.shared.handleRouteChange() }
            guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.pause()
            }
        }
    }

    /// The audio daemon restarted: all player objects are invalid — rebuild
    /// the queue at the current position (paused), otherwise the app stays
    /// silent until the book is reopened.
    private func observeMediaServicesReset() {
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.item != nil else { return }
                self.configureAudioSession()
                // Playback WAS stopped by the system: anchor Smart Rewind
                // like any other pause.
                if self.isPlaying { self.pausedAt = Date() }
                self.isPlaying = false
                let position = self.currentTime
                let index = self.trackIndex(for: position)
                self.buildQueue(
                    startingAtTrackIndex: index,
                    seekWithin: max(0, position - self.trackAbsoluteStart(index))
                )
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Siri/navigation prompts/calls interrupt the audio session: the system
    /// pauses playback but never restarts it — mirror the pause in our state
    /// and resume when the interruption ends (if the system says we should).
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            // Extract primitives here; Notification itself is not Sendable.
            guard let info = note.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            Task { @MainActor [weak self] in
                self?.handleInterruption(began: type == .began, shouldResume: shouldResume)
            }
        }
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            // Don't overwrite on nested interruptions (second .began while the
            // first is still active would clear the flag → no resume).
            if isPlaying {
                resumeAfterInterruption = true
                // Same bookkeeping as pause(), minus player.pause() (the
                // system already halted the audio): Smart-Rewind anchor and a
                // prompt sync while we still have CPU.
                pausedAt = Date()
                Task { await syncProgress(force: true) }
            }
            // Mirror the halt in our state (also fixes the play/pause
            // button showing the wrong icon).
            isPlaying = false
            updateNowPlayingInfo()
        } else {
            if resumeAfterInterruption, shouldResume {
                play()
            }
            resumeAfterInterruption = false
        }
    }

    private func configureAudioSession() {
        // Only set the category — setActive(true) only on actual playback (play):
        // otherwise the silent restore of the last session at app start would
        // already interrupt other apps' music.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = String(localized: "Audio session could not be activated: \(error.localizedDescription)")
        }
    }

    deinit {
        // If the session was not ended via stop(): remove block-based
        // observers so nothing lingers in NotificationCenter.
        if let trackAdvanceObserver {
            NotificationCenter.default.removeObserver(trackAdvanceObserver)
        }
        for observer in [interruptionObserver, routeChangeObserver, mediaResetObserver, trackFailureObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    // MARK: - Loading

    /// - Parameter isOfflineFallback: true when this book was opened via the
    ///   offline metadata cache (server unreachable) instead of a fresh server
    ///   response — only controls the brief "Resumed from …" hint, otherwise
    ///   identical behaviour.
    /// - Parameter restart: replay from the beginning — ignore any saved/server
    ///   position, clear the finished flag, and write `0` through immediately
    ///   (server + iCloud/gpodder) without the conflict guard blocking the
    ///   intended backward jump. Makes "replay a finished episode" reliable for
    ///   every source, not just feeds without server progress.
    func load(item: LibraryItemDetail, isOfflineFallback: Bool = false, restart: Bool = false) async {
        self.item = item
        let sortedTracks = (item.media.tracks ?? []).enumerated().sorted { l, r in
            // Stable: fall back to the original position when the server
            // index is missing/equal — Swift's sort is not stability-guaranteed,
            // and download naming vs. playback order MUST agree.
            let li = l.element.index ?? l.offset
            let ri = r.element.index ?? r.offset
            return li == ri ? l.offset < r.offset : li < ri
        }.map(\.element)
        tracks = sortedTracks
        duration = item.media.duration ?? sortedTracks.reduce(0) { $0 + ($1.duration ?? 0) }

        // S19/S19b: resolve the chapter list once — validated chapters if they
        // cover the book, otherwise a track/rest fallback (ABS ships items with
        // chapters covering only part of the duration). Selector, player display
        // and the S9b chapter-swipe all use THIS list.
        // T9b: podcasts keep partial chapter coverage (segment markers) — the
        // coverage fallback is audiobook-only.
        let isPodcast = item.id.hasPrefix("rss:") || item.id.hasPrefix("abspod:")
        let resolvedChapters = ChapterModel.resolved(
            chapters: item.media.chapters ?? [], tracks: sortedTracks, duration: duration,
            isPodcast: isPodcast, isMusic: item.id.hasPrefix("sub:"))
        chapters = resolvedChapters.chapters
        chaptersAreFallback = resolvedChapters.isFallback

        guard !sortedTracks.isEmpty else {
            errorMessage = String(localized: "No playable track found.")
            return
        }

        localTrackFiles = DownloadManager.shared.localTrackMap(forItemId: item.id)
        trackRetryAttempts.removeAll()
        observeTrackFailures()
        // Self-heal: a "downloaded" book with missing/corrupt tracks fetches
        // exactly those in the background (valid ones are skipped). Only for
        // downloadable sources — local files stream from disk, never download.
        if provider.capabilities.contains(.downloadable),
           DownloadManager.shared.isDownloaded(itemId: item.id),
           localTrackFiles.count < sortedTracks.count,
           NetworkMonitor.shared.isConnected {
            let provider = self.provider
            Task { await DownloadManager.shared.download(item: item, provider: provider) }
        }

        // Core rule at start: the server state wins, never start at 0 when the
        // server already knows progress.
        let serverProgress = item.userMediaProgress?.currentTime ?? 0
        let serverUpdateMs = item.userMediaProgress?.lastUpdate ?? 0
        var startTime = serverProgress
        var restoredFromLocal = false
        // Crash safety: if the per-second local backup is NEWER than the server
        // state and differs noticeably (the app died before the next sync),
        // continue there and flush it right away.
        if let saved = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double],
           saved.count == 2,
           SyncRules.shouldRestoreLocalPosition(
               savedTime: saved[0], savedAtMs: saved[1],
               serverTime: serverProgress, serverUpdateMs: serverUpdateMs
           ) {
            startTime = saved[0]
            restoredFromLocal = true
        }
        // Explicit replay: ignore any saved/server position and begin at 0.
        if restart {
            startTime = 0
            restoredFromLocal = false
        }
        let startIndex = trackIndex(for: startTime)
        let offsetWithinTrack = max(0, startTime - trackAbsoluteStart(startIndex))

        guard buildQueue(startingAtTrackIndex: startIndex, seekWithin: offsetWithinTrack) else {
            errorMessage = String(localized: "Audiobook could not be loaded.")
            return
        }

        setupRemoteCommandCenter()
        lastSyncedTime = serverProgress
        lastKnownServerUpdate = serverUpdateMs
        currentTime = startTime
        isFinished = restart ? false : (item.userMediaProgress?.isFinished ?? false)
        // Remembered per-book speed; then a per-show podcast rate (if set);
        // otherwise the default speed from the settings instead of a hard 1.0.
        let showRate: Float? = AppStorageKeys.podcastShowId(forEpisodeId: item.id).flatMap {
            UserDefaults.standard.object(forKey: AppStorageKeys.podcastShowRate($0)) as? Float
        }
        playbackRate = (UserDefaults.standard.object(forKey: AppStorageKeys.playbackRate(item.id)) as? Float)
            ?? showRate
            ?? (UserDefaults.standard.object(forKey: AppStorageKeys.defaultPlaybackRate) as? Float ?? 1.0)
        updateCurrentChapter()
        updateNowPlayingInfo()
        updateWidgetSnapshot(force: true)
        startSyncTimer()
        syncStatus = .synced
        // Hint only when a state was actually adopted — for a fresh book (start
        // at 0) "adopted server position" would be misleading.
        if isOfflineFallback || restoredFromLocal {
            showSourceHint(.localUsed)
        } else if serverProgress > 0 && !restart {
            showSourceHint(.serverAdopted)
        }
        if restoredFromLocal {
            // Flush the restored state immediately (offline → queue). No conflict
            // dialog: the state was intended before the crash.
            suppressConflictForNextSync = true
            await syncProgress(force: true)
        }
        if restart {
            // Deliberate replay from 0: write it through immediately (server +
            // iCloud/gpodder) and don't let the conflict guard flag the backward
            // jump — starting over is intended, on every source.
            suppressConflictForNextSync = true
            await syncProgress(force: true)
        }

        // Load the cover for lock screen / Dynamic Island. The system shows both
        // automatically once MPNowPlayingInfoCenter has an artwork — no own Live
        // Activity needed.
        loadArtwork(coverURL: provider.coverURL(forItemId: item.id))
    }

    /// Shows a brief hint (e.g. "adopted server position") and fades it out by
    /// itself after a few seconds. Shown globally via the overlay pill —
    /// regardless of whether you are currently in the
    /// library, on the detail page or in the full player.
    func showSourceHint(_ hint: SourceHint) {
        sourceHint = hint
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.sourceHint == hint {
                self?.sourceHint = nil
            }
        }
    }

    // MARK: - Track-Verwaltung (Multi-Track)

    /// Cumulative start time (absolute seconds in the whole book) for a track
    /// index. Uses `startOffset` from the server if present, otherwise sums the
    /// individual durations itself.
    /// M4: the Subsonic song currently playing (`sub:` items only) — id, its
    /// absolute start within the album item, and lookup metadata for lyrics.
    var currentMusicSong: (id: String, start: Double, title: String?, artist: String?, duration: Double)? {
        guard item?.id.hasPrefix("sub:") == true,
              tracks.indices.contains(currentTrackIndex) else { return nil }
        let track = tracks[currentTrackIndex]
        return (track.contentUrl,
                trackAbsoluteStart(currentTrackIndex),
                currentChapter?.title,
                item?.media.metadata?.authorName,
                track.duration ?? 0)
    }

    private func trackAbsoluteStart(_ index: Int) -> Double {
        TrackMath.trackStart(index: index, tracks: tracks, bookDuration: duration)
    }

    /// Finds the track that an absolute book time falls into.
    private func trackIndex(for absoluteTime: Double) -> Int {
        TrackMath.trackIndex(for: absoluteTime, tracks: tracks, bookDuration: duration)
    }

    private func resolveTrackURL(index: Int) -> URL? {
        if let local = localTrackFiles[index] {
            return local
        }
        guard index < tracks.count else { return nil }
        return provider.streamURL(forContentPath: tracks[index].contentUrl)
    }

    /// Rebuilds the playback queue starting at the given track and seeks to the
    /// given position within the first track. Needed because AVQueuePlayer can
    /// only seek within the current item — for jumps across track boundaries
    /// (chapter, scrubber, device switch) the queue must be rebuilt.
    @discardableResult
    private func buildQueue(startingAtTrackIndex startIndex: Int, seekWithin: Double) -> Bool {
        guard startIndex >= 0, startIndex < tracks.count else { return false }

        // Cleanly tear down the old player and its observers.
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil
        if let observer = trackAdvanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        trackAdvanceObserver = nil
        for observer in itemStatusObservers { observer.invalidate() }
        itemStatusObservers.removeAll()

        let isRadio = self.item?.id.hasPrefix("radio:") == true
        var items: [AVPlayerItem] = []
        itemTrackIndex.removeAll()
        icyStreamTitle = nil   // F2: never carry a song title across items
        icySongArtwork = nil   // Teil 2: nor its resolved cover
        stationArtwork = nil   // Teil 2: the next station loads its own logo
        for index in startIndex..<tracks.count {
            guard let url = resolveTrackURL(index: index) else { continue }
            if isRadio {
                // Y42: persistent breadcrumb — a station that never plays leaves
                // the resolved stream URL and, below, its load error in the log.
                Logger.player.notice("radio play: building stream \(url.absoluteString, privacy: .public)")
            }
            // Decide per track: a partially downloaded book can mix local
            // files and streaming (auth header only makes sense remotely).
            let item: AVPlayerItem
            if url.isFileURL {
                item = AVPlayerItem(asset: AVURLAsset(url: url))
            } else {
                let headers = provider.streamAuthHeaders(forItemId: self.item?.id ?? "")
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                item = AVPlayerItem(asset: asset)
            }
            // F2: live radio — tap the in-stream ICY metadata (song title)
            // for the player UI and the lock screen.
            if isRadio {
                let output = AVPlayerItemMetadataOutput(identifiers: nil)
                let collector = ICYMetadataCollector { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.icyStreamTitle != value else { return }
                        self.icyStreamTitle = value
                        self.updateNowPlayingInfo()
                        // Teil 2: try to resolve now-playing cover art for the song.
                        self.refreshICYArtwork()
                    }
                }
                icyCollector = collector
                output.setDelegate(collector, queue: DispatchQueue(label: "de.lzs.maer.icy"))
                item.add(output)
            }
            itemTrackIndex[ObjectIdentifier(item)] = index
            // Surface a load failure that never starts playback (ATS block,
            // dead stream, 404) — otherwise it stalls silently (Regel 3).
            // @Sendable: KVO fires on an arbitrary thread; an inheriting closure
            // would trap there under the MainActor default (the Y32 lesson). Only
            // Sendable values (index, description) cross onto the main actor.
            let failedIndex = index
            let observation = item.observe(\.status, options: [.new]) { @Sendable [weak self] observedItem, _ in
                guard observedItem.status == .failed else { return }
                let description = observedItem.error?.localizedDescription
                    ?? observedItem.errorLog()?.events.last?.errorComment
                Task { @MainActor [weak self] in
                    self?.handleItemLoadFailure(trackIndex: failedIndex, errorDescription: description)
                }
            }
            itemStatusObservers.append(observation)
            items.append(item)
        }
        guard !items.isEmpty else { return false }

        let newPlayer = AVQueuePlayer(items: items)
        let wasPlaying = isPlaying
        player = newPlayer
        currentTrackIndex = startIndex

        addTimeObserver()
        observeBookEnd(lastItem: items.last)

        if seekWithin > 0.5 {
            newPlayer.seek(to: CMTime(seconds: seekWithin, preferredTimescale: 1000))
        }
        if wasPlaying {
            newPlayer.rate = playbackRate
        }
        return true
    }

    /// Detects the BOOK end (last item finished): sync as finished immediately
    /// instead of waiting for the 30s timer. Track changes no longer need an
    /// observer — the index comes per tick from `itemTrackIndex`.
    private func observeBookEnd(lastItem: AVPlayerItem?) {
        if let observer = trackAdvanceObserver {
            NotificationCenter.default.removeObserver(observer)
            trackAdvanceObserver = nil
        }
        guard let lastItem else { return }
        trackAdvanceObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: lastItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = self.duration
                self.isPlaying = false
                // Also mark finished locally — the sync writes it anyway;
                // otherwise the UI shows the wrong state after a fully played book.
                self.isFinished = true
                self.updateNowPlayingInfo()
                self.updateWidgetSnapshot(force: true)
                await self.syncProgress(force: true)
                if let finishedId = self.item?.id {
                    self.onBookFinished?(finishedId)
                }
            }
        }
    }

    /// X16c: finalize the current item as finished — set the position to the end
    /// and the finished flag, so a following `stop()` (and its final sync) writes
    /// "finished" rather than the current position. Used when the user marks the
    /// ACTIVE item as played, mirroring a natural end.
    func finalizeAsFinished() {
        currentTime = duration
        isFinished = true
    }

    // MARK: - Playback

    func play() {
        activateAudioSession()
        applySmartRewindIfNeeded()
        // In case a sleep fade was interrupted mid-way: full volume.
        player?.volume = 1
        player?.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo()
        updateWidgetSnapshot(force: true)
        Haptics.tap()
    }

    /// Smart Rewind (settings toggle, default ON): resuming after a longer
    /// pause jumps back a little so the listener regains context. Only for
    /// pauses in THIS session — after a relaunch the position is loaded
    /// fresh anyway. Not user-initiated: no immediate forced server write.
    private func applySmartRewindIfNeeded() {
        guard let pausedAt else { return }
        self.pausedAt = nil
        guard UserDefaults.standard.object(forKey: AppStorageKeys.smartRewind) as? Bool ?? true else { return }
        let gap = Date().timeIntervalSince(pausedAt)
        let rewind: Double
        switch gap {
        case ..<120: return                 // short pause: resume in place
        case ..<600: rewind = 10            // 2–10 min
        case ..<3600: rewind = 20           // 10–60 min
        default: rewind = 30                // an hour or more
        }
        guard currentTime > 0 else { return }
        Task { await seek(to: max(0, currentTime - rewind), userInitiated: false) }
    }

    /// Starts playback, but first briefly reconciles with the server.
    /// Covers the device switch: if you pause on the iPhone and want to continue
    /// on the iPad seconds later, the iPad jumps to the newer server state before
    /// playing — instead of starting from the old local state and overwriting the
    /// fresh progress.
    func playWithServerCheck() async {
        // Wait for the reconcile at most 1.5s — on a slow network (no immediate
        // offline error) the play button must not hang until the URLSession
        // timeout. If the reconcile takes longer, playback starts immediately; a
        // later adopt then jumps during playback.
        let reconcile = Task { await self.reconcileWithServer() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reconcile.value }
            group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            await group.next()
            group.cancelAll()
        }
        play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        pausedAt = Date()
        updateNowPlayingInfo()
        updateWidgetSnapshot(force: true)
        ListeningStatsStore.shared.flush()
        Haptics.tap()
        Task { await syncProgress(force: true) }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            Task { await playWithServerCheck() }
        }
    }

    /// - Parameter userInitiated: true for all deliberate user actions
    ///   (scrubber, chapter, skip, lock screen). Such jumps are written to the
    ///   server immediately and without confirmation — also backwards.
    func seek(to time: Double, userInitiated: Bool = true) async {
        guard !tracks.isEmpty else { return }
        let clamped = max(0, min(time, max(duration, 0)))
        let targetIndex = trackIndex(for: clamped)
        let offsetWithinTrack = max(0, clamped - trackAbsoluteStart(targetIndex))

        if targetIndex == currentTrackIndex, let player {
            // Jump stays within the currently loaded track.
            await player.seek(to: CMTime(seconds: offsetWithinTrack, preferredTimescale: 1000))
        } else {
            // Jump across a track boundary — rebuild the queue.
            buildQueue(startingAtTrackIndex: targetIndex, seekWithin: offsetWithinTrack)
        }

        currentTime = clamped
        updateCurrentChapter()
        updateNowPlayingInfo()
        if userInitiated {
            // A DELIBERATE jump picks a new position — Smart Rewind must not
            // pull away from it when playback resumes after a long pause.
            pausedAt = nil
            suppressConflictForNextSync = true
            await syncProgress(force: true)
        }
    }

    func skip(by seconds: Double) {
        Task { await seek(to: currentTime + seconds) }
    }

    /// Like `skip(by:)`, but intended only for jumps via the lock screen/control
    /// center — there is (unlike buttons in the app) no palm detection there. A
    /// skip command from your pocket can trigger unnoticed several times in a
    /// row. Only from several fast jumps in a short time does the detection kick
    /// in — a single deliberate lock-screen jump still goes through immediately,
    /// without any confirmation.
    func skipFromLockscreen(by seconds: Double) {
        let now = Date()
        recentLockscreenSkipTimestamps.removeAll { now.timeIntervalSince($0) > lockscreenSkipWindow }
        if recentLockscreenSkipTimestamps.isEmpty {
            lockscreenSkipBaseline = currentTime
        }
        recentLockscreenSkipTimestamps.append(now)

        if recentLockscreenSkipTimestamps.count > lockscreenSkipSuspicionCount {
            // Threshold exceeded: don't run this further jump automatically,
            // instead ask once whether the whole series was really intended.
            recentLockscreenSkipTimestamps.removeAll()
            if suspiciousLockscreenJump == nil, let baseline = lockscreenSkipBaseline {
                suspiciousLockscreenJump = SuspiciousLockscreenJump(beforeTime: baseline, afterTime: currentTime)
            }
            return
        }

        Task { await seek(to: currentTime + seconds) }
    }

    func jumpToChapter(_ chapter: ABSChapter) {
        Task { await seek(to: chapter.start) }
    }

    /// Jumps to the previous chapter. After more than 3 seconds into the current
    /// chapter it first jumps to its start (as common in music/podcast apps);
    /// only a further press goes back one chapter.
    func previousChapter() {
        guard !chapters.isEmpty else { return }
        guard let idx = currentChapterIndex else { return }
        let currentStart = chapters[idx].start
        Haptics.tap()
        if currentTime - currentStart > 3 || idx == 0 {
            Task { await seek(to: currentStart) }
        } else {
            Task { await seek(to: chapters[idx - 1].start) }
        }
    }

    func nextChapter() {
        guard !chapters.isEmpty, let idx = currentChapterIndex else { return }
        if idx + 1 < chapters.count {
            Haptics.tap()
            Task { await seek(to: chapters[idx + 1].start) }
        }
    }

    private var currentChapterIndex: Int? {
        guard let current = currentChapter else { return nil }
        return chapters.firstIndex(of: current)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
        // Remember per book.
        if let item {
            UserDefaults.standard.set(rate, forKey: AppStorageKeys.playbackRate(item.id))
        }
    }

    func setSkipInterval(_ seconds: Double) {
        skipInterval = seconds
        UserDefaults.standard.set(seconds, forKey: AppStorageKeys.skipInterval)
        // Update the lock-screen buttons immediately.
        MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [NSNumber(value: seconds)]
        MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [NSNumber(value: seconds)]
    }

    // MARK: - Zeit-Beobachtung

    private func addTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Never derive book time from an item that is not ready to
                // play (e.g. a failed/corrupt track): its position reads 0 and
                // would yank currentTime back to the track start — that was
                // the phantom "conflict detected" right after session restore.
                guard let currentItem = self.player?.currentItem,
                      currentItem.status == .readyToPlay else { return }
                if let idx = self.itemTrackIndex[ObjectIdentifier(currentItem)] {
                    self.currentTrackIndex = idx
                }
                // Local listening stats: 1 s per tick while playing.
                if self.isPlaying { ListeningStatsStore.shared.addSeconds(1) }
                // Absolute book time = start of the current track + position
                // within this track.
                let newTime = self.trackAbsoluteStart(self.currentTrackIndex) + seconds
                self.currentTime = newTime
                // Single-track items (podcasts) often ship a wrong/rounded/missing
                // feed duration, so playback ran past the shown time. Trust the
                // real asset duration when known, and never let the total fall
                // below the current position (no overshoot / negative remaining).
                // Multi-track audiobooks keep their reliable summed duration.
                if self.tracks.count == 1 {
                    let assetSeconds = currentItem.duration.seconds
                    let real = assetSeconds.isFinite && assetSeconds > 0 ? assetSeconds : self.duration
                    let corrected = max(real, newTime)
                    if abs(corrected - self.duration) > 0.5 {
                        self.duration = corrected
                        // Persist the real duration into the episode model —
                        // feeds without/with wrong itunes:duration otherwise
                        // never get a working played/remaining state in lists.
                        if let id = self.item?.id, id.hasPrefix("rss:"),
                           assetSeconds.isFinite, assetSeconds > 0 {
                            PodcastSubscriptions.shared.updateEpisodeDuration(guid: id, duration: assetSeconds)
                        }
                    }
                }
                // Crash safety: keep the position locally — throttled to every
                // 5s (UserDefaults writes aren't free). The loss window on crash
                // is thus at most ~5s instead of 30s.
                let now = Date().timeIntervalSince1970
                if self.isPlaying, now - self.lastLocalSaveAt >= 5, let key = self.localPositionKey {
                    self.lastLocalSaveAt = now
                    UserDefaults.standard.set([self.currentTime, now * 1000], forKey: key)
                    // Listen log: a podcast crossing its played threshold in
                    // normal playback lands in the show-independent history
                    // (cheap + idempotent; threshold logic stays in the store).
                    if let detail = self.item, detail.id.hasPrefix("rss:") || detail.id.hasPrefix("abspod:") {
                        PodcastListenLog.shared.noteIfPlayed(
                            guid: detail.id, duration: detail.media.duration ?? 0,
                            episodeTitle: detail.media.metadata?.title ?? "",
                            showTitle: detail.media.metadata?.authorName ?? "",
                            feedURL: PodcastSubscriptions.shared.feedURL(forEpisodeId: detail.id) ?? "")
                    }
                    self.updateWidgetSnapshot()
                }
                self.updateCurrentChapter()
                self.updateNowPlayingInfo()
                // Download-on-play: save a feed-only episode of an ABS show to
                // the server after ~30 s (no-op if nothing is registered).
                PodcastServerSave.shared.playbackTick(itemId: self.item?.id, currentTime: self.currentTime)
                // Check the buffering status here too — uses the same clean
                // MainActor context, no separate KVO observer needed.
                if let currentItem = self.player?.currentItem {
                    self.isBuffering = self.isPlaying
                        && currentItem.isPlaybackBufferEmpty
                        && !currentItem.isPlaybackLikelyToKeepUp
                }
            }
        }
    }

    // MARK: - Failed-Track-Recovery

    /// One global observer (object nil: queue items change on every rebuild):
    /// a track that CANNOT play any further would otherwise be silent —
    /// player stalls, no error surfaces anywhere.
    private func observeTrackFailures() {
        guard trackFailureObserver == nil else { return }
        trackFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            Task { @MainActor [weak self] in
                guard let self, let item else { return }
                self.handleTrackFailure(item)
            }
        }
    }

    /// One automatic recovery per track: a broken LOCAL file is removed (the
    /// rebuilt queue streams the track and the self-heal download replaces
    /// the file); a stream failure gets one rebuild. A second failure stops
    /// playback with a visible hint instead of silent stalling.
    private func handleTrackFailure(_ playerItem: AVPlayerItem) {
        guard let index = itemTrackIndex[ObjectIdentifier(playerItem)] else { return }
        if trackRetryAttempts.contains(index) {
            pause()
            showSourceHint(.trackFailed)
            return
        }
        trackRetryAttempts.insert(index)
        if let local = localTrackFiles[index], NetworkMonitor.shared.isConnected {
            // Only drop the file when streaming can take over; offline the
            // retry re-reads the same file (it may fail transiently).
            try? FileManager.default.removeItem(at: local)
            localTrackFiles[index] = nil
            if let item, DownloadManager.shared.isDownloaded(itemId: item.id) {
                let provider = self.provider
                Task { await DownloadManager.shared.download(item: item, provider: provider) }
            }
        }
        let idx = trackIndex(for: currentTime)
        let rebuilt = buildQueue(
            startingAtTrackIndex: idx,
            seekWithin: max(0, currentTime - trackAbsoluteStart(idx))
        )
        if !rebuilt {
            isPlaying = false
            showSourceHint(.trackFailed)
        }
    }

    /// An item whose asset never loads (`status == .failed`) — the load failure
    /// path that FailedToPlayToEndTime doesn't cover (playback never started).
    /// Logs the error persistently (Y42 diagnosis) and surfaces a hint instead
    /// of a silent stall.
    private func handleItemLoadFailure(trackIndex index: Int, errorDescription: String?) {
        let isRadio = item?.id.hasPrefix("radio:") == true
        Logger.player.notice("play failed: item \(index) status .failed for \(self.item?.id ?? "?", privacy: .public) — \(errorDescription ?? "no error", privacy: .public)")
        // Radio is single-item live audio — no track recovery to attempt; stop
        // and tell the user. Books/podcasts keep their existing retry path.
        guard isRadio else { return }
        isPlaying = false
        showSourceHint(.streamFailed)
    }

    /// Absolute book time where the currently playing track ends —
    /// nil if unknown. Used by the "sleep until end of track" mode.
    func currentTrackEndTime() -> Double? {
        guard currentTrackIndex < tracks.count,
              let trackDuration = tracks[currentTrackIndex].duration else { return nil }
        return trackAbsoluteStart(currentTrackIndex) + trackDuration
    }

    /// Only offer "until end of track" when it differs from the book end
    /// (single-file books: track end == book end, the option adds nothing).
    var canSleepUntilTrackEnd: Bool {
        guard let end = currentTrackEndTime() else { return false }
        return end < duration - 1
    }

    private func updateCurrentChapter() {
        // S19: only a chapter that actually CONTAINS the current time (validated
        // list) — nil in a gap/past the end → the player omits the chapter line.
        let newChapter = ChapterModel.current(at: currentTime, in: chapters)
        guard newChapter != currentChapter else { return }
        currentChapter = newChapter
    }

    // MARK: - Cleanup

    func stop() {
        ListeningStatsStore.shared.flush()
        Task { await syncProgress(force: true) }
        player?.pause()
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil
        if let observer = trackAdvanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        trackAdvanceObserver = nil
        for observer in [interruptionObserver, routeChangeObserver, mediaResetObserver, trackFailureObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        interruptionObserver = nil
        routeChangeObserver = nil
        mediaResetObserver = nil
        trackFailureObserver = nil
        for observer in itemStatusObservers { observer.invalidate() }
        itemStatusObservers.removeAll()
        player = nil
        syncTask?.cancel()
        sleepTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}


/// F2: ICY timed-metadata tap for live radio. AVFoundation calls the delegate
/// on OUR serial queue — nonisolated by construction (the Y32 class rule);
/// the value hops to the MainActor inside `onValue`.
private nonisolated final class ICYMetadataCollector: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onValue: @Sendable (String) -> Void
    init(onValue: @escaping @Sendable (String) -> Void) { self.onValue = onValue }

    /// Hands the metadata items into the async load. `@unchecked Sendable`
    /// (Rule 5 exception, justified): `AVMetadataItem` is a reference type, but
    /// the items are transferred ONCE off the delegate's serial queue and never
    /// touched again there, and `load(_:)` is AVFoundation's designated async
    /// accessor — so there is no concurrent access.
    private struct ItemHandoff: @unchecked Sendable { let items: [AVMetadataItem] }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        let handoff = ItemHandoff(items: groups.flatMap(\.items))
        guard !handoff.items.isEmpty else { return }
        // Y53: `stringValue` is synchronous and iOS-16-deprecated — load it
        // asynchronously. The delegate runs on our serial queue; the Task hops
        // off it, the value reaches the main actor through `onValue`.
        let onValue = self.onValue
        Task {
            for item in handoff.items {
                if let value = try? await item.load(.stringValue), !value.isEmpty {
                    onValue(value)
                    return
                }
            }
        }
    }
}
