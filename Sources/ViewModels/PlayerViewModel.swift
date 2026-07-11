import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {

    /// Wird angezeigt, wenn die App einen spürbar NIEDRIGEREN Fortschritt an den
    /// Server schreiben würde, als zuletzt gespeichert war. Das ist die zentrale
    /// Schutzmaßnahme gegen genau das Plappa-Problem (Reset auf 0).
    struct ServerConflict: Identifiable {
        let serverTime: Double
        let localTime: Double
        var id: Double { localTime }
    }

    /// Wird angezeigt, wenn mehrere schnelle Sprünge HINTEREINANDER über den
    /// Sperrbildschirm/das Kontrollzentrum kamen — typisches Muster für
    /// unbeabsichtigten Taschen-Kontakt, da iOS dort keine Handflächen-
    /// Erkennung hat. Betrifft ausschließlich Lockscreen-Sprünge, niemals
    /// Buttons innerhalb der App selbst.
    struct SuspiciousLockscreenJump: Identifiable {
        let beforeTime: Double
        let afterTime: Double
        var id: Double { afterTime }
    }

    /// Sichtbarer Sync-Status im Player — macht auf einen Blick klar, ob der
    /// aktuelle Fortschritt wirklich sicher gespeichert ist. Gerade weil diese
    /// App sich zentral über verlässlichen Sync definiert, soll das nicht im
    /// Verborgenen passieren.
    enum SyncStatus: Equatable {
        case synced
        /// Offline — liegt in der SyncQueue, wird automatisch nachgereicht.
        case queued
        /// Verbindung verloren, aktueller Stand noch NICHT geschrieben — es
        /// liegt aber (noch) nichts in der Queue (kein syncProgress-Fehlschlag).
        case offline
        /// Echter Fehler (kein reines Offline-Problem).
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

    /// Kurzer, transienter Hinweis (Icon + Text), woher der aktuelle Stand
    /// stammt bzw. wie er gesichert ist. Feste, geprüfte Beschriftungen statt
    /// freiem Text — wird als globale Glas-Pille angezeigt.
    enum SourceHint: Equatable {
        case saved
        case serverAdopted
        case localUsed
        case queued
        case offline
        case conflict
        case trackFailed

        var label: String {
            switch self {
            case .saved: return String(localized: "Progress saved")
            case .serverAdopted: return String(localized: "Adopted server position")
            case .localUsed: return String(localized: "Using local position")
            case .queued: return String(localized: "Offline — queued for sync")
            case .offline: return String(localized: "Offline — progress saved locally")
            case .conflict: return String(localized: "Conflict detected")
            case .trackFailed: return String(localized: "Playback error — track unavailable")
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
            }
        }
    }

    @Published var syncStatus: SyncStatus = .synced
    /// Kurzer Hinweis, woher der Fortschritt beim Öffnen kam — blendet sich
    /// nach ein paar Sekunden von selbst wieder aus.
    @Published var sourceHint: SourceHint?

    @Published var isPlaying = false
    /// Absolute Position im GESAMTEN Buch, in Sekunden — unabhängig davon, ob
    /// das Buch aus einer einzigen M4B-Datei oder mehreren Tracks besteht.
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var chapters: [ABSChapter] = []
    @Published var currentChapter: ABSChapter?
    @Published var playbackRate: Float = 1.0
    /// When the current pause started — basis for Smart Rewind on resume.
    private var pausedAt: Date?
    /// Skip-Intervall in Sekunden (15/30/60), app-weit gemerkt.
    @Published var skipInterval: Double =
        UserDefaults.standard.object(forKey: AppStorageKeys.skipInterval) as? Double ?? 30
    @Published var sleepTimerRemaining: TimeInterval?
    /// True, wenn der Sleep-Timer im "bis Kapitelende"-Modus läuft (für die
    /// Anzeige im Menü).
    @Published var sleepUntilChapterEnd = false
    /// True while the sleep timer runs in "until end of track" mode.
    @Published var sleepUntilTrackEnd = false
    @Published var errorMessage: String?
    @Published var pendingServerConflict: ServerConflict?
    @Published var suspiciousLockscreenJump: SuspiciousLockscreenJump?
    /// True, während der Player nachpuffert (z. B. nach kurzem Funkloch) —
    /// die View zeigt dann einen "Lädt…"-Zustand statt eines starren Fehlers.
    @Published var isBuffering = false
    /// Spiegelt, ob das Buch als abgeschlossen gilt (für den "Als gehört
    /// markieren"-Button, der sich dann in "Als ungehört markieren" ändert).
    @Published var isFinished = false

    /// AVQueuePlayer statt AVPlayer, damit mehrteilige Bücher (mehrere
    /// Audiodateien statt einer M4B) nahtlos nacheinander abgespielt werden
    /// können. Alle bestehenden AVPlayer-Aufrufe (rate, pause, ...)
    /// funktionieren unverändert, AVQueuePlayer ist eine Unterklasse.
    var player: AVQueuePlayer?
    private var timeObserverToken: Any?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    /// True if playback was running when an interruption (Siri, navigation
    /// prompt, phone call) began — resume once it ends.
    private var resumeAfterInterruption = false
    private var trackAdvanceObserver: NSObjectProtocol?
    private var trackFailureObserver: NSObjectProtocol?
    /// Track indices that already got their ONE automatic recovery attempt —
    /// guards against a rebuild loop on a persistently broken track.
    private var trackRetryAttempts: Set<Int> = []
    var sleepTask: Task<Void, Never>?
    var syncTask: Task<Void, Never>?

    let apiClient: APIClient
    var item: LibraryItemDetail?
    /// Called once when the book plays to its END (not on manual "mark
    /// finished") — the coordinator uses it for auto-play-next-in-series.
    var onBookFinished: ((String) -> Void)?
    var artworkImage: UIImage?

    /// Alle Tracks des Buchs, sortiert. Bei einem normalen M4B-Buch genau
    /// einer, bei mehrteiligen Büchern mehrere.
    private var tracks: [ABSAudioTrack] = []
    /// Index des Tracks, der gerade im Player aktiv ist.
    private var currentTrackIndex: Int = 0
    /// AVPlayerItem → Track-Index. Quelle der Wahrheit für die absolute
    /// Zeitrechnung: der Index wird pro Tick vom gerade spielenden Item
    /// ABGELEITET statt per Notification gezählt — verpasste/verspätete
    /// Track-Wechsel-Notifications können die Buchzeit so nicht mehr
    /// verfälschen (falscher Rückschritt → falscher Konflikt-Dialog).
    private var itemTrackIndex: [ObjectIdentifier: Int] = [:]
    /// Local files of a downloaded book, keyed by track index — strict
    /// mapping, immune to stray files in the folder.
    private var localTrackFiles: [Int: URL] = [:]

    /// True, während ein Write zum Server unterwegs ist.
    var syncInFlight = false
    /// Ein force-Sync kam an, während einer lief — danach einmal nachziehen.
    var syncFollowUpRequested = false

    /// Sekunden vor Timer-Ende, über die die Lautstärke sanft ausblendet —
    /// kein harter Stopp mitten im Satz.
    let sleepFadeDuration: Double = 8

    /// Letzter erfolgreich an den Server geschriebener Wert.
    var lastSyncedTime: Double = 0
    /// UserDefaults-Key der sekündlichen Positions-Sicherung dieses Buchs.
    /// Schließt das 30s-Verlustfenster bei Crash/Force-Quit: [Zeit, ms-Epoch].
    var localPositionKey: String? {
        item.map { AppStorageKeys.localPosition($0.id) }
    }

    /// Letzter Schreibzeitpunkt der lokalen Positions-Sicherung (Throttle).
    private var lastLocalSaveAt: TimeInterval = 0

    /// lastUpdate-Zeitstempel des zuletzt GESEHENEN Server-Eintrags (ms epoch).
    /// Ein neuerer Eintrag stammt von einem anderen Gerät (oder unserem
    /// eigenen Write) — Grundlage für den Geräte-Abgleich.
    var lastKnownServerUpdate: Double = 0
    /// Wird gesetzt, wenn der Nutzer BEWUSST gesprungen ist (Scrubber, Kapitel,
    /// ±30s, Lockscreen). Ein bewusster Sprung nach hinten ist legitim und löst
    /// keinen Warn-Dialog aus. Gefährlich ist nur ein Absacken OHNE Nutzeraktion
    /// (z. B. Player-Reset auf 0) — genau das Plappa-Szenario.
    var suppressConflictForNextSync = false

    /// Schwelle, ab der ein nicht vom Nutzer ausgelöster Rückschritt als
    /// verdächtig gilt.
    let suspiciousDropThreshold: Double = 120

    // MARK: - Taschen-Kontakt-Schutz für Lockscreen-Sprünge

    /// Zeitpunkte der letzten Sprünge über den Sperrbildschirm/das
    /// Kontrollzentrum — nur DIESER Pfad ist betroffen, nicht die Buttons in
    /// der App selbst (siehe `skipFromLockscreen`).
    private var recentLockscreenSkipTimestamps: [Date] = []
    /// Stand, bevor die aktuell laufende Sprung-Serie begann — der
    /// Rücksprungpunkt, falls sich die Serie als ungewollt herausstellt.
    private var lockscreenSkipBaseline: Double?
    /// Zeitfenster, in dem mehrere Sprünge als "eine Serie" gezählt werden.
    private let lockscreenSkipWindow: TimeInterval = 4
    /// Ab so vielen Sprüngen innerhalb des Zeitfensters gilt die Serie als
    /// verdächtig (typisches Taschen-Kontakt-Muster, kein bewusstes
    /// mehrfaches Antippen).
    private let lockscreenSkipSuspicionCount = 5

    init(apiClient: APIClient) {
        self.apiClient = apiClient
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
            if isPlaying { resumeAfterInterruption = true }
            // The system already halted the player — mirror it in our state
            // (also fixes the play/pause button showing the wrong icon).
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
        // Nur Kategorie setzen — setActive(true) erst beim tatsächlichen
        // Abspielen (play): sonst unterbricht schon das stille Wiederherstellen
        // der letzten Session beim App-Start die Musik anderer Apps.
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

    // MARK: - Laden

    /// - Parameter isOfflineFallback: true, wenn dieses Buch über den
    ///   Offline-Metadaten-Cache geöffnet wurde (Server nicht erreichbar),
    ///   statt über eine frische Serverantwort — steuert nur die kurze
    ///   "Fortgesetzt von …"-Anzeige, sonst identisches Verhalten.
    func load(item: LibraryItemDetail, isOfflineFallback: Bool = false) async {
        self.item = item
        chapters = item.media.chapters ?? []
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

        guard !sortedTracks.isEmpty else {
            errorMessage = String(localized: "No playable track found.")
            return
        }

        localTrackFiles = DownloadManager.shared.localTrackMap(forItemId: item.id)
        trackRetryAttempts.removeAll()
        observeTrackFailures()
        // Self-heal: a "downloaded" book with missing/corrupt tracks fetches
        // exactly those in the background (valid ones are skipped).
        if DownloadManager.shared.isDownloaded(itemId: item.id),
           localTrackFiles.count < sortedTracks.count,
           NetworkMonitor.shared.isConnected {
            let apiClient = self.apiClient
            Task { await DownloadManager.shared.download(item: item, apiClient: apiClient) }
        }

        // Kernregel beim Start: Serverstand gewinnt, nie bei 0 anfangen,
        // wenn der Server schon Fortschritt kennt.
        let serverProgress = item.userMediaProgress?.currentTime ?? 0
        let serverUpdateMs = item.userMediaProgress?.lastUpdate ?? 0
        var startTime = serverProgress
        var restoredFromLocal = false
        // Crash-Sicherung: Ist die sekündliche lokale Sicherung JÜNGER als der
        // Serverstand und weicht spürbar ab (App starb vor dem nächsten Sync),
        // dort fortsetzen und gleich nachreichen.
        if let saved = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double],
           saved.count == 2,
           SyncRules.shouldRestoreLocalPosition(
               savedTime: saved[0], savedAtMs: saved[1],
               serverTime: serverProgress, serverUpdateMs: serverUpdateMs
           ) {
            startTime = saved[0]
            restoredFromLocal = true
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
        isFinished = item.userMediaProgress?.isFinished ?? false
        // Remembered per-book speed; new books start at the default speed
        // from the settings instead of a hard 1.0.
        playbackRate = UserDefaults.standard.object(forKey: AppStorageKeys.playbackRate(item.id)) as? Float
            ?? (UserDefaults.standard.object(forKey: AppStorageKeys.defaultPlaybackRate) as? Float ?? 1.0)
        updateCurrentChapter()
        updateNowPlayingInfo()
        startSyncTimer()
        syncStatus = .synced
        // Hinweis nur, wenn wirklich ein Stand übernommen wurde — bei einem
        // frischen Buch (Start bei 0) wäre „Serverstand übernommen" irreführend.
        if isOfflineFallback || restoredFromLocal {
            showSourceHint(.localUsed)
        } else if serverProgress > 0 {
            showSourceHint(.serverAdopted)
        }
        if restoredFromLocal {
            // Wiederhergestellten Stand sofort nachreichen (offline → Queue).
            // Kein Konflikt-Dialog: der Stand war vor dem Crash gewollt.
            suppressConflictForNextSync = true
            await syncProgress(force: true)
        }

        // Cover fürs Lockscreen / die Dynamic Island laden. Das System zeigt
        // beide automatisch an, sobald MPNowPlayingInfoCenter ein Artwork
        // enthält — keine eigene Live Activity nötig.
        loadArtwork(coverURL: apiClient.coverURL(forItemId: item.id))
    }

    /// Zeigt einen kurzen Hinweis (z. B. „Serverstand übernommen“) und blendet
    /// ihn nach ein paar Sekunden von selbst wieder aus. Wird global über die
    /// Overlay-Pille angezeigt — unabhängig davon, ob man gerade in der
    /// Bibliothek, auf der Detailseite oder im vollen Player ist.
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

    /// Kumulative Startzeit (absolute Sekunden im Gesamtbuch) für einen
    /// Track-Index. Nutzt `startOffset` vom Server, falls vorhanden, sonst
    /// wird aus den Einzeldauern selbst aufsummiert.
    private func trackAbsoluteStart(_ index: Int) -> Double {
        TrackMath.trackStart(index: index, tracks: tracks, bookDuration: duration)
    }

    /// Findet den Track, in den eine absolute Buch-Zeit fällt.
    private func trackIndex(for absoluteTime: Double) -> Int {
        TrackMath.trackIndex(for: absoluteTime, tracks: tracks, bookDuration: duration)
    }

    private func resolveTrackURL(index: Int) -> URL? {
        if let local = localTrackFiles[index] {
            return local
        }
        guard index < tracks.count else { return nil }
        return apiClient.streamURL(forContentPath: tracks[index].contentUrl)
    }

    /// Baut die Wiedergabe-Queue neu auf, beginnend beim angegebenen Track,
    /// und springt innerhalb des ersten Tracks an die angegebene Stelle.
    /// Nötig, weil AVQueuePlayer nur innerhalb des aktuellen Items seeken
    /// kann — für Sprünge über Track-Grenzen hinweg (Kapitel, Scrubber,
    /// Geräte-Wechsel) muss die Queue neu aufgebaut werden.
    @discardableResult
    private func buildQueue(startingAtTrackIndex startIndex: Int, seekWithin: Double) -> Bool {
        guard startIndex >= 0, startIndex < tracks.count else { return false }

        // Alten Player und seine Beobachter sauber abbauen.
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil
        if let observer = trackAdvanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        trackAdvanceObserver = nil

        var items: [AVPlayerItem] = []
        itemTrackIndex.removeAll()
        for index in startIndex..<tracks.count {
            guard let url = resolveTrackURL(index: index) else { continue }
            // Decide per track: a partially downloaded book can mix local
            // files and streaming (auth header only makes sense remotely).
            let item: AVPlayerItem
            if url.isFileURL {
                item = AVPlayerItem(asset: AVURLAsset(url: url))
            } else {
                var headers: [String: String] = [:]
                if let token = apiClient.token, !token.isEmpty {
                    headers["Authorization"] = "Bearer \(token)"
                }
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                item = AVPlayerItem(asset: asset)
            }
            itemTrackIndex[ObjectIdentifier(item)] = index
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

    /// Erkennt das BUCH-Ende (letztes Item fertig): sofort als abgeschlossen
    /// syncen statt auf den 30s-Timer zu warten. Track-Wechsel brauchen keinen
    /// Beobachter mehr — der Index kommt pro Tick aus `itemTrackIndex`.
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
                // Auch lokal als abgeschlossen markieren — der Sync schreibt es
                // ohnehin; sonst zeigt die UI nach durchgehörtem Buch den
                // falschen Zustand.
                self.isFinished = true
                self.updateNowPlayingInfo()
                await self.syncProgress(force: true)
                if let finishedId = self.item?.id {
                    self.onBookFinished?(finishedId)
                }
            }
        }
    }

    // MARK: - Wiedergabe

    func play() {
        activateAudioSession()
        applySmartRewindIfNeeded()
        // Falls ein Sleep-Fade mittendrin unterbrochen wurde: volle Lautstärke.
        player?.volume = 1
        player?.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo()
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

    /// Startet die Wiedergabe, gleicht aber vorher kurz mit dem Server ab.
    /// Deckt den Geräte-Wechsel ab: Wenn du auf dem iPhone pausierst und
    /// Sekunden später auf dem iPad weiterhören willst, springt das iPad vor
    /// dem Abspielen auf den neueren Serverstand — statt vom alten lokalen
    /// Stand loszulaufen und den frischen Fortschritt zu überschreiben.
    func playWithServerCheck() async {
        // Abgleich max. 1,5s abwarten — bei zähem Netz (kein sofortiger
        // Offline-Fehler) soll der Play-Button nicht bis zum URLSession-
        // Timeout hängen. Läuft der Abgleich länger, startet die Wiedergabe
        // sofort; ein späteres Adopt springt dann während des Abspielens.
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

    /// - Parameter userInitiated: true bei allen bewussten Nutzeraktionen
    ///   (Scrubber, Kapitel, Skip, Lockscreen). Solche Sprünge werden sofort
    ///   und ohne Rückfrage an den Server geschrieben — auch nach hinten.
    func seek(to time: Double, userInitiated: Bool = true) async {
        guard !tracks.isEmpty else { return }
        let clamped = max(0, min(time, max(duration, 0)))
        let targetIndex = trackIndex(for: clamped)
        let offsetWithinTrack = max(0, clamped - trackAbsoluteStart(targetIndex))

        if targetIndex == currentTrackIndex, let player {
            // Sprung bleibt innerhalb des aktuell geladenen Tracks.
            await player.seek(to: CMTime(seconds: offsetWithinTrack, preferredTimescale: 1000))
        } else {
            // Sprung über eine Track-Grenze hinweg — Queue neu aufbauen.
            buildQueue(startingAtTrackIndex: targetIndex, seekWithin: offsetWithinTrack)
        }

        currentTime = clamped
        updateCurrentChapter()
        updateNowPlayingInfo()
        if userInitiated {
            suppressConflictForNextSync = true
            await syncProgress(force: true)
        }
    }

    func skip(by seconds: Double) {
        Task { await seek(to: currentTime + seconds) }
    }

    /// Wie `skip(by:)`, aber ausschließlich für Sprünge über den
    /// Sperrbildschirm/das Kontrollzentrum gedacht — dort gibt es (anders als
    /// bei Buttons in der App) keine Handflächen-Erkennung. Ein Skip-Befehl
    /// aus der Hosentasche kann sich unbemerkt mehrfach hintereinander
    /// auslösen. Erst ab mehreren schnellen Sprüngen in kurzer Zeit greift
    /// die Erkennung — ein einzelner, bewusster Lockscreen-Sprung läuft
    /// unverändert sofort durch, ganz ohne Rückfrage.
    func skipFromLockscreen(by seconds: Double) {
        let now = Date()
        recentLockscreenSkipTimestamps.removeAll { now.timeIntervalSince($0) > lockscreenSkipWindow }
        if recentLockscreenSkipTimestamps.isEmpty {
            lockscreenSkipBaseline = currentTime
        }
        recentLockscreenSkipTimestamps.append(now)

        if recentLockscreenSkipTimestamps.count > lockscreenSkipSuspicionCount {
            // Schwelle überschritten: diesen weiteren Sprung nicht mehr
            // automatisch ausführen, stattdessen einmal nachfragen, ob die
            // ganze Serie wirklich gewollt war.
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

    /// Springt zum vorherigen Kapitel. Bei mehr als 3 Sekunden im aktuellen
    /// Kapitel wird erst an dessen Anfang gesprungen (wie in Musik-/Podcast-
    /// Apps üblich), erst ein weiterer Druck geht ein Kapitel zurück.
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
        // Pro Buch merken.
        if let item {
            UserDefaults.standard.set(rate, forKey: AppStorageKeys.playbackRate(item.id))
        }
    }

    func setSkipInterval(_ seconds: Double) {
        skipInterval = seconds
        UserDefaults.standard.set(seconds, forKey: AppStorageKeys.skipInterval)
        // Lockscreen-Buttons sofort nachziehen.
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
                // Absolute Buch-Zeit = Start des aktuellen Tracks + Position
                // innerhalb dieses Tracks.
                let newTime = self.trackAbsoluteStart(self.currentTrackIndex) + seconds
                self.currentTime = newTime
                // Crash-Sicherung: Position lokal festhalten — auf alle 5s
                // gedrosselt (UserDefaults-Writes sind nicht gratis). Das
                // Verlustfenster bei Crash beträgt damit max. ~5s statt 30s.
                let now = Date().timeIntervalSince1970
                if self.isPlaying, now - self.lastLocalSaveAt >= 5, let key = self.localPositionKey {
                    self.lastLocalSaveAt = now
                    UserDefaults.standard.set([self.currentTime, now * 1000], forKey: key)
                }
                self.updateCurrentChapter()
                self.updateNowPlayingInfo()
                // Buffering-Status gleich mitprüfen — nutzt denselben sauberen
                // MainActor-Kontext, kein separater KVO-Observer nötig.
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
                let apiClient = self.apiClient
                Task { await DownloadManager.shared.download(item: item, apiClient: apiClient) }
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
        currentChapter = chapters.last(where: { currentTime >= $0.start })
    }

    // MARK: - Aufräumen

    func stop() {
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
        player = nil
        syncTask?.cancel()
        sleepTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
