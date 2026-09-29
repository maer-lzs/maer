// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Thrown when a download task was cancelled deliberately (pause or abort).
/// `resumeData` is non-nil for pauses and lets the next attempt continue
/// mid-file instead of starting the track over.
struct DownloadCancelledError: Error {
    let resumeData: Data?
}

/// Downloads files with progress reporting over ONE shared background
/// URLSession: transfers keep running while the app is backgrounded,
/// suspended, or killed by the system. Each task's destination is persisted.
/// If the app is relaunched for finished downloads (no live handler), the
/// delegate still files the result correctly.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = FileDownloader()

    /// Set by AppDelegate; called after all background events are processed.
    /// Assigned by the app delegate on the main thread and read and cleared
    /// again on the main actor (`urlSessionDidFinishEvents` hops with
    /// `Task { @MainActor … }`). Never touched concurrently. The rest of the
    /// downloader's mutable state is serialized by `lock`.
    // unsafe because only the main thread assigns, reads and clears it.
    nonisolated(unsafe) var backgroundCompletionHandler: (() -> Void)?

    private struct Handler {
        let onProgress: (Double) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    // An implicitly-unwrapped `var` only because the delegate-`self` pattern
    // forbids a `let` here (self isn't available before super.init).
    // unsafe because it is assigned exactly once, in init, and only read after.
    nonisolated(unsafe) private var session: URLSession!
    // unsafe because every read and write stands between `lock.lock()` and
    // `lock.unlock()` (download, takeHandler and the delegate callbacks),
    // which the compiler cannot see.
    nonisolated(unsafe) private var handlers: [Int: Handler] = [:]
    private let lock = NSLock()

    /// taskIdentifier → destination path, persisted. For downloads finishing
    /// without a running app (relaunch after a system kill).
    private let destinationsKey = AppStorageKeys.pendingDownloadDestinations

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(
            withIdentifier: "absplayer.track-downloads"
        )
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        // Prune destination entries orphaned by earlier app kills. Anything
        // that no longer belongs to a live task.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let active = Set(tasks.map { String($0.taskIdentifier) })
            self.lock.lock()
            // Also keep entries for tasks started THIS session after the
            // getAllTasks snapshot was taken. Pruning them would make a
            // perfectly good download fail on completion (missing destination).
            let live = Set(self.handlers.keys.map(String.init))
            var map = AppStorageKeys.dictionary(self.destinationsKey) as? [String: String] ?? [:]
            map = map.filter { active.contains($0.key) || live.contains($0.key) }
            AppStorageKeys.set(map, for: self.destinationsKey)
            self.lock.unlock()
        }
    }

    /// Downloads and moves the result to `destination` itself (target folder
    /// must exist). `resumeData` continues a previously paused transfer.
    /// `onTask` hands the live task to the caller for pause/cancel control.
    func download(
        request: URLRequest,
        to destination: URL,
        resumeData: Data? = nil,
        onProgress: @escaping (Double) -> Void,
        onTask: ((URLSessionDownloadTask) -> Void)? = nil
    ) async throws {
        // The background session is the one way out past the HTTP door;
        // the identity is set here like there.
        var identified = request
        AppUserAgent.applyIfMissing(to: &identified)
        let request = identified
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = resumeData.map { session.downloadTask(withResumeData: $0) }
                ?? session.downloadTask(with: request)
            lock.lock()
            handlers[task.taskIdentifier] = Handler(onProgress: onProgress, continuation: continuation)
            var map = AppStorageKeys.dictionary(destinationsKey) as? [String: String] ?? [:]
            map[String(task.taskIdentifier)] = destination.path
            AppStorageKeys.set(map, for: destinationsKey)
            lock.unlock()
            onTask?(task)
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
        var map = AppStorageKeys.dictionary(destinationsKey) as? [String: String] ?? [:]
        guard let path = map.removeValue(forKey: String(id)) else { return nil }
        AppStorageKeys.set(map, for: destinationsKey)
        return URL(fileURLWithPath: path)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let handler = handlers[downloadTask.taskIdentifier]
        lock.unlock()
        // Servers without a Content-Length (chunked transfer. Common for
        // podcast CDNs and transcoded streams) report an unknown total: signal
        // an indeterminate download (-1) instead of never reporting, which left
        // the progress ring stuck empty at 0.
        if totalBytesExpectedToWrite > 0 {
            handler?.onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            handler?.onProgress(-1)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` vanishes once this returns. Move it now.
        let handler = takeHandler(downloadTask.taskIdentifier)
        guard let destination = takeDestination(downloadTask.taskIdentifier) else {
            handler?.continuation.resume(throwing: URLError(.unknown))
            return
        }
        // A download task "succeeds" even for HTTP 4xx/5xx. The error page
        // would be stored as an audio track and break playback silently
        // (CoreMedia -12864). Validate the status before keeping anything.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            handler?.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        // Orphan tasks (no live handler, e.g. zombies from an earlier app
        // session) must NEVER overwrite an existing file: the book may have
        // completed via resume-by-skip since, and replacing a good track with
        // this task's (possibly stale) payload corrupts playback silently.
        if handler == nil, FileManager.default.fileExists(atPath: destination.path) {
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
        // No handler (relaunch) and no existing file: keep it. A later
        // download of the book will skip it (resume).
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        _ = takeDestination(task.taskIdentifier)
        guard let handler = takeHandler(task.taskIdentifier) else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            // Deliberate pause/abort. Carry the resume data (if any) upward.
            let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            handler.continuation.resume(throwing: DownloadCancelledError(resumeData: data))
        } else {
            handler.continuation.resume(throwing: error)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All background events processed: call the system handler (main).
        Task { @MainActor [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
