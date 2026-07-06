import Foundation

/// Lädt eine Datei mit Fortschritts-Rückmeldung herunter. Eigener kleiner
/// Delegate-Wrapper, weil die einfache async URLSession-API bei großen
/// Dateien (Hörbücher: oft mehrere hundert MB) keinen Downloadfortschritt
/// liefert.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: (Double) -> Void
    private var session: URLSession?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    /// Lädt herunter und liefert eine temporäre URL zurück. Der Aufrufer ist
    /// dafür verantwortlich, die Datei von dort an den Zielort zu verschieben
    /// (das System löscht die temporäre Datei sonst automatisch wieder).
    func download(request: URLRequest) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Die Datei an `location` verschwindet, sobald diese Methode zurückkehrt
        // — deshalb sofort synchron in eine eigene temporäre Datei verschieben.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            continuation?.resume(returning: tempURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // didCompleteWithError ist die garantierte letzte Delegate-Meldung eines
        // Tasks — bei Erfolg (error == nil, nach didFinishDownloadingTo), bei
        // Fehler und bei Abbruch. Eine noch offene Continuation (echter Fehler
        // ohne vorheriges didFinishDownloadingTo) wird hier aufgelöst.
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        // Session invalidieren, damit URLSession ihre starke Referenz auf den
        // Delegate (self) freigibt. Ohne das bliebe pro Download ein
        // FileDownloader samt Session am Leben (Retain-Cycle Session ->
        // Delegate -> Session), da die Session nie invalidiert wurde.
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
