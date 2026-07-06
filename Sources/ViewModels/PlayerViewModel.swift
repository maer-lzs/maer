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
        /// Echter Fehler (kein reines Offline-Problem).
        case failed

        var label: String {
            switch self {
            case .synced: return "Synchronisiert"
            case .queued: return "Offline — wird nachgereicht"
            case .failed: return "Sync fehlgeschlagen"
            }
        }

        var systemImage: String {
            switch self {
            case .synced: return "checkmark.icloud"
            case .queued: return "icloud.and.arrow.up"
            case .failed: return "exclamationmark.icloud"
            }
        }
    }

    @Published var syncStatus: SyncStatus = .synced
    /// Kurzer Hinweis, woher der Fortschritt beim Öffnen kam (Server, Offline-
    /// Cache) — blendet sich nach ein paar Sekunden von selbst wieder aus.
    @Published var resumeSourceMessage: String?

    @Published var isPlaying = false
    /// Absolute Position im GESAMTEN Buch, in Sekunden — unabhängig davon, ob
    /// das Buch aus einer einzigen M4B-Datei oder mehreren Tracks besteht.
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var chapters: [ABSChapter] = []
    @Published var currentChapter: ABSChapter?
    @Published var playbackRate: Float = 1.0
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
    /// Lokale Dateien, falls das Buch heruntergeladen ist — ein Eintrag pro
    /// Track, in derselben Reihenfolge wie `tracks`.
    private var localTrackFiles: [URL]?

    /// Letzter erfolgreich an den Server geschriebener Wert.
    private var lastSyncedTime: Double = 0
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
        let startIndex = trackIndex(for: serverProgress)
        let offsetWithinTrack = max(0, serverProgress - trackAbsoluteStart(startIndex))

        guard buildQueue(startingAtTrackIndex: startIndex, seekWithin: offsetWithinTrack) else {
            errorMessage = "Hörbuch konnte nicht geladen werden."
            return
        }

        setupRemoteCommandCenter()
        lastSyncedTime = serverProgress
        currentTime = serverProgress
        isFinished = item.userMediaProgress?.isFinished ?? false
        updateCurrentChapter()
        updateNowPlayingInfo()
        startSyncTimer()
        syncStatus = .synced
        showResumeSourceMessage(isOfflineFallback ? "Offline-Fortschritt übernommen" : "Fortgesetzt vom Server")

        // Cover fürs Lockscreen / die Dynamic Island laden. Das System zeigt
        // beide automatisch an, sobald MPNowPlayingInfoCenter ein Artwork
        // enthält — keine eigene Live Activity nötig.
        loadArtwork(coverURL: apiClient.coverURL(forItemId: item.id))
    }

    /// Zeigt eine kurze Meldung (z. B. "Fortgesetzt vom Server") und blendet
    /// sie nach ein paar Sekunden von selbst wieder aus.
    /// Zeigt eine kurze Meldung (z. B. "Fortgesetzt vom Server") und blendet
    /// sie nach ein paar Sekunden von selbst wieder aus. Läuft überall dort,
    /// wo gerade eine View auf `resumeSourceMessage` schaut — Bibliothek,
    /// Detailseite oder voller Player, je nachdem, wo man sich befindet, wenn
    /// die Wiedergabe (auch über die Mini-Leiste) startet.
    private func showResumeSourceMessage(_ message: String) {
        resumeSourceMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.resumeSourceMessage == message {
                self?.resumeSourceMessage = nil
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
        for index in startIndex..<tracks.count {
            guard let url = resolveTrackURL(index: index) else { continue }
            if isLocal {
                items.append(AVPlayerItem(asset: AVURLAsset(url: url)))
            } else {
                var headers: [String: String] = [:]
                if let token = apiClient.token, !token.isEmpty {
                    headers["Authorization"] = "Bearer \(token)"
                }
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                items.append(AVPlayerItem(asset: asset))
            }
        }
        guard !items.isEmpty else { return false }

        let newPlayer = AVQueuePlayer(items: items)
        let wasPlaying = isPlaying
        player = newPlayer
        currentTrackIndex = startIndex

        addTimeObserver()
        observeTrackAdvance()

        if seekWithin > 0.5 {
            newPlayer.seek(to: CMTime(seconds: seekWithin, preferredTimescale: 1000))
        }
        if wasPlaying {
            newPlayer.rate = playbackRate
        }
        return true
    }

    /// Erkennt, wenn AVQueuePlayer automatisch zum nächsten Track
    /// weiterspringt, und hält `currentTrackIndex` synchron — nötig, damit
    /// die absolute Zeitrechnung (Track-Start + Position im Track) stimmt.
    private func observeTrackAdvance() {
        // Nur auf das AKTUELLE Item hören (nicht object: nil). Mit object: nil
        // würde der Beobachter auf das Ende JEDES beliebigen AVPlayerItem
        // reagieren — auch auf Items eines alten/anderen Players, der noch nicht
        // abgebaut ist — und dadurch die Track-Zählung eines Mehrspur-Buchs
        // verfälschen.
        if let observer = trackAdvanceObserver {
            NotificationCenter.default.removeObserver(observer)
            trackAdvanceObserver = nil
        }
        guard let currentItem = player?.currentItem else { return }
        trackAdvanceObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.currentTrackIndex + 1 < self.tracks.count {
                    self.currentTrackIndex += 1
                }
                // Der AVQueuePlayer ist inzwischen auf den nächsten Track
                // weitergerückt — den Beobachter auf dessen (jetzt aktuelles)
                // Item umhängen, damit auch der nächste Track-Wechsel erkannt
                // wird. Am Buchende ist currentItem nil, dann wird nichts mehr
                // registriert.
                self.observeTrackAdvance()
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
        if let image = await fetchImage(url) {
            ImageCache.shared.set(image, for: url)
            return image
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let image = await fetchImage(url) {
            ImageCache.shared.set(image, for: url)
            return image
        }
        return nil
    }

    private static func fetchImage(_ url: URL) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    /// Setzt das Buch serverseitig auf "abgeschlossen" bzw. hebt das wieder auf.
    func toggleFinished() async {
        guard let item else { return }
        do {
            if isFinished {
                // Rückgängig: aktuellen Stand als nicht-fertig schreiben.
                try await apiClient.updateProgress(
                    itemId: item.id,
                    currentTime: currentTime,
                    duration: duration,
                    isFinished: false
                )
                isFinished = false
                // Lokalen Sync-Stand an das gerade Geschriebene angleichen, damit
                // der 30-Sekunden-Timer den aktuellen Stand nicht fälschlich als
                // Rückschritt/Konflikt behandelt.
                lastSyncedTime = currentTime
            } else {
                // Gehört markieren: Fortschritt explizit auf Buchende setzen,
                // statt dem Server mit einem Teil-Update zu überlassen, was er
                // mit currentTime macht.
                try await apiClient.updateProgress(
                    itemId: item.id,
                    currentTime: duration,
                    duration: duration,
                    isFinished: true
                )
                isFinished = true
                // Lokalen Zustand an den Server angleichen: ans Buchende springen
                // und den Sync-Stand nachziehen. Sonst schriebe der periodische
                // Sync gleich wieder den alten (niedrigeren) Stand mit
                // isFinished=false und höbe die Markierung damit auf.
                await seek(to: duration, userInitiated: false)
                lastSyncedTime = duration
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
    }

    // MARK: - Zeit-Beobachtung

    private func addTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Absolute Buch-Zeit = Start des aktuellen Tracks + Position
                // innerhalb dieses Tracks.
                self.currentTime = self.trackAbsoluteStart(self.currentTrackIndex) + seconds
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

    /// Schreibt den Fortschritt an den Server.
    /// - Parameter force: erzwingt einen Sync auch ohne die 5-Sekunden-Schwelle
    ///   (z. B. bei Pause oder wenn die App in den Hintergrund geht).
    func syncProgress(force: Bool) async {
        guard let item else { return }
        guard force || abs(currentTime - lastSyncedTime) >= 5 else { return }

        // Kernregel: Ein Rückschritt, den der Nutzer NICHT selbst ausgelöst hat,
        // wird nie stillschweigend geschrieben.
        if !suppressConflictForNextSync, currentTime < lastSyncedTime - suspiciousDropThreshold {
            if pendingServerConflict == nil {
                pendingServerConflict = ServerConflict(serverTime: lastSyncedTime, localTime: currentTime)
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
                syncStatus = .queued
            } else {
                // Ein echter Fehler (z. B. abgelaufener Token, Serverproblem) —
                // das soll nicht unbemerkt bleiben.
                errorMessage = "Sync fehlgeschlagen: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                syncStatus = .failed
            }
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
        commandCenter.skipForwardCommand.preferredIntervals = [30]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipFromLockscreen(by: 30) }
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [30]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipFromLockscreen(by: -30) }
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
            if serverTime > currentTime + 5 {
                await seek(to: serverTime, userInitiated: false)
                lastSyncedTime = serverTime
                showResumeSourceMessage("Fortgesetzt vom Server")
            }
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
