import Foundation

/// Lädt Dateien mit Fortschritts-Rückmeldung über EINE geteilte
/// Background-URLSession: Downloads laufen weiter, wenn die App in den
/// Hintergrund geht oder suspendiert wird (wichtig bei Hörbüchern mit
/// mehreren hundert MB). Bei Force-Quit bricht der Download ab und wird beim
/// nächsten Versuch neu gestartet (bewusst kein Relaunch-Handling).
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = FileDownloader()

    private struct Handler {
        let onProgress: (Double) -> Void
        let continuation: CheckedContinuation<URL, Error>
    }

    private var session: URLSession!
    /// Task-Identifier → Handler. Zugriff über `lock`, da Delegate-Callbacks
    /// und `download`-Aufrufer auf verschiedenen Threads laufen.
    private var handlers: [Int: Handler] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(
            withIdentifier: "absplayer.track-downloads"
        )
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Lädt herunter und liefert eine temporäre URL zurück; der Aufrufer
    /// verschiebt die Datei an ihren Zielort.
    func download(request: URLRequest, onProgress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request)
            lock.lock()
            handlers[task.taskIdentifier] = Handler(onProgress: onProgress, continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    private func takeHandler(_ id: Int) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: id)
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
        // Datei verschwindet nach Rückkehr — sofort synchron wegverschieben.
        guard let handler = takeHandler(downloadTask.taskIdentifier) else { return }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            handler.continuation.resume(returning: tempURL)
        } catch {
            handler.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Erfolgsfall wurde bereits in didFinishDownloadingTo aufgelöst
        // (Handler dann schon entfernt) — hier nur echte Fehler/Abbrüche.
        guard let error, let handler = takeHandler(task.taskIdentifier) else { return }
        handler.continuation.resume(throwing: error)
    }
}
