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

    @Published var isPlaying = false
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
    /// True, während der Player nachpuffert (z. B. nach kurzem Funkloch) —
    /// die View zeigt dann einen "Lädt…"-Zustand statt eines starren Fehlers.
    @Published var isBuffering = false
    /// Spiegelt, ob das Buch als abgeschlossen gilt (für den "Als gehört
    /// markieren"-Button, der sich dann in "Als ungehört markieren" ändert).
    @Published var isFinished = false

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var sleepTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private let apiClient: APIClient
    private var item: LibraryItemDetail?
    private var artworkImage: UIImage?

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

    // MARK: - Laden

    func load(item: LibraryItemDetail) async {
        self.item = item
        chapters = item.media.chapters ?? []
        duration = item.media.duration ?? (item.media.tracks?.first?.duration ?? 0)

        let asset: AVURLAsset
        if let localURL = DownloadManager.shared.localFileURL(forItemId: item.id) {
            // Lokal heruntergeladen: kein Netzwerk, kein Auth-Header nötig —
            // genau der Fall, der bei hoher Serverlatenz (unterwegs) hilft.
            asset = AVURLAsset(url: localURL)
        } else {
            guard let track = item.media.tracks?.first,
                  let url = apiClient.streamURL(forContentPath: track.contentUrl) else {
                errorMessage = "Kein abspielbarer Track gefunden. Hat das Buch mehrere Dateien statt einer M4B?"
                return
            }
            var headers: [String: String] = [:]
            if let token = apiClient.token, !token.isEmpty {
                headers["Authorization"] = "Bearer \(token)"
            }
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player

        addTimeObserver()
        setupRemoteCommandCenter()

        // Kernregel beim Start: Serverstand gewinnt, nie bei 0 anfangen,
        // wenn der Server schon Fortschritt kennt.
        let serverProgress = item.userMediaProgress?.currentTime ?? 0
        if serverProgress > 0 {
            await seek(to: serverProgress, userInitiated: false)
        }
        lastSyncedTime = serverProgress
        currentTime = serverProgress
        isFinished = item.userMediaProgress?.isFinished ?? false
        updateCurrentChapter()
        updateNowPlayingInfo()
        startSyncTimer()

        // Cover fürs Lockscreen / die Dynamic Island laden. Das System zeigt
        // beide automatisch an, sobald MPNowPlayingInfoCenter ein Artwork
        // enthält — keine eigene Live Activity nötig.
        loadArtwork(coverURL: apiClient.coverURL(forItemId: item.id))
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
        guard let player else { return }
        let clamped = max(0, min(time, max(duration, 0)))
        await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 1000))
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
                self.currentTime = seconds
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

        do {
            try await apiClient.updateProgress(
                itemId: item.id,
                currentTime: currentTime,
                duration: duration,
                isFinished: duration > 0 && currentTime >= duration - 1
            )
            lastSyncedTime = currentTime
            suppressConflictForNextSync = false
        } catch {
            if Self.isOfflineError(error) {
                // Erwartbar, kein echter Fehler: kein Netz gerade, z. B. auf
                // Reisen. Der nächste automatische Versuch (spätestens in 30s,
                // oder sofort bei Pause/Hintergrund) klappt einfach, sobald
                // wieder Verbindung besteht — kein Grund zur Beunruhigung.
                errorMessage = nil
            } else {
                // Ein echter Fehler (z. B. abgelaufener Token, Serverproblem) —
                // das soll nicht unbemerkt bleiben.
                errorMessage = "Sync fehlgeschlagen: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    /// Erkennt reine Netzwerk-Nichterreichbarkeit (kein Netz, Timeout, DNS
    /// nicht auflösbar …) — im Unterschied zu echten Fehlern wie 401 oder
    /// einem kaputten Server-Format, die weiterhin angezeigt werden sollen.
    private static func isOfflineError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let offlineCodes: Set<Int> = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff
        ]
        return offlineCodes.contains(nsError.code)
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
            Task { @MainActor in self?.skip(by: 30) }
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [30]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -30) }
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
            }
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
        player = nil
        syncTask?.cancel()
        sleepTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
