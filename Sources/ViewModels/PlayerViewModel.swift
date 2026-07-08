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
            case .synced: return "Synchronisiert"
            case .queued: return "Offline — wird nachgereicht"
            case .offline: return "Offline"
            case .failed: return "Sync fehlgeschlagen"
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

        var label: String {
            switch self {
            case .saved: return "Fortschritt gesichert"
            case .serverAdopted: return "Serverstand übernommen"
            case .localUsed: return "Lokaler Stand verwendet"
            case .queued: return "Offline — wird nachgereicht"
            case .offline: return "Offline — Fortschritt wird lokal gemerkt"
            case .conflict: return "Konflikt erkannt"
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
    /// Skip-Intervall in Sekunden (15/30/60), app-weit gemerkt.
    @Published var skipInterval: Double =
        UserDefaults.standard.object(forKey: "skipInterval") as? Double ?? 30
    @Published var sleepTimerRemaining: TimeInterval?
    /// True, wenn der Sleep-Timer im "bis Kapitelende"-Modus läuft (für die
    /// Anzeige im Menü).
    @Published var sleepUntilChapterEnd = false
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
    private var player: AVQueuePlayer?
    private var timeObserverToken: Any?
    private var trackAdvanceObserver: NSObjectProtocol?
    private var sleepTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private let apiClient: APIClient
    private var item: LibraryItemDetail?
    private var artworkImage: UIImage?

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
    /// Lokale Dateien, falls das Buch heruntergeladen ist — ein Eintrag pro
    /// Track, in derselben Reihenfolge wie `tracks`.
    private var localTrackFiles: [URL]?

    /// Letzter erfolgreich an den Server geschriebener Wert.
    private var lastSyncedTime: Double = 0
    /// UserDefaults-Key der sekündlichen Positions-Sicherung dieses Buchs.
    /// Schließt das 30s-Verlustfenster bei Crash/Force-Quit: [Zeit, ms-Epoch].
    private var localPositionKey: String? {
        item.map { "localPosition.\($0.id)" }
    }

    /// lastUpdate-Zeitstempel des zuletzt GESEHENEN Server-Eintrags (ms epoch).
    /// Ein neuerer Eintrag stammt von einem anderen Gerät (oder unserem
    /// eigenen Write) — Grundlage für den Geräte-Abgleich.
    private var lastKnownServerUpdate: Double = 0
    /// Wird gesetzt, wenn der Nutzer BEWUSST gesprungen ist (Scrubber, Kapitel,
    /// ±30s, Lockscreen). Ein bewusster Sprung nach hinten ist legitim und löst
    /// keinen Warn-Dialog aus. Gefährlich ist nur ein Absacken OHNE Nutzeraktion
    /// (z. B. Player-Reset auf 0) — genau das Plappa-Szenario.
    private var suppressConflictForNextSync = false

    /// Schwelle, ab der ein nicht vom Nutzer ausgelöster Rückschritt als
    /// verdächtig gilt.
    private let suspiciousDropThreshold: Double = 120

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
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = "Audiosession konnte nicht aktiviert werden: \(error.localizedDescription)"
        }
    }

    deinit {
        // Falls die Session nicht über stop() beendet wurde: den auf ein
        // AVPlayerItem gebundenen Track-Wechsel-Beobachter entfernen, damit kein
        // block-basierter Beobachter im NotificationCenter zurückbleibt.
        if let trackAdvanceObserver {
            NotificationCenter.default.removeObserver(trackAdvanceObserver)
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
        let sortedTracks = (item.media.tracks ?? []).sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        tracks = sortedTracks
        duration = item.media.duration ?? sortedTracks.reduce(0) { $0 + ($1.duration ?? 0) }

        guard !sortedTracks.isEmpty else {
            errorMessage = "Kein abspielbarer Track gefunden."
            return
        }

        localTrackFiles = DownloadManager.shared.localFileURLs(forItemId: item.id)

        // Kernregel beim Start: Serverstand gewinnt, nie bei 0 anfangen,
        // wenn der Server schon Fortschritt kennt.
        let serverProgress = item.userMediaProgress?.currentTime ?? 0
        let serverUpdateMs = item.userMediaProgress?.lastUpdate ?? 0
        var startTime = serverProgress
        var restoredFromLocal = false
        // Crash-Sicherung: Ist die sekündliche lokale Sicherung JÜNGER als der
        // Serverstand und weicht spürbar ab (App starb vor dem nächsten Sync),
        // dort fortsetzen und gleich nachreichen.
        if let saved = UserDefaults.standard.array(forKey: "localPosition.\(item.id)") as? [Double],
           saved.count == 2, saved[1] > serverUpdateMs, abs(saved[0] - serverProgress) > 5 {
            startTime = saved[0]
            restoredFromLocal = true
        }
        let startIndex = trackIndex(for: startTime)
        let offsetWithinTrack = max(0, startTime - trackAbsoluteStart(startIndex))

        guard buildQueue(startingAtTrackIndex: startIndex, seekWithin: offsetWithinTrack) else {
            errorMessage = "Hörbuch konnte nicht geladen werden."
            return
        }

        setupRemoteCommandCenter()
        lastSyncedTime = serverProgress
        lastKnownServerUpdate = serverUpdateMs
        currentTime = startTime
        isFinished = item.userMediaProgress?.isFinished ?? false
        // Gemerkte Wiedergabegeschwindigkeit dieses Buchs übernehmen.
        playbackRate = UserDefaults.standard.object(forKey: "playbackRate.\(item.id)") as? Float ?? 1.0
        updateCurrentChapter()
        updateNowPlayingInfo()
        startSyncTimer()
        syncStatus = .synced
        showSourceHint((isOfflineFallback || restoredFromLocal) ? .localUsed : .serverAdopted)
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
    private func showSourceHint(_ hint: SourceHint) {
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
        guard index >= 0, index < tracks.count else { return duration }
        if let offset = tracks[index].startOffset { return offset }
        return tracks[..<index].reduce(0) { $0 + ($1.duration ?? 0) }
    }

    /// Findet den Track, in den eine absolute Buch-Zeit fällt.
    private func trackIndex(for absoluteTime: Double) -> Int {
        for index in tracks.indices {
            let start = trackAbsoluteStart(index)
            let end = start + (tracks[index].duration ?? 0)
            if absoluteTime < end || index == tracks.count - 1 {
                return index
            }
        }
        return 0
    }

    private func resolveTrackURL(index: Int) -> URL? {
        if let localFiles = localTrackFiles, index < localFiles.count {
            return localFiles[index]
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

        let isLocal = localTrackFiles != nil
        var items: [AVPlayerItem] = []
        itemTrackIndex.removeAll()
        for index in startIndex..<tracks.count {
            guard let url = resolveTrackURL(index: index) else { continue }
            let item: AVPlayerItem
            if isLocal {
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
                self.updateNowPlayingInfo()
                await self.syncProgress(force: true)
            }
        }
    }

    private func loadArtwork(coverURL: URL?) {
        guard let coverURL else { return }
        Task { [weak self] in
            guard let image = await Self.loadImage(for: coverURL) else { return }
            await MainActor.run {
                self?.artworkImage = image
                self?.updateNowPlayingInfo()
            }
        }
    }

    /// Lädt das Cover für den Lockscreen/die Dynamic Island — nutzt denselben
    /// geteilten Cache wie die Bibliothek und versucht bei Fehlschlag einmal
    /// automatisch erneut.
    private static func loadImage(for url: URL) async -> UIImage? {
        if let cached = ImageCache.shared.image(for: url) {
            return cached
        }
        if let (image, data) = await fetchImage(url) {
            ImageCache.shared.set(image, data: data, for: url)
            return image
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let (image, data) = await fetchImage(url) {
            ImageCache.shared.set(image, data: data, for: url)
            return image
        }
        return nil
    }

    private static func fetchImage(_ url: URL) async -> (UIImage, Data)? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        return (image, data)
    }

    /// Setzt das Buch serverseitig auf "abgeschlossen" bzw. hebt das wieder auf.
    func toggleFinished() async {
        guard let item else { return }
        // Denselben In-Flight-Guard respektieren wie syncProgress — sonst kann
        // dieser Write einen laufenden Positions-Write im Netz überholen.
        while syncInFlight {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        syncInFlight = true
        defer { syncInFlight = false }

        let target = !isFinished
        // Gehört markieren setzt den Fortschritt explizit ans Buchende;
        // Rückgängig behält den aktuellen Stand und kippt nur das Flag.
        let writeTime = target ? duration : currentTime
        do {
            try await apiClient.updateProgress(
                itemId: item.id,
                currentTime: writeTime,
                duration: duration,
                isFinished: target
            )
            SyncQueue.shared.remove(itemId: item.id)
        } catch {
            // Nutzer-Statusentscheidung nicht verlieren: queuen, lokal
            // trotzdem übernehmen — der Flush reicht sie nach.
            SyncQueue.shared.enqueue(
                itemId: item.id,
                currentTime: writeTime,
                duration: duration,
                isFinished: target
            )
            if NetworkStatus.isOfflineError(error) {
                if syncStatus != .queued { showSourceHint(.queued) }
                syncStatus = .queued
            } else {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                syncStatus = .failed
            }
        }
        isFinished = target
        if target {
            // Lokalen Zustand angleichen: ans Buchende springen und Sync-Stand
            // nachziehen — sonst schriebe der periodische Sync gleich wieder
            // den alten Stand mit isFinished=false.
            await seek(to: duration, userInitiated: false)
            lastSyncedTime = duration
        } else {
            lastSyncedTime = currentTime
        }
    }

    // MARK: - Wiedergabe

    func play() {
        player?.rate = playbackRate
        isPlaying = true
        updateNowPlayingInfo()
        Haptics.tap()
    }

    /// Startet die Wiedergabe, gleicht aber vorher kurz mit dem Server ab.
    /// Deckt den Geräte-Wechsel ab: Wenn du auf dem iPhone pausierst und
    /// Sekunden später auf dem iPad weiterhören willst, springt das iPad vor
    /// dem Abspielen auf den neueren Serverstand — statt vom alten lokalen
    /// Stand loszulaufen und den frischen Fortschritt zu überschreiben.
    func playWithServerCheck() async {
        await reconcileWithServer()
        play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
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
            UserDefaults.standard.set(rate, forKey: "playbackRate.\(item.id)")
        }
    }

    func setSkipInterval(_ seconds: Double) {
        skipInterval = seconds
        UserDefaults.standard.set(seconds, forKey: "skipInterval")
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
                // Track-Index direkt vom gerade spielenden Item ableiten —
                // immer korrekt, auch wenn der Player mehrfach weitersprang.
                if let item = self.player?.currentItem,
                   let idx = self.itemTrackIndex[ObjectIdentifier(item)] {
                    self.currentTrackIndex = idx
                }
                // Absolute Buch-Zeit = Start des aktuellen Tracks + Position
                // innerhalb dieses Tracks.
                self.currentTime = self.trackAbsoluteStart(self.currentTrackIndex) + seconds
                // Crash-Sicherung: Position sekündlich lokal festhalten.
                if self.isPlaying, let key = self.localPositionKey {
                    UserDefaults.standard.set(
                        [self.currentTime, Date().timeIntervalSince1970 * 1000],
                        forKey: key
                    )
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

    private func updateCurrentChapter() {
        currentChapter = chapters.last(where: { currentTime >= $0.start })
    }

    // MARK: - Sync (die eigentliche Existenzberechtigung der App)

    private func startSyncTimer() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await self.syncProgress(force: false)
            }
        }
    }

    /// True, während ein Write zum Server unterwegs ist.
    private var syncInFlight = false
    /// Ein force-Sync kam an, während einer lief — danach einmal nachziehen.
    private var syncFollowUpRequested = false

    /// Schreibt den Fortschritt an den Server. Reentrancy-sicher: Es ist nie
    /// mehr als ein Write gleichzeitig unterwegs — parallele Writes könnten
    /// sich im Netz überholen und der ältere Stand würde gewinnen.
    /// - Parameter force: erzwingt einen Sync auch ohne die 5-Sekunden-Schwelle
    ///   (z. B. bei Pause oder wenn die App in den Hintergrund geht).
    func syncProgress(force: Bool) async {
        if syncInFlight {
            // Timer-Ticks verwerfen (der nächste kommt eh); bewusste Syncs
            // (Pause/Seek) nach Abschluss einmal mit frischem Stand nachziehen.
            if force { syncFollowUpRequested = true }
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }

        var runForce = force
        repeat {
            syncFollowUpRequested = false
            await performSync(force: runForce)
            runForce = true
        } while syncFollowUpRequested
    }

    private func performSync(force: Bool) async {
        guard let item else { return }
        guard force || abs(currentTime - lastSyncedTime) >= 5 else { return }

        // Kernregel: Ein Rückschritt, den der Nutzer NICHT selbst ausgelöst hat,
        // wird nie stillschweigend geschrieben.
        if !suppressConflictForNextSync, currentTime < lastSyncedTime - suspiciousDropThreshold {
            if pendingServerConflict == nil {
                pendingServerConflict = ServerConflict(serverTime: lastSyncedTime, localTime: currentTime)
                showSourceHint(.conflict)
            }
            return
        }

        let isFinishedNow = duration > 0 && currentTime >= duration - 1
        do {
            try await apiClient.updateProgress(
                itemId: item.id,
                currentTime: currentTime,
                duration: duration,
                isFinished: isFinishedNow
            )
            lastSyncedTime = currentTime
            suppressConflictForNextSync = false
            SyncQueue.shared.remove(itemId: item.id)
            // Server hat den Stand — lokale Crash-Sicherung ist damit erledigt.
            if let key = localPositionKey {
                UserDefaults.standard.removeObject(forKey: key)
            }
            // Nur Übergänge melden (kein 30s-Spam): offline/queued/failed → gesichert.
            if syncStatus != .synced {
                showSourceHint(.saved)
            }
            syncStatus = .synced
        } catch {
            if NetworkStatus.isOfflineError(error) {
                // Erwartbar, kein echter Fehler: kein Netz gerade, z. B. auf
                // Reisen. Den aktuellen Stand in die Offline-Queue legen,
                // damit er auch einen App-Kill übersteht, statt verloren zu
                // gehen — beim nächsten Start bzw. bei Wiederverbindung wird
                // sie automatisch geleert (siehe SyncQueue).
                SyncQueue.shared.enqueue(
                    itemId: item.id,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinishedNow
                )
                errorMessage = nil
                if syncStatus != .queued { showSourceHint(.queued) }
                syncStatus = .queued
            } else {
                // Ein echter Fehler (z. B. abgelaufener Token, Serverproblem) —
                // sichtbar machen, aber den Stand trotzdem queuen: sonst wäre
                // er verloren, wenn die App vor dem nächsten Versuch beendet
                // wird. Der Flush reconciled ohnehin gegen den Server.
                SyncQueue.shared.enqueue(
                    itemId: item.id,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: isFinishedNow
                )
                errorMessage = "Sync fehlgeschlagen: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                syncStatus = .failed
            }
        }
    }

    /// Verbindung ging verloren, während gerade abgespielt wird: den sichtbaren
    /// Sync-Status sofort auf "offline" setzen, statt bis zum nächsten
    /// Sync-Tick (alle 30s) zu warten. Es wird bewusst NICHTS in die Queue
    /// gelegt — das geschieht weiterhin nur, wenn ein echter
    /// syncProgress-Versuch fehlschlägt.
    func markConnectionLostWhilePlaying() {
        guard isPlaying, syncStatus == .synced else { return }
        syncStatus = .offline
        showSourceHint(.offline)
    }

    /// Nach einem Flush der Offline-Queue aufrufen: Wurde der eigene Eintrag
    /// erfolgreich nachgereicht, den sichtbaren Status von .queued auf .synced
    /// nachziehen — sonst bliebe der "wird nachgereicht"-Hinweis bis zum
    /// nächsten Sync-Tick stehen, obwohl längst synchronisiert.
    func updateSyncStatusFromQueue() {
        guard let item, syncStatus != .synced else { return }
        if !SyncQueue.shared.hasPendingUpdate(itemId: item.id) {
            if syncStatus == .queued || syncStatus == .failed { showSourceHint(.saved) }
            syncStatus = .synced
        }
    }

    /// Nutzer hat im Dialog bestätigt: den niedrigeren Stand wirklich schreiben.
    func confirmLowerProgress() async {
        suppressConflictForNextSync = true
        pendingServerConflict = nil
        await syncProgress(force: true)
    }

    /// Nutzer hat abgebrochen: zurück zum zuletzt gespeicherten Serverstand
    /// springen, damit der Konflikt aufgelöst ist und nicht erneut aufpoppt.
    func cancelAndRestoreServerPosition() {
        pendingServerConflict = nil
        Task { await seek(to: lastSyncedTime, userInitiated: false) }
    }

    func dismissLowerProgressConflict() {
        pendingServerConflict = nil
    }

    /// Nutzer hat im Dialog bestätigt: die Sprung-Serie war wirklich gewollt,
    /// aktuellen (weiter vorne liegenden) Stand sofort synchronisieren.
    func confirmLockscreenJump() async {
        suspiciousLockscreenJump = nil
        suppressConflictForNextSync = true
        await syncProgress(force: true)
    }

    /// Nutzer hat abgebrochen: zurück zum Stand vor Beginn der Sprung-Serie
    /// springen — vermutlich Taschen-Kontakt, nicht gewollt.
    func cancelLockscreenJump() {
        guard let jump = suspiciousLockscreenJump else { return }
        suspiciousLockscreenJump = nil
        Task { await seek(to: jump.beforeTime, userInitiated: false) }
    }

    func dismissLockscreenJump() {
        suspiciousLockscreenJump = nil
    }

    // MARK: - Sleep-Timer

    func startSleepTimer(minutes: Double) {
        sleepTask?.cancel()
        sleepUntilChapterEnd = false
        sleepTimerRemaining = minutes * 60
        sleepTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                guard var remaining = self.sleepTimerRemaining else { break }
                remaining -= 1
                self.sleepTimerRemaining = remaining
                if remaining <= 0 {
                    self.pause()
                    self.sleepTimerRemaining = nil
                    break
                }
            }
        }
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTimerRemaining = nil
        sleepUntilChapterEnd = false
    }

    /// Sleep-Timer bis zum Ende des aktuellen Kapitels. Statt fester Minuten
    /// läuft die Wiedergabe bis zur Kapitelgrenze und pausiert dann.
    func startSleepTimerUntilChapterEnd() {
        sleepTask?.cancel()
        guard let chapter = currentChapter else {
            sleepUntilChapterEnd = false
            return
        }
        sleepUntilChapterEnd = true
        let end = chapter.end
        sleepTimerRemaining = max(end - currentTime, 0)
        sleepTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                let remaining = max(end - self.currentTime, 0)
                self.sleepTimerRemaining = remaining
                if remaining <= 0 {
                    self.pause()
                    self.sleepTimerRemaining = nil
                    self.sleepUntilChapterEnd = false
                    break
                }
            }
        }
    }

    // MARK: - Lockscreen / Now Playing

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skipFromLockscreen(by: self.skipInterval)
            }
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skipFromLockscreen(by: -self.skipInterval)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item?.media.metadata?.title ?? "Hörbuch"
        info[MPMediaItemPropertyArtist] = item?.media.metadata?.authorName ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Wird aufgerufen, wenn die App wieder in den Vordergrund kommt. Deckt den
    /// Fall ab, dass zwischenzeitlich auf einem anderen Gerät weitergehört
    /// wurde, während diese App-Instanz nur im Hintergrund lag (nicht beendet).
    /// Übernimmt den Serverstand NUR, wenn er weiter ist als die lokale
    /// Position — nie umgekehrt, das würde eigenen Fortschritt verwerfen.
    func reconcileWithServer() async {
        guard let item else { return }
        do {
            let fresh = try await apiClient.fetchItemDetail(itemId: item.id)
            let serverTime = fresh.userMediaProgress?.currentTime ?? 0
            let serverUpdate = fresh.userMediaProgress?.lastUpdate ?? 0
            // Neuerer Server-Eintrag als der zuletzt gesehene + abweichende
            // Position → anderes Gerät hat geschrieben. Übernehmen — auch
            // RÜCKWÄRTS (bewusstes Zurückspulen dort ist gewollt). Nach
            // eigenem Write ist serverTime ≈ currentTime → kein Sprung.
            // Fallback ohne lastUpdate (alte Server): nur vorwärts wie bisher.
            let isNewer = serverUpdate > lastKnownServerUpdate
            let adopt = serverUpdate > 0
                ? (isNewer && abs(serverTime - currentTime) > 5)
                : serverTime > currentTime + 5
            if adopt {
                await seek(to: serverTime, userInitiated: false)
                lastSyncedTime = serverTime
                showSourceHint(.serverAdopted)
            }
            // Auch das Abschluss-Flag vom neueren Eintrag übernehmen — z. B.
            // auf einem anderen Gerät als (un)gehört markiert.
            if isNewer, let serverFinished = fresh.userMediaProgress?.isFinished,
               serverFinished != isFinished {
                isFinished = serverFinished
            }
            lastKnownServerUpdate = max(lastKnownServerUpdate, serverUpdate)
            syncStatus = .synced
        } catch {
            // Kein Netz o.ä.: einfach mit dem lokalen Stand weitermachen,
            // kein Abbruch der Wiedergabe wegen eines Abgleich-Fehlers.
        }
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
        player = nil
        syncTask?.cancel()
        sleepTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
