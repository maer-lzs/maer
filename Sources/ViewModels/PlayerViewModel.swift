// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    /// center. A typical pattern for accidental pocket contact, since iOS has no
    /// palm detection there. Affects lock-screen jumps only, never buttons within
    /// the app itself.
    struct SuspiciousLockscreenJump: Identifiable {
        let beforeTime: Double
        let afterTime: Double
        var id: Double { afterTime }
    }

    /// Visible sync status in the player. Makes it clear at a glance whether the
    /// current progress is really safely saved. Precisely because this app is
    /// defined by reliable sync, this should not happen out of sight.
    enum SyncStatus: Equatable {
        case synced
        /// Offline. Sits in the SyncQueue, sent automatically later.
        case queued
        /// Connection lost, current state NOT written yet. But nothing is (yet)
        /// in the queue (no syncProgress failure).
        case offline
        /// Real error (not a pure offline problem).
        case failed

        var label: String {
            switch self {
            case .synced: return String(localized: "Synced")
            case .queued: return String(localized: "Offline: queued for sync")
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

    /// The notices this model says (`PlaybackNotice`); what shows, and for
    /// how long, decides the coordinator's channel.
    typealias SourceHint = PlaybackNotice

    @Published var syncStatus: SyncStatus = .synced
    /// The last notice this model said: an event for the channel, which
    /// keeps the pill, its timer and the log. It is not cleared here.
    @Published var sourceHint: SourceHint?
    /// Every start of playback, from any way (button, lock screen, AirPods,
    /// CarPlay, Siri): the channel lets a stopping error fall on it.
    let playbackStarts = PassthroughSubject<Void, Never>()
    /// The player waits to play because the stream does not deliver, not
    /// because it is paused: mid-play when it stopped, and at the start while
    /// the first bytes come (measured, the same reason both times). A state
    /// for the channel, which times the hint; this model keeps no timer for it.
    @Published private(set) var waitsOnTheStream = false

    @Published var isPlaying = false
    /// Absolute position in the WHOLE book, in seconds. Regardless of whether
    /// the book consists of a single M4B file or several tracks.
    @Published var currentTime: Double = 0
    /// Whether anything HAPPENED since this item was loaded.
    /// Playback, a deliberate restart, or a deliberate seek. The restore
    /// flush reads it: a merely-loaded episode must not re-stamp its old
    /// position as new (the reviver).
    var eventSinceLoad = false
    @Published var duration: Double = 0
    @Published var chapters: [ABSChapter] = []
    @Published var currentChapter: ABSChapter?
    /// True when `chapters` is a track/rest fallback (the server's chapters
    /// didn't cover the book). The selector shows a discreet hint.
    @Published var chaptersAreFallback = false
    @Published var playbackRate: Float = 1.0
    /// When the current pause started. Basis for Smart Rewind on resume.
    private var pausedAt: Date?
    /// Skip interval in seconds (15/30/60), remembered app-wide.
    @Published var skipInterval: Double = AppStorageKeys.skipIntervalValue
    @Published var sleepTimerRemaining: TimeInterval?
    /// Raw ICY StreamTitle from the live stream (radio). Parsed for
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
    /// True while the player is rebuffering (e.g. after a brief signal drop).
    /// The view then shows a "Loading…" state instead of a rigid error.
    @Published var isBuffering = false
    /// Mirrors whether the book counts as finished (for the "mark as played"
    /// button, which then changes to "mark as unplayed").
    @Published var isFinished = false

    /// AVQueuePlayer instead of AVPlayer so multi-file books (several audio files
    /// instead of one M4B) play back-to-back seamlessly. All existing AVPlayer
    /// calls (rate, pause, …) work unchanged, AVQueuePlayer is a subclass.
    var player: AVQueuePlayer?
    private var timeObserverToken: Any?
    // These opaque NotificationCenter tokens are assigned only in methods of
    // this main-actor class (setup) and read again there (stop) or in the
    // nonisolated `deinit`, which runs after the last reference is gone. So
    // there is never concurrent access; the marker lets `deinit` remove them.
    // unsafe because main actor and deinit are the only places that touch them.
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaResetObserver: NSObjectProtocol?
    /// True if playback was running when an interruption (Siri, navigation
    /// prompt, phone call) began. Resume once it ends.
    private var resumeAfterInterruption = false
    // unsafe because main actor and deinit are the only places that touch them.
    nonisolated(unsafe) private var trackAdvanceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var trackFailureObserver: NSObjectProtocol?
    /// A later track of this queue that failed to load: the queue ends before
    /// it. At its start playback stops, or, when its local file was dropped
    /// for the server, goes on from there. Cleared by every new queue.
    private var heldAhead: HeldPoint?

    struct HeldPoint {
        let index: Int
        let then: FailedLoad.LocalFallback
        /// Why the held track failed, for the symbol when it stops.
        let cause: NoticeCause
    }

    /// Where the local files of an item lie, and whether the network carries.
    /// Both are the shared ones; a witness hands in its own.
    private let localTracks: (String) -> [Int: URL]
    private let isOnline: () -> Bool
    /// KVO on each queued item's `status`: an unreachable or ATS-blocked stream
    /// sets `.failed` WITHOUT ever firing `AVPlayerItemFailedToPlayToEndTime`
    /// (playback never begins). It would stall silently. Rebuilt per queue.
    private var itemStatusObservers: [NSKeyValueObservation] = []
    /// KVO on the queue player's `timeControlStatus`: a stream that stops
    /// delivering mid-play leaves `isPlaying` true and never fails (measured
    /// over 100 s); only the wait shows it. Rebuilt per queue.
    private var stallObserver: NSKeyValueObservation?
    /// Track indices that already got their ONE automatic recovery attempt.
    /// Guards against a rebuild loop on a persistently broken track.
    private var trackRetryAttempts: Set<Int> = []
    /// The playing item failed to load and playback stopped for it; the
    /// next play or the network's return builds the queue anew.
    private var loadFailureNoted = false
    var sleepTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?

    let provider: any AudioProvider
    var item: LibraryItemDetail?
    /// Called once when the book plays to its END (not on manual "mark
    /// finished"). The coordinator uses it for auto-play-next-in-series.
    var onBookFinished: ((String) -> Void)?
    /// The title button ran off the end of this item's tracks. May the queue
    /// take over? Answered by the coordinator (it owns queue and resolution);
    /// returns whether a next item will start.
    var onQueueSkipRequested: (() -> Bool)?
    /// The title button ran off the start: the song this session played
    /// before, answered by the coordinator (it keeps them). Returns whether
    /// one will start; without one the press goes to the start.
    var onSongBeforeRequested: (() -> Bool)?
    /// Whether the session holds a song before this one.
    var hasSongBefore: (() -> Bool)?
    var artworkImage: UIImage?
    /// Teil 2: the station logo (favicon) for live radio. The fallback the ICY
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
    /// counted via notification. Missed/late track-change notifications can no
    /// longer distort the book time (false backward jump → false conflict dialog).
    private var itemTrackIndex: [ObjectIdentifier: Int] = [:]
    /// Local files of a downloaded book, keyed by track index. Strict
    /// mapping, immune to stray files in the folder.
    private var localTrackFiles: [Int: URL] = [:]

    /// True while a write to the server is in flight.
    var syncInFlight = false
    /// A deliberate sync arrived while one was running. Re-run once
    /// afterwards, under the last occasion that asked.
    var syncFollowUpOrigin: SyncOrigin?
    /// A pause of a running piece asked for its sync, and the run that
    /// records its stand has not ended yet (the record follows the server's
    /// answer). A change of account in that window holds this stand too
    /// (`AccountSwitchHold`).
    var pauseRecordPending = false

    /// Seconds before the timer end over which the volume fades gently. No hard
    /// stop mid-sentence.
    /// Seconds of volume fade before the sleep timer pauses. A named
    /// knob for tuning; 8 s felt too abrupt, doubled to 16 s.
    let sleepFadeDuration: Double = 16

    /// Last value successfully written to the server.
    var lastSyncedTime: Double = 0
    /// Has ANY source answered where this book starts? A fresh
    /// session that found nothing (no witness, no backup, no server answer)
    /// must not push. At 00:00 it would overwrite a server that is hours
    /// ahead, and the suspicious-drop guard has no reference to stop it.
    var startSourceResolved = false

    /// Last write time of the local position backup (throttle).
    private var lastLocalSaveAt: TimeInterval = 0
    /// When THIS playback started, in ms: set on play, never by the
    /// heartbeat. It rides in every claim as the play time, and the pause
    /// rule compares a foreign play against it; against the last heartbeat
    /// the comparison would practically never fire.
    private(set) var playbackStartedAtMs: Double = 0
    /// The owner epoch of the stock when THIS playback started
    /// (`ListeningStore.ownerEpoch`). Every write and claim of the playback
    /// carries it: one that began under the account before writes nothing
    /// into the account's stock or claim after a change of account, so the
    /// pot has nothing of it to send. A play under the new account takes
    /// the new epoch.
    private(set) var standEpoch = ListeningStore.ownerEpoch()

    /// lastUpdate timestamp of the last SEEN server entry (ms epoch). A newer
    /// entry comes from another device (or our own write). Basis for the device
    /// reconcile.
    var lastKnownServerUpdate: Double = 0
    /// Set when the user jumped DELIBERATELY (scrubber, chapter, ±30s, lock
    /// screen). A deliberate backward jump is legitimate and triggers no warning
    /// dialog. Only a drop WITHOUT user action is dangerous (e.g. player reset to
    /// 0). Exactly the reset scenario.
    var suppressConflictForNextSync = false

    /// Threshold above which a non-user-initiated backward jump counts as
    /// suspicious.
    let suspiciousDropThreshold: Double = 120

    // MARK: - Pocket-contact protection for lock-screen jumps

    /// Timestamps of the recent jumps via the lock screen/control center. Only
    /// THIS path is affected, not the buttons in the app itself (see
    /// `skipFromLockscreen`).
    private var recentLockscreenSkipTimestamps: [Date] = []
    /// State before the currently running jump series began. The return point
    /// if the series turns out to be unwanted.
    private var lockscreenSkipBaseline: Double?
    /// Time window within which several jumps count as "one series".
    private let lockscreenSkipWindow: TimeInterval = 4
    /// From this many jumps within the window the series counts as suspicious
    /// (typical pocket-contact pattern, not deliberate multiple tapping).
    private let lockscreenSkipSuspicionCount = 5

    init(provider: any AudioProvider,
         localTracks: @escaping (String) -> [Int: URL] = { DownloadManager.shared.localTrackMap(forItemId: $0) },
         isOnline: @escaping () -> Bool = { NetworkMonitor.shared.isConnected }) {
        self.provider = provider
        self.localTracks = localTracks
        self.isOnline = isOnline
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

    /// The audio daemon restarted: all player objects are invalid. Rebuild
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
                self.notePlayback("stopped", from: "system stop notification")
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
    /// pauses playback but never restarts it. Mirror the pause in our state
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
                Task { await syncProgress(.interruption) }
            }
            // Mirror the halt in our state (also fixes the play/pause
            // button showing the wrong icon).
            notePlayback("stopped", from: "audio session interruption")
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
        // Only set the category. setActive(true) only on actual playback (play):
        // otherwise the silent restore of the last session at app start would
        // already interrupt other apps' music.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        } catch {
            Logger.player.error("AUDIO category failed reason=\(FailureReason.of(error), privacy: .public)")
        }
    }

    /// The title cannot play: the sentence stands in the pill of the channel,
    /// in the full player and over the mini bar, until the next start. Only
    /// there: the line under the controls (`errorMessage`) carries what lasts
    /// beyond the pill, a sync failure, and would say this sentence twice.
    private func cannotPlay(_ sentence: String) {
        showSourceHint(.cannotPlay(sentence))
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            cannotPlay(String(localized: "Audio session could not be activated: \(ErrorSentence.of(error))"))
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
    ///   response. Only controls the brief "Resumed from …" hint, otherwise
    ///   identical behaviour.
    /// - Parameter restart: replay from the beginning. Ignore any saved/server
    ///   position, clear the finished flag, and write `0` through immediately
    ///   (server + iCloud/gpodder) without the conflict guard blocking the
    ///   intended backward jump. Makes "replay a finished episode" reliable for
    ///   every source, not just feeds without server progress.
    func load(item: LibraryItemDetail, isOfflineFallback: Bool = false, restart: Bool = false) async {
        // A fresh load starts with NO event. Restoring is loading,
        // not listening. A deliberate restart is the user acting, so it counts.
        eventSinceLoad = restart
        self.item = item
        applySkipInterval(forItemId: item.id)
        let sortedTracks = (item.media.tracks ?? []).enumerated().sorted { l, r in
            // Stable: fall back to the original position when the server
            // index is missing/equal. Swift's sort is not stability-guaranteed,
            // and download naming vs. playback order MUST agree.
            let li = l.element.index ?? l.offset
            let ri = r.element.index ?? r.offset
            return li == ri ? l.offset < r.offset : li < ri
        }.map(\.element)
        tracks = sortedTracks
        duration = item.media.duration ?? sortedTracks.reduce(0) { $0 + ($1.duration ?? 0) }

        // Resolve the chapter list once. Validated chapters if they
        // cover the book, otherwise a track/rest fallback (ABS ships items with
        // chapters covering only part of the duration). Selector, player display
        // and the cover swipe all use THIS list.
        // Podcasts keep partial chapter coverage (segment markers). The
        // coverage fallback is audiobook-only.
        let isPodcast = ItemNamespace.isPodcastEpisode(item.id)
        let resolvedChapters = ChapterModel.resolved(
            chapters: item.media.chapters ?? [], tracks: sortedTracks, duration: duration,
            isPodcast: isPodcast, isMusic: MusicSourceRule.isServerMusic(item.id))
        chapters = resolvedChapters.chapters
        chaptersAreFallback = resolvedChapters.isFallback

        guard !sortedTracks.isEmpty else {
            cannotPlay(String(localized: "No playable track found."))
            return
        }

        localTrackFiles = localTracks(item.id)
        trackRetryAttempts.removeAll()
        observeTrackFailures()
        // Self-heal: a "downloaded" book with missing/corrupt tracks fetches
        // exactly those in the background (valid ones are skipped). Only for
        // downloadable sources. Local files stream from disk, never download.
        if provider.capabilities.contains(.downloadable),
           DownloadManager.shared.isDownloaded(itemId: item.id),
           localTrackFiles.count < sortedTracks.count,
           isOnline() {
            let provider = self.provider
            Task { await DownloadManager.shared.download(item: item, provider: provider, kind: nil) }
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
        if let saved = ListeningStore.backup(item.id),
           saved.count >= 2,
           SyncRules.shouldRestoreLocalPosition(
               savedTime: saved[0], savedAtMs: saved[1],
               serverTime: serverProgress, serverUpdateMs: serverUpdateMs
           ) {
            startTime = saved[0]
            restoredFromLocal = true
        }
        // The flushed witness. What THIS device last pushed. For a
        // downloaded book it is usually the ONLY local source: the crash
        // backup above is gone after every successful sync, and `item` here is
        // the detail saved at DOWNLOAD time, whose progress never moves. The
        // rule decides; it never wins against a newer foreign device.
        var restoredFromFlushed = false
        if !restoredFromLocal,
           let flushed = ListeningStore.flushed(item.id),
           flushed.count >= 2,
           SyncRules.shouldPreferFlushedWitness(
               flushedTime: flushed[0], flushedAtMs: flushed[1],
               serverTime: serverProgress, serverUpdateMs: serverUpdateMs
           ) {
            startTime = flushed[0]
            restoredFromFlushed = true
        }
        // A backward jump is never silent again. Whatever the
        // cause, the person notices it. So the log names it, with both
        // sides and their timestamps. Threshold 60 s: below that it is the
        // normal re-position, above it is a finding.
        // The reference is whichever local witness EXISTS: the crash backup, or
        // else the flushed one. Measured cause of the silent null start: with
        // the backup deleted there was no reference at all, so the jump could
        // not be logged. The loudest case was the quietest.
        let localWitness = (ListeningStore.backup(item.id))
            ?? (ListeningStore.flushed(item.id))
        if let saved = localWitness, saved.count >= 2, saved[0] - startTime > 60 {
            let source = restoredFromLocal ? "local" : (restoredFromFlushed ? "flushed" : "server")
            let detail = "start=\(Int(startTime))s server=\(Int(serverProgress))s@\(Int(serverUpdateMs))ms local=\(Int(saved[0]))s@\(Int(saved[1]))ms from=\(source)"
            Logger.library.warning("PROGRESS backward jump \(Int(saved[0] - startTime))s on \(item.id, privacy: .public): \(detail, privacy: .public)")
            // The log line alone is out of reach. System logs
            // are not practical to hand over. The diagnosis is the only
            // window, so the last five jumps live in a ring beside it.
            var ring = (AppStorageKeys.array(AppStorageKeys.jumpRing(item.id)) as? [[Double]]) ?? []
            ring.append([Date().timeIntervalSince1970 * 1000, startTime,
                         serverProgress, serverUpdateMs, saved[0], saved[1]])
            AppStorageKeys.set(Array(ring.suffix(5)), for: AppStorageKeys.jumpRing(item.id))
        }
        // Explicit replay: ignore any saved/server position and begin at 0.
        if restart {
            startTime = 0
            restoredFromLocal = false
        }
        // Resolved when anything datable spoke: a server entry in the detail,
        // the crash backup, or the flushed witness. Only the silent case.
        // Downloaded book, frozen detail, no witness, server not (yet) heard.
        // Stays unresolved, and that is exactly the dangerous one.
        startSourceResolved = restoredFromLocal || restoredFromFlushed
            || item.userMediaProgress != nil
        let startIndex = trackIndex(for: startTime)
        let offsetWithinTrack = max(0, startTime - trackAbsoluteStart(startIndex))

        guard buildQueue(startingAtTrackIndex: startIndex, seekWithin: offsetWithinTrack) else {
            cannotPlay(String(localized: "Audiobook could not be loaded."))
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
            AppStorageKeys.float(AppStorageKeys.podcastShowRate($0))
        }
        playbackRate = AppStorageKeys.float(AppStorageKeys.playbackRate(item.id))
            ?? showRate
            ?? AppStorageKeys.defaultPlaybackRateValue
        updateCurrentChapter()
        updateNowPlayingInfo()
        updateWidgetSnapshot(force: true)
        startSyncTimer()
        syncStatus = .synced
        // Hint only when a state was actually adopted. For a fresh book (start
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
            await syncProgress(.restoreFlush)
        }
        if restart {
            // Deliberate replay from 0: write it through immediately (server +
            // iCloud/gpodder) and don't let the conflict guard flag the backward
            // jump. Starting over is intended, on every source.
            suppressConflictForNextSync = true
            await syncProgress(.restart)
        }

        // Load the cover for lock screen / Dynamic Island. The system shows both
        // automatically once MPNowPlayingInfoCenter has an artwork. No own Live
        // Activity needed.
        loadArtwork(coverURL: provider.coverURL(forItemId: item.id))
    }

    /// Says a notice (e.g. "adopted server position"). The coordinator's
    /// channel puts it in the log and decides whether and how long it shows.
    func showSourceHint(_ hint: SourceHint) {
        sourceHint = hint
    }

    // MARK: - Track-Verwaltung (Multi-Track)

    /// Cumulative start time (absolute seconds in the whole book) for a track
    /// index. Uses `startOffset` from the server if present, otherwise sums the
    /// individual durations itself.
    /// The music server song currently playing, of either server. Its
    /// server's song id, its absolute start within the album item, lookup
    /// metadata for lyrics, and the item id that names its server.
    var currentMusicSong: (id: String, start: Double, title: String?, artist: String?, duration: Double,
                           itemId: String)? {
        guard let id = item?.id, MusicSourceRule.isServerMusic(id),
              tracks.indices.contains(currentTrackIndex) else { return nil }
        let track = tracks[currentTrackIndex]
        return (track.contentUrl,
                trackAbsoluteStart(currentTrackIndex),
                currentChapter?.title,
                item?.media.metadata?.authorName,
                track.duration ?? 0,
                id)
    }

    /// The song this hearing entered into the listening history already
    /// (item and song id), so one hearing writes once.
    private var historyNotedSong: String?

    /// The listening history at the five second tick: a book whose
    /// position crossed into played, a server song past half of it or four
    /// minutes (`ListenHistory.songHeard`).
    private func noteListeningHistory(id: String, phaseBefore: ProgressMark.PlayState.Phase,
                                      phaseAfter: ProgressMark.PlayState.Phase) {
        let history = ListenHistory.shared
        if phaseAfter == .played, phaseBefore != .played,
           MediaFamily.booksTabMember(id, markedForm: ListeningStore.backup(id).flatMap(ProgressMark.markedForm)) {
            history.noteHeard(id: id, family: .book, title: item?.media.metadata?.title ?? "",
                              subtitle: item?.media.metadata?.authorName ?? "")
        }
        guard let song = currentMusicSong else { return }
        let step = ListenHistory.songHeard(song: "\(song.itemId)#\(song.id)", position: currentTime - song.start,
                                           duration: song.duration, noted: historyNotedSong)
        historyNotedSong = step.noted
        guard step.enter else { return }
        history.noteHeard(id: AppSession.shared.musicProvider(for: song.itemId).itemId(songId: song.id),
                          family: .music, title: song.title ?? "", subtitle: song.artist ?? "")
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
    /// only seek within the current item. For jumps across track boundaries
    /// (chapter, scrubber, device switch) the queue must be rebuilt.
    @discardableResult
    private func buildQueue(startingAtTrackIndex startIndex: Int, seekWithin: Double) -> Bool {
        guard startIndex >= 0, startIndex < tracks.count else { return false }
        // A new queue holds new items: a noted load failure is healed by it.
        loadFailureNoted = false

        // Cleanly tear down the old player and its observers.
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil
        if let observer = trackAdvanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        trackAdvanceObserver = nil
        heldAhead = nil
        for observer in itemStatusObservers { observer.invalidate() }
        itemStatusObservers.removeAll()

        let isRadio = self.item.map { ItemNamespace.isRadio($0.id) } == true
        var items: [AVPlayerItem] = []
        itemTrackIndex.removeAll()
        icyStreamTitle = nil   // never carry a song title across items
        icySongArtwork = nil   // nor its resolved cover
        stationArtwork = nil   // Teil 2: the next station loads its own logo
        for index in startIndex..<tracks.count {
            guard let url = resolveTrackURL(index: index) else { continue }
            if isRadio {
                // Persistent breadcrumb. A station that never plays leaves
                // the resolved stream URL and, below, its load error in the log.
                Logger.player.notice("radio play: building stream \(url.absoluteString, privacy: .public)")
            }
            // Decide per track: a partially downloaded book can mix local
            // files and streaming (auth header only makes sense remotely).
            let item: AVPlayerItem
            if url.isFileURL {
                item = AVPlayerItem(asset: AVURLAsset(url: url))
            } else {
                // The stream names the app like every other request. Measured
                // on eight hosts (archive.org, gutenberg.org, three live
                // stations, two podcast CDNs): none answers the app's name
                // differently from CoreMedia's, and the download of the same
                // episode already carried it.
                let headers = provider.streamAuthHeaders(forItemId: self.item?.id ?? "")
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers,
                                                          AVURLAssetHTTPUserAgentKey: AppUserAgent.value])
                item = AVPlayerItem(asset: asset)
            }
            // Live radio. Tap the in-stream ICY metadata (song title)
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
                // queue because AVPlayerItemMetadataOutput hands its delegate a DispatchQueue; the value hops into a Task at once.
                output.setDelegate(collector, queue: DispatchQueue(label: "fm.maer.app.icy"))
                item.add(output)
            }
            itemTrackIndex[ObjectIdentifier(item)] = index
            // Surface a load failure that never starts playback (ATS block,
            // dead stream, 404). Otherwise it stalls silently.
            // @Sendable: KVO fires on an arbitrary thread; an inheriting closure
            // would trap there under the MainActor default. Only
            // Sendable values (index, description) cross onto the main actor.
            let failedIndex = index
            let observation = item.observe(\.status, options: [.new]) { @Sendable [weak self] observedItem, _ in
                guard observedItem.status == .failed else { return }
                let description = observedItem.error.map { FailureReason.of($0) }
                    ?? observedItem.errorLog()?.events.last?.errorComment
                // The cause as the error tells it; the network's state is
                // asked on the main actor.
                let cause = NoticeCause.of(observedItem.error, online: true)
                let failedItem = ObjectIdentifier(observedItem)
                Task { @MainActor [weak self] in
                    self?.handleItemLoadFailure(trackIndex: failedIndex, item: failedItem,
                                                errorDescription: description, cause: cause)
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
        observeStalls(of: newPlayer)
        observeBookEnd(lastItem: items.last)

        if seekWithin > 0.5 {
            newPlayer.seek(to: CMTime(seconds: seekWithin, preferredTimescale: 1000))
        }
        if wasPlaying {
            newPlayer.rate = playbackRate
        }
        return true
    }

    /// Watches the new queue player for a wait on the stream. @Sendable: KVO
    /// fires on an arbitrary thread; only the Bool crosses onto the main actor.
    private func observeStalls(of newPlayer: AVQueuePlayer) {
        waitsOnTheStream = false
        stallObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] observed, _ in
            let waits = observed.timeControlStatus == .waitingToPlayAtSpecifiedRate
                && observed.reasonForWaitingToPlay == .toMinimizeStalls
            Task { @MainActor [weak self] in
                guard let self, self.waitsOnTheStream != waits else { return }
                self.waitsOnTheStream = waits
                Logger.player.notice("STALL \(waits ? "waiting on the stream" : "stream runs or paused", privacy: .public)")
            }
        }
    }

    /// Detects the BOOK end (last item finished): sync as finished immediately
    /// instead of waiting for the 30s timer. Track changes no longer need an
    /// observer. The index comes per tick from `itemTrackIndex`. A queue cut
    /// before a later track that failed to load ends at its held point instead.
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
                if let held = self.heldAhead {
                    self.stopAtHeldFailure(held)
                    return
                }
                self.currentTime = self.duration
                self.notePlayback("stopped", from: "item ended")
                self.isPlaying = false
                // Also mark finished locally. The sync writes it anyway;
                // otherwise the UI shows the wrong state after a fully played book.
                self.isFinished = true
                self.updateNowPlayingInfo()
                self.updateWidgetSnapshot(force: true)
                await self.syncProgress(.bookEnd)
                if let finishedId = self.item?.id {
                    self.onBookFinished?(finishedId)
                }
            }
        }
    }

    /// Finalize the current item as finished. Set the position to the end
    /// and the finished flag, so a following `stop()` (and its final sync) writes
    /// "finished" rather than the current position. Used when the user marks the
    /// ACTIVE item as played, mirroring a natural end.
    func finalizeAsFinished() {
        currentTime = duration
        isFinished = true
    }

    // MARK: - Playback

    /// Every start and every stop of playback names its caller in the
    /// log. Measured on two devices: playback stopped with no takeover
    /// line and no pause line, and nothing said who did it.
    func notePlayback(_ what: String, from caller: String) {
        Logger.player.notice("PLAYER \(what, privacy: .public) from=\(caller, privacy: .public) item=\(self.item?.id ?? "-", privacy: .private(mask: .hash)) at=\(Int(self.currentTime))")
        // Play, pause and stop are the events that create or move a
        // listening entry; the rows follow them on the next frame. A book's
        // moment is held by the library model, so it learns it first.
        if let id = item?.id, !PodcastCloudSync.potCarries(id), !ItemNamespace.isRadio(id) {
            AppSession.shared.libraryViewModel.noteLocalProgress(
                itemId: id, currentTime: currentTime, duration: duration, isFinished: false)
        }
        ListeningRevision.shared.bump("player \(what)")
    }

    func play(caller: String = #function) {
        notePlayback("play", from: caller)
        playbackStarts.send()
        // Playback is an EVENT. From here on the sync path may
        // write this item's local state.
        eventSinceLoad = true
        // Takeover contract: playing claims. The other device notices the
        // foreign claim and stands down by itself (no remote control).
        playbackStartedAtMs = Date().timeIntervalSince1970 * 1000
        standEpoch = ListeningStore.ownerEpoch()
        refreshClaim(forced: true)
        activateAudioSession()
        applySmartRewindIfNeeded()
        // A failed item plays nothing at any rate: build the queue first.
        rebuildIfLoadFailed()
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
    /// pauses in THIS session. After a relaunch the position is loaded
    /// fresh anyway. Not user-initiated: no immediate forced server write.
    private func applySmartRewindIfNeeded() {
        guard let pausedAt else { return }
        self.pausedAt = nil
        guard AppStorageKeys.smartRewindValue else { return }
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
    /// playing. Instead of starting from the old local state and overwriting the
    /// fresh progress.
    func playWithServerCheck() async {
        // Podcast/KVS half of the device switch: the freshest state of a
        // podcast episode lives in the iCloud blob, not behind
        // `reconcileWithServer`. One targeted pull, then adopt a newer mark
        // before playback starts. That is the takeover's "fetch the
        // freshest state" step for the classes without a progress server.
        if let item, PodcastCloudSync.potCarries(item.id) {
            // Pull only: a play is not a change of state, and the whole pot
            // beside the claim made the claim wait for the pot's upload.
            // For EVERY class whose stand lives in the pot: a catalogue book
            // used to start at the mark of the last full reconcile.
            PodcastCloudSync.shared.reconcile(changedId: item.id, pushing: false)
            if let mark = ListeningStore.mark(item.id),
               abs(mark.position - currentTime) > 2 {
                await seek(to: mark.position, userInitiated: false)
            }
        }
        // The takeover start for every source: the other device's claim
        // carries where it stood, refreshed every few seconds, and that is
        // fresher than any pot. Newer than the local mark wins.
        if let item {
            let nowMs = Date().timeIntervalSince1970 * 1000
            let claim = PlaybackClaimSync.shared.current
            if let claimed = PlaybackClaimRules.takeoverPosition(
                    claim: claim, itemId: item.id,
                    ownDeviceId: SyncHistoryStore.deviceId, nowMs: nowMs),
               (claim?.t ?? 0) >= (ListeningStore.mark(item.id)?.updatedAtMs ?? 0),
               abs(claimed - currentTime) > 2 {
                Logger.player.notice("CLAIM start-at item=\(item.id, privacy: .private(mask: .hash)) position=\(Int(claimed))")
                await seek(to: claimed, userInitiated: false)
            }
        }
        // Wait for the reconcile at most 1.5s. On a slow network (no immediate
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

    /// The claim with the current stand: on the carrier's heartbeat while
    /// playing, and at once on play, jump and chapter change. The other
    /// device starts where this one stood. The beat is the runner's
    /// question; the player only says whether an event forces it.
    func refreshClaim(forced: Bool) {
        guard let item else { return }
        // The play time rides on every write, heartbeats included: the
        // store delivers only the latest value of the key, so a flag on
        // the play write alone was gone before it arrived.
        PlaybackClaimSync.shared.claimIfDue(itemId: item.id, from: self,
                                            position: currentTime, duration: duration,
                                            title: nowPlayingTitle, playAt: playbackStartedAtMs,
                                            epoch: standEpoch, forced: forced)
    }

    /// The podcast state to the pot: at a deliberate occasion always, on
    /// the tick only at the carrier's cadence, which the runner knows.
    func sendStateToPot(deliberate: Bool) {
        guard let item, ItemNamespace.isPodcastEpisode(item.id) else { return }
        PodcastCloudSync.shared.sendState(changedId: item.id, deliberate: deliberate)
    }

    /// A change of account holds what plays. The stand of the running piece
    /// is recorded now, under the account it was played in (`standEpoch`),
    /// because the stock passes to the next account right after and the
    /// write of the pause comes only after the server's answer, under an
    /// epoch that no longer counts. Then it pauses, so nothing of it plays
    /// on into the next account. A piece paused whose record still waits for
    /// the server is recorded the same way; one whose record landed long ago
    /// is left alone, so it is never stamped anew.
    func holdForAccountSwitch() {
        guard AccountSwitchHold.records(isPlaying: isPlaying, pauseRecordPending: pauseRecordPending) else { return }
        if let id = item?.id {
            ListeningStore.record(id, position: currentTime, duration: duration,
                                  atMs: Date().timeIntervalSince1970 * 1000, epoch: standEpoch)
        }
        if isPlaying { pause(caller: "account switch") }
    }

    func pause(caller: String = #function) {
        notePlayback("pause", from: caller)
        let wasPlaying = isPlaying
        player?.pause()
        isPlaying = false
        pausedAt = Date()
        // Pausing withdraws the claim actively, with the final stand for
        // the device that takes over. The other device's hint line dies
        // in delivery seconds, the 90-s ageing stays the fallback for the
        // paths without a clean pause.
        if let item {
            PlaybackClaimSync.shared.release(itemId: item.id, position: currentTime,
                                             duration: duration, epoch: standEpoch)
        }
        updateNowPlayingInfo()
        updateWidgetSnapshot(force: true)
        ListeningStatsStore.shared.flush()
        Haptics.tap()
        // Only a pause of a running piece has a stand on its way; the run
        // of `syncProgress` that writes it clears the mark when it ends.
        if wasPlaying { pauseRecordPending = true }
        Task { await syncProgress(.pause) }
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
    ///   server immediately and without confirmation. Also backwards.
    func seek(to time: Double, userInitiated: Bool = true) async {
        guard !tracks.isEmpty else { return }
        let clamped = max(0, min(time, max(duration, 0)))
        let targetIndex = trackIndex(for: clamped)
        let offsetWithinTrack = max(0, clamped - trackAbsoluteStart(targetIndex))

        if targetIndex == currentTrackIndex, let player {
            // Jump stays within the currently loaded track.
            await player.seek(to: CMTime(seconds: offsetWithinTrack, preferredTimescale: 1000))
        } else {
            // Jump across a track boundary. Rebuild the queue.
            buildQueue(startingAtTrackIndex: targetIndex, seekWithin: offsetWithinTrack)
        }

        currentTime = clamped
        updateCurrentChapter()
        updateNowPlayingInfo()
        if userInitiated {
            // A DELIBERATE jump picks a new position. Smart Rewind must not
            // pull away from it when playback resumes after a long pause.
            pausedAt = nil
            eventSinceLoad = true
            suppressConflictForNextSync = true
            // The other device learns the jump at once, not at the next
            // heartbeat.
            if isPlaying { refreshClaim(forced: true) }
            await syncProgress(.seek)
        }
    }

    func skip(by seconds: Double) {
        Task { await seek(to: currentTime + seconds) }
    }

    /// Like `skip(by:)`, but intended only for jumps via the lock screen/control
    /// center. There is (unlike buttons in the app) no palm detection there. A
    /// skip command from your pocket can trigger unnoticed several times in a
    /// row. Only from several fast jumps in a short time does the detection kick
    /// in. A single deliberate lock-screen jump still goes through immediately,
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

    /// What the title keys of the app do for what is loaded; their action and
    /// their VoiceOver names both read it.
    var titleStep: RemoteCommandRule.AppStep {
        RemoteCommandRule.appStep(for: RemoteCommandRule.kind(forItem: item?.id))
    }

    /// The one entry for the title keys and the cover swipe in the app. The
    /// rule decides per press: a song takes the same title way as the
    /// remote, everything else turns chapters.
    func stepTitle(forward: Bool) {
        switch titleStep {
        case .title:
            Haptics.tap()
            jumpToAdjacentTrack(forward: forward)
        case .chapter:
            if forward { nextChapter() } else { previousChapter() }
        }
    }

    /// The real track change behind the song title buttons. The back edge
    /// is `RemoteCommandRule.back`: within the first seconds "previous"
    /// means the song before (across items, as in the system's music app),
    /// afterwards the start of this one.
    /// Returns whether anything will happen. A press that can do nothing
    /// must not read as success to the system.
    @discardableResult
    func jumpToAdjacentTrack(forward: Bool) -> Bool {
        guard !tracks.isEmpty else { return false }
        let withinTrack = currentTime - trackAbsoluteStart(currentTrackIndex)
        if forward {
            if currentTrackIndex + 1 < tracks.count {
                Task { await seek(to: trackAbsoluteStart(currentTrackIndex + 1)) }
                return true
            }
            // Last (or only) track: the QUEUE is the next thing. A single-song
            // item has one track, so the guard above failed on the MAIN case
            // of music listening (a shuffled playlist of songs) and the
            // press returned silently.
            return onQueueSkipRequested?() ?? false
        }
        switch RemoteCommandRule.back(withinTrack: withinTrack, trackIndex: currentTrackIndex,
                                      hasSongBefore: hasSongBefore?() ?? false) {
        case .startOfTrack:
            Task { await seek(to: trackAbsoluteStart(currentTrackIndex)) }
        case .previousTrack:
            Task { await seek(to: trackAbsoluteStart(currentTrackIndex - 1)) }
        case .songBefore:
            if onSongBeforeRequested?() != true { Task { await seek(to: 0) } }
        case .startOfItem:
            Task { await seek(to: 0) }
        }
        return true
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
            AppStorageKeys.set(rate, for: AppStorageKeys.playbackRate(item.id))
            // Choice family: "this title at 1.25×" is a content judgement.
            UserChoiceCloudSync.shared.noteScalar(
                key: AppStorageKeys.playbackRate(item.id), value: Double(rate))
        }
    }

    /// The habit of the loaded item: a song skips shorter than a book.
    var skipContent: PlaybackSkip.Content {
        PlaybackSkip.content(forItemId: item?.id ?? "")
    }

    /// The remembered width of the item's habit, applied on every load so a
    /// song after a book jumps ten seconds, and the book after it thirty.
    func applySkipInterval(forItemId id: String) {
        let seconds = PlaybackSkip.content(forItemId: id) == .music
            ? AppStorageKeys.musicSkipIntervalValue
            : AppStorageKeys.skipIntervalValue
        skipInterval = seconds
        updateRemoteSkipIntervals(seconds)
    }

    func setSkipInterval(_ seconds: Double) {
        skipInterval = seconds
        if skipContent == .music {
            AppStorageKeys.musicSkipIntervalValue = seconds
        } else {
            AppStorageKeys.skipIntervalValue = seconds
        }
        updateRemoteSkipIntervals(seconds)
    }

    /// The lock-screen buttons show the same width as the player.
    private func updateRemoteSkipIntervals(_ seconds: Double) {
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
                // would yank currentTime back to the track start. That was
                // the phantom "conflict detected" right after session restore.
                guard let currentItem = self.player?.currentItem,
                      currentItem.status == .readyToPlay else { return }
                let signpost = PerfSignpost.tick(playing: self.isPlaying)
                defer { signpost.end() }
                if let idx = self.itemTrackIndex[ObjectIdentifier(currentItem)] {
                    self.currentTrackIndex = idx
                }
                // Local listening stats: 1 s per tick while playing. The item
                // rides along so the same second can be seen per station/show
                // as well. One count, two views.
                if self.isPlaying {
                    ListeningStatsStore.shared.addSeconds(1, itemId: self.item?.id)
                }
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
                        // Persist the real duration into the episode model.
                        // Feeds without/with wrong itunes:duration otherwise
                        // never get a working played/remaining state in lists.
                        if let id = self.item?.id, ItemNamespace.isRSS(id),
                           assetSeconds.isFinite, assetSeconds > 0 {
                            PodcastSubscriptions.shared.updateEpisodeDuration(guid: id, duration: assetSeconds)
                        }
                    }
                }
                // Crash safety: keep the position locally. Throttled to every
                // 5s (UserDefaults writes aren't free). The loss window on crash
                // is thus at most ~5s instead of 30s.
                let now = Date().timeIntervalSince1970
                if self.isPlaying, now - self.lastLocalSaveAt >= 5, let id = self.item?.id {
                    self.lastLocalSaveAt = now
                    // The stock decides what a local state IS for this class:
                    // a live stream has no end to be at, so it gets no growing
                    // number that a later surface would read as progress.
                    // The tile counts and the sections read the play STATE,
                    // not the position: when this tick moves an episode from
                    // unplayed to in progress or across the played line, the
                    // podcast surfaces must recompute now, not at the next
                    // restart.
                    // The PHASE, not the state: an in-progress state carries
                    // the position and differs on every tick, which had the
                    // whole podcast tab recompute every five seconds.
                    let tail = PlayedTail.seconds(forItemId: id)
                    let phaseBefore = ProgressMark.state(stored: ListeningStore.backup(id), currentDuration: self.duration, tail: tail).phase
                    ListeningStore.record(id, position: self.currentTime,
                                          duration: self.duration, atMs: now * 1000, epoch: self.standEpoch)
                    let phaseAfter = ProgressMark.state(stored: ListeningStore.backup(id), currentDuration: self.duration, tail: tail).phase
                    self.noteListeningHistory(id: id, phaseBefore: phaseBefore, phaseAfter: phaseAfter)
                    if ItemNamespace.isPodcastEpisode(id), phaseAfter != phaseBefore {
                        PodcastProgressStore.shared.reload()
                        // A change of phase is one of the pot's occasions.
                        self.sendStateToPot(deliberate: true)
                    }
                    // Listen log: a podcast crossing its played threshold in
                    // normal playback lands in the show-independent history
                    // (cheap + idempotent; threshold logic stays in the store).
                    if let detail = self.item, ItemNamespace.isPodcastEpisode(detail.id) {
                        PodcastListenLog.shared.noteIfPlayed(
                            guid: detail.id, duration: detail.media.duration ?? 0,
                            episodeTitle: detail.media.metadata?.title ?? "",
                            showTitle: detail.media.metadata?.authorName ?? "",
                            feedURL: PodcastSubscriptions.shared.feedURL(forEpisodeId: detail.id) ?? "")
                    }
                    self.updateWidgetSnapshot()
                }
                // The heartbeat of the claim, decided by its own rule.
                if self.isPlaying { self.refreshClaim(forced: false) }
                self.updateCurrentChapter()
                self.updateNowPlayingInfo()
                // Download-on-play: save a feed-only episode of an ABS show to
                // the server after ~30 s (no-op if nothing is registered).
                PodcastServerSave.shared.playbackTick(itemId: self.item?.id, currentTime: self.currentTime)
                // Check the buffering status here too. Uses the same clean
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
    /// a track that CANNOT play any further would otherwise be silent.
    /// Player stalls, no error surfaces anywhere.
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
            forgetCatalogAnswer()
            return
        }
        trackRetryAttempts.insert(index)
        // Only drop the file when streaming can take over; offline the
        // retry re-reads the same file (it may fail transiently).
        if isOnline() { dropLocalFile(at: index) }
        let idx = trackIndex(for: currentTime)
        let rebuilt = buildQueue(
            startingAtTrackIndex: idx,
            seekWithin: max(0, currentTime - trackAbsoluteStart(idx))
        )
        if !rebuilt {
            notePlayback("stopped", from: "queue rebuild failed")
            isPlaying = false
            showSourceHint(.trackFailed)
            forgetCatalogAnswer()
        }
    }

    /// A local file that failed is dropped and fetched again in the
    /// background; until it is back, the track plays from the server. The
    /// one place for both failure paths, mid-play and at load.
    private func dropLocalFile(at index: Int) {
        guard let local = localTrackFiles[index] else { return }
        do {
            try FileManager.default.removeItem(at: local)
        } catch {
            // The download skips a track that is there, so a file left here
            // is not fetched again; the line says so.
            Logger.player.error("LOCAL failed track not removed index=\(index) reason=\(FailureReason.of(error), privacy: .public)")
        }
        localTrackFiles[index] = nil
        if let item, DownloadManager.shared.isDownloaded(itemId: item.id) {
            let provider = self.provider
            Task { await DownloadManager.shared.download(item: item, provider: provider, kind: nil) }
        }
    }

    /// Playback of a catalogue item failed visibly: its kept answer may
    /// describe a release that is gone, so the next start asks the network
    /// again and learns it.
    private func forgetCatalogAnswer() {
        guard let item, let identifier = FreeCatalog.archiveIdentifier(of: item.id) else { return }
        Task { await ArchiveOrgClient.forgetMetadata(identifier: identifier) }
    }

    /// An item whose asset never loads (`status == .failed`). The load failure
    /// path that FailedToPlayToEndTime doesn't cover (playback never started).
    /// Logs the error persistently; when the failed item is the one playing,
    /// playback stops with a hint instead of a silent stall, for every kind
    /// of item, and the next play builds the queue anew.
    private func handleItemLoadFailure(trackIndex index: Int, item failedItem: ObjectIdentifier,
                                       errorDescription: String?, cause errorCause: NoticeCause) {
        let isRadio = item.map { ItemNamespace.isRadio($0.id) } == true
        let cause = isOnline() ? errorCause : .network
        Logger.player.notice("play failed: item \(index) status .failed for \(self.item?.id ?? "?", privacy: .public) — \(errorDescription ?? "no error", privacy: .public)")
        let inCurrentQueue = itemTrackIndex[failedItem] != nil
        let fallback = inCurrentQueue && index >= currentTrackIndex && !isRadio
            ? FailedLoad.localFallback(fromLocalFile: localTrackFiles[index] != nil,
                                       retried: trackRetryAttempts.contains(index), online: isOnline())
            : .none
        if fallback == .stream {
            trackRetryAttempts.insert(index)
            dropLocalFile(at: index)
            Logger.player.notice("LOADFAIL local file dropped track=\(index), plays on from the server")
        }
        if FailedLoad.holdsAhead(failedIndex: index, currentIndex: currentTrackIndex,
                                 inCurrentQueue: inCurrentQueue, heldAt: heldAhead?.index) {
            holdAhead(at: index, then: fallback, cause: cause)
            return
        }
        guard FailedLoad.stopsPlayback(failedIndex: index, currentIndex: currentTrackIndex,
                                       inCurrentQueue: inCurrentQueue) else { return }
        if fallback == .stream {
            rebuildAtHeldPosition(reason: "local file")
            showSourceHint(.downloadUnreadable)
            return
        }
        loadFailureNoted = true
        notePlayback("stopped", from: isRadio ? "radio item failed" : "item failed to load")
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        showSourceHint(isRadio ? .streamFailed : Self.loadHint(fallback, cause: cause))
        forgetCatalogAnswer()
    }

    /// The hint of a stopped load failure: a download that cannot be read
    /// says so; every other failure carries its cause for the symbol.
    private static func loadHint(_ fallback: FailedLoad.LocalFallback, cause: NoticeCause) -> SourceHint {
        fallback == .unavailable ? .downloadUnreadableOffline : .loadFailed(cause)
    }

    /// A later track failed to load while an earlier one plays: the queue is
    /// cut before it, so nothing behind it plays. When the queue's last item
    /// ends, playback stops at the failed track's start like a failure of the
    /// playing item (mark, hint, the next play builds anew from there), or
    /// goes on from there when its local file was dropped for the server.
    private func holdAhead(at index: Int, then: FailedLoad.LocalFallback, cause: NoticeCause) {
        heldAhead = HeldPoint(index: index, then: then, cause: cause)
        guard let player else { return }
        for item in player.items() where (itemTrackIndex[ObjectIdentifier(item)] ?? -1) >= index {
            player.remove(item)
        }
        // What is left ends at the held point, not at the end of the book.
        // The last item left is the one before the failed track, or, when a
        // track between had no address, the one before that.
        let last = player.items().last
        observeBookEnd(lastItem: last)
        Logger.player.notice("LOADFAIL ahead track=\(index) queue ends before it, last=\(last.flatMap { self.itemTrackIndex[ObjectIdentifier($0)] } ?? -1)")
        // A late failure finds the queue waiting at the end of the track
        // before, its end signal already gone: no end will come, hold now.
        if FailedLoad.endHasPassed(position: last?.currentTime().seconds, duration: last?.duration.seconds),
           let held = heldAhead {
            Logger.player.notice("LOADFAIL ahead track=\(index) the track before has ended, holds now")
            stopAtHeldFailure(held)
        }
    }

    private func stopAtHeldFailure(_ held: HeldPoint) {
        guard heldAhead?.index == held.index else { return }
        let index = held.index
        // Asked again now: the network may have gone while the track before
        // played, and then nothing can take over.
        let then = FailedLoad.atFiring(held.then, online: isOnline())
        if then == .stream {
            currentTime = trackAbsoluteStart(index)
            let rebuilt = buildQueue(startingAtTrackIndex: index, seekWithin: 0)
            Logger.player.notice("LOADFAIL held track=\(index) plays on from the server ok=\(rebuilt)")
            if rebuilt {
                showSourceHint(.downloadUnreadable)
                return
            }
        }
        loadFailureNoted = true
        currentTrackIndex = index
        currentTime = trackAbsoluteStart(index)
        notePlayback("stopped", from: "later item failed to load")
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        showSourceHint(Self.loadHint(then, cause: isOnline() ? held.cause : .network))
        forgetCatalogAnswer()
    }

    /// Before a play: a queue whose current item failed to load is built
    /// anew. The position is the one this device holds, never one fetched
    /// for the rebuild, so the rebuild itself moves nobody back.
    private func rebuildIfLoadFailed() {
        let failed = player?.currentItem?.status == .failed
        guard FailedLoad.rebuildsBeforePlay(currentItemFailed: failed, noted: loadFailureNoted) else { return }
        rebuildAtHeldPosition(reason: "play")
    }

    /// The network path changed: a stopped load failure is built anew once
    /// the path carries, without starting playback.
    func rebuildAfterPathChange(_ path: MaerSyncPath) {
        guard FailedLoad.rebuildsOnPathChange(noted: loadFailureNoted, satisfied: path.satisfied) else { return }
        rebuildAtHeldPosition(reason: "network back")
    }

    private func rebuildAtHeldPosition(reason: String) {
        let index = trackIndex(for: currentTime)
        let rebuilt = buildQueue(startingAtTrackIndex: index,
                                 seekWithin: max(0, currentTime - trackAbsoluteStart(index)))
        Logger.player.notice("LOADFAIL rebuild reason=\(reason, privacy: .public) track=\(index) ok=\(rebuilt)")
    }

    /// Absolute book time where the currently playing track ends.
    /// Nil if unknown. Used by the "sleep until end of track" mode.
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
        // Only a chapter that actually CONTAINS the current time (validated
        // list). Nil in a gap/past the end → the player omits the chapter line.
        let newChapter = ChapterModel.current(at: currentTime, in: chapters)
        guard newChapter != currentChapter else { return }
        currentChapter = newChapter
    }

    // MARK: - Cleanup

    func stop(caller: String = #function) {
        notePlayback("stop", from: caller)
        ListeningStatsStore.shared.flush()
        // Session end withdraws the claim like a pause does.
        if isPlaying, let item {
            PlaybackClaimSync.shared.release(itemId: item.id, position: currentTime,
                                             duration: duration, epoch: standEpoch)
        }
        Task { await syncProgress(.stop) }
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
        heldAhead = nil
        for observer in itemStatusObservers { observer.invalidate() }
        itemStatusObservers.removeAll()
        stallObserver?.invalidate()
        stallObserver = nil
        waitsOnTheStream = false
        player = nil
        syncTask?.cancel()
        sleepTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}


/// ICY timed-metadata tap for live radio. AVFoundation calls the delegate
/// on OUR serial queue. Nonisolated by construction (a closure called off
/// the main actor must not inherit its isolation);
/// the value hops to the MainActor inside `onValue`.
private nonisolated final class ICYMetadataCollector: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let onValue: @Sendable (String) -> Void
    init(onValue: @escaping @Sendable (String) -> Void) { self.onValue = onValue }

    /// Hands the metadata items into the async load. `@unchecked Sendable`
    /// (Rule 5 exception) unchecked because `AVMetadataItem` is a reference type, but
    /// the items are transferred ONCE off the delegate's serial queue and never
    /// touched again there, and `load(_:)` is AVFoundation's designated async
    /// accessor. So there is no concurrent access.
    private struct ItemHandoff: @unchecked Sendable { let items: [AVMetadataItem] }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        let handoff = ItemHandoff(items: groups.flatMap(\.items))
        guard !handoff.items.isEmpty else { return }
        // `stringValue` is synchronous and iOS-16-deprecated. Load it
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
