import Foundation

/// Lädt Dateien mit Fortschritts-Rückmeldung über EINE geteilte
/// Background-URLSession: Downloads laufen weiter, wenn die App in den
/// Hintergrund geht, suspendiert oder vom System beendet wird. Das Ziel jedes
/// Tasks wird persistiert — wird die App für fertige Downloads neu geweckt
/// (ohne Live-Handler), sortiert der Delegate die Datei trotzdem korrekt ein.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = FileDownloader()

    /// Von AppDelegate gesetzt; nach Verarbeitung aller Events aufrufen.
    var backgroundCompletionHandler: (() -> Void)?

    private struct Handler {
        let onProgress: (Double) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private var session: URLSession!
    private var handlers: [Int: Handler] = [:]
    private let lock = NSLock()

    /// taskIdentifier → Ziel-Pfad, persistiert — für Downloads, die ohne
    /// laufende App fertig werden (Relaunch nach System-Kill).
    private let destinationsKey = "pendingDownloadDestinations"

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(
            withIdentifier: "absplayer.track-downloads"
        )
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        // Verwaiste Ziel-Einträge früherer Läufe (App-Kill) entfernen —
        // alles, was zu keinem noch laufenden Task gehört.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let active = Set(tasks.map { String($0.taskIdentifier) })
            self.lock.lock()
            var map = UserDefaults.standard.dictionary(forKey: self.destinationsKey) as? [String: String] ?? [:]
            map = map.filter { active.contains($0.key) }
            UserDefaults.standard.set(map, forKey: self.destinationsKey)
            self.lock.unlock()
        }
    }

    /// Lädt herunter und verschiebt das Ergebnis selbst an `destination`
    /// (Zielordner muss existieren) — so kennt auch der Orphan-Pfad das Ziel.
    func download(request: URLRequest, to destination: URL, onProgress: @escaping (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: request)
            lock.lock()
            handlers[task.taskIdentifier] = Handler(onProgress: onProgress, continuation: continuation)
            var map = UserDefaults.standard.dictionary(forKey: destinationsKey) as? [String: String] ?? [:]
            map[String(task.taskIdentifier)] = destination.path
            UserDefaults.standard.set(map, forKey: destinationsKey)
            lock.unlock()
            task.resume()
        }
    }

    private func takeHandler(_ id: Int) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: id)
    }

    private func takeDestination(_ id: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        var map = UserDefaults.standard.dictionary(forKey: destinationsKey) as? [String: String] ?? [:]
        guard let path = map.removeValue(forKey: String(id)) else { return nil }
        UserDefaults.standard.set(map, forKey: destinationsKey)
        return URL(fileURLWithPath: path)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let handler = handlers[downloadTask.taskIdentifier]
        lock.unlock()
        handler?.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Datei verschwindet nach Rückkehr — sofort synchron ans Ziel.
        let handler = takeHandler(downloadTask.taskIdentifier)
        guard let destination = takeDestination(downloadTask.taskIdentifier) else {
            handler?.continuation.resume(throwing: URLError(.unknown))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            handler?.continuation.resume(returning: ())
        } catch {
            handler?.continuation.resume(throwing: error)
        }
        // Ohne handler (Relaunch): Datei liegt jetzt trotzdem am Zielort —
        // ein erneuter Download des Buchs überspringt sie (Resume).
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        _ = takeDestination(task.taskIdentifier)
        takeHandler(task.taskIdentifier)?.continuation.resume(throwing: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Alle Hintergrund-Events verarbeitet: System-Handler aufrufen (Main).
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
