// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

/// Thrown when a download task was cancelled deliberately (pause or abort).
/// `resumeData` is non-nil for pauses and lets the next attempt continue
/// mid-file instead of starting the track over.
struct DownloadCancelledError: Error {
    let resumeData: Data?
}

/// Thrown when a track arrived with fewer bytes than its source states for
/// the file (`TrackFileSize`): it is not kept as a finished track.
struct ShortDownloadError: LocalizedError {
    let bytes: Int64
    let stated: Int64
    var errorDescription: String? { String(localized: "A track arrived incomplete. Try the download again.") }
}

/// Thrown when the host of a download gave no byte for the limit of
/// `DownloadSilence` while the app watched.
/// `resumeData` lets the next attempt continue where the bytes stopped.
nonisolated struct SilentHostError: LocalizedError {
    let resumeData: Data?
    var errorDescription: String? { String(localized: "The server stopped answering. Try the download again.") }
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
        /// The size the source states for this file, where its download is
        /// that file; nil holds the result to no size.
        let statedBytes: Int64?
        /// The size and type a source that may transcode states for the
        /// original; it holds the result only when the answer shows the
        /// original arrived (`TrackFileSize.statedByAnswer`).
        let claim: TrackFileSize.Claim?
        /// The runs of this task so far (`DownloadStall`).
        var stall = DownloadStall()
        /// The host the app asked, the key of `DownloadSilence`.
        let host: String
        /// The task, for ending it when its host fell silent.
        let task: URLSessionDownloadTask
    }

    /// The silence of every host with downloads running, how often the
    /// watch looks, and whether it runs. A host may give no byte for two
    /// minutes (`DownloadSilence.limit`); a gap of three looks means the
    /// app was not running.
    private struct Watch {
        var silence = DownloadSilence(limit: 120, maxGap: 45)
        var tick: TimeInterval = 15
        var running = false
        #if DEBUG
        var endAfterEntry = false
        #endif
    }
    private let watch = Mutex(Watch())

    #if DEBUG
    /// Test seam: a short limit and tick, as a witness waits seconds, not
    /// minutes. Only while no download runs.
    func testSetSilence(limit: TimeInterval, tick: TimeInterval) {
        watch.withLock { $0 = Watch(silence: DownloadSilence(limit: limit, maxGap: tick * 3), tick: tick) }
    }

    /// Test seam: the downloads of a host end right after a download's
    /// entry, where the watch may come between a download and its run.
    func testEndAfterEntry(_ on: Bool) {
        watch.withLock { $0.endAfterEntry = on }
    }

    /// Whether the watch counts any download running.
    var testWatchesAny: Bool { watch.withLock { $0.silence.watchesAny } }
    #endif

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
        // A net under the silence watch, which only counts while the app
        // runs: a download still not finished after a day ends with its
        // resume data. The default is seven days.
        config.timeoutIntervalForResource = 86_400
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
    /// `statedBytes` is the size the result must reach (`TrackFileSize`):
    /// fewer bytes are not kept and throw `ShortDownloadError`. `claim`
    /// does the same for a source that may transcode, once the answer
    /// shows the original arrived. A task that ends `DownloadStall.limit`
    /// runs at the same byte also throws `ShortDownloadError`. A host that
    /// gives no byte to any of its downloads for the limit of
    /// `DownloadSilence` ends them with `SilentHostError`.
    func download(
        request: URLRequest,
        to destination: URL,
        resumeData: Data? = nil,
        statedBytes: Int64? = nil,
        claim: TrackFileSize.Claim? = nil,
        onProgress: @escaping (Double) -> Void,
        onTask: ((URLSessionDownloadTask) -> Void)? = nil
    ) async throws {
        // The background session is the one way out past the HTTP door;
        // the identity is set here like there.
        var identified = request
        ServerHeaders.apply(to: &identified)
        try ServerHeaders.admit(identified)
        let server = identified.url.flatMap { url in
            ServerHeaders.entries().flatMap { ServerHeaderRule.entry(for: url, in: $0) }
        }
        // The background session follows a redirect without asking its
        // delegate and carries the headers along (measured), so a server
        // with headers is asked at the end of its redirects.
        if let server { identified = await ServerHeaders.end(of: identified, server: server) }
        AppUserAgent.applyIfMissing(to: &identified)
        let request = identified
        // Resume data carries the request it was paused with, headers and
        // all; a server with headers starts its file anew with today's.
        var resumeData = resumeData
        if resumeData != nil, server != nil {
            Logger.library.notice("DOWNLOAD starts anew host=\(request.url?.host ?? "-", privacy: .public): resume data would carry old server headers")
            resumeData = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = resumeData.map { session.downloadTask(withResumeData: $0) }
                ?? session.downloadTask(with: request)
            // The host the app asks; a redirect elsewhere still counts here.
            let host = task.originalRequest?.url?.host ?? request.url?.host ?? ""
            // The entry and its count are one step, as are the take and its
            // end (`takeHandler`): a watch ending the host between them
            // would find the entry, end no count, and the count after it
            // would hold a download that does not run. `watch` is taken
            // only inside `lock` or alone, never the other way.
            lock.lock()
            handlers[task.taskIdentifier] = Handler(onProgress: onProgress, continuation: continuation,
                                                    statedBytes: statedBytes, claim: claim, host: host, task: task)
            let startWatch = watch.withLock { state -> Bool in
                state.silence.began(host, at: Date())
                defer { state.running = true }
                return !state.running
            }
            var map = AppStorageKeys.dictionary(destinationsKey) as? [String: String] ?? [:]
            map[String(task.taskIdentifier)] = destination.path
            AppStorageKeys.set(map, for: destinationsKey)
            lock.unlock()
            #if DEBUG
            if watch.withLock({ $0.endAfterEntry }) { endDownloads(of: host) }
            #endif
            if startWatch { watchSilence() }
            onTask?(task)
            task.resume()
        }
    }

    /// Looks at the silence of every host every `Watch.tick` while
    /// downloads run, and ends the downloads of a host that fell silent.
    private func watchSilence() {
        Task { [weak self] in
            while let self {
                let tick = self.watch.withLock { $0.tick }
                // bearable, because nothing cancels this task (no one holds it); a cancelled sleep would not end the loop but turn it without a pause
                try? await Task.sleep(for: .seconds(tick))
                let online = await Reachability.isConnected()
                let silent = self.watch.withLock { $0.silence.tick(at: Date(), online: online) }
                for host in silent { self.endDownloads(of: host) }
                // The stop reads the state its writers change under the same
                // lock: a download that begins meanwhile either is counted
                // here or finds the watch stopped and starts it again.
                let goOn = self.watch.withLock { state -> Bool in
                    if !state.silence.watchesAny { state.running = false }
                    return state.running
                }
                if !goOn { return }
            }
        }
    }

    /// Ends every running download of `host` with `SilentHostError`,
    /// carrying the resume data its cancellation produces, so the next
    /// attempt continues where the bytes stopped.
    private func endDownloads(of host: String) {
        let ids = lock.withLock { handlers.filter { $0.value.host == host }.map(\.key) }
        let taken = ids.compactMap { id in takeHandler(id).map { (id, $0) } }
        for (id, _) in taken { _ = takeDestination(id) }
        guard !taken.isEmpty else { return }
        let limit = watch.withLock { Int($0.silence.limit) }
        Logger.library.error("DOWNLOAD silent host=\(host, privacy: .public) seconds=\(limit) tasks=\(taken.count), failed")
        for (_, handler) in taken {
            handler.task.cancel(byProducingResumeData: { data in
                handler.continuation.resume(throwing: SilentHostError(resumeData: data))
            })
        }
    }

    /// Takes a task's handler; each taken handler ends one counted download
    /// of its host (`DownloadSilence.ended`), exactly once.
    private func takeHandler(_ id: Int) -> Handler? {
        lock.withLock {
            let taken = handlers.removeValue(forKey: id)
            if let host = taken?.host { watch.withLock { $0.silence.ended(host) } }
            return taken
        }
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
        let stalled = handlers[downloadTask.taskIdentifier]?.stall.written(bytesWritten, total: totalBytesWritten) ?? false
        let handler = handlers[downloadTask.taskIdentifier]
        lock.unlock()
        if let host = handler?.host { watch.withLock { $0.silence.heard(host, at: Date()) } }
        // A server that states a length and closes early makes the session
        // start over without end (`DownloadStall`): the task ends here as a
        // track that arrived incomplete.
        if stalled, let taken = takeHandler(downloadTask.taskIdentifier) {
            _ = takeDestination(downloadTask.taskIdentifier)
            Logger.library.error("DOWNLOAD stalled task=\(downloadTask.taskIdentifier) bytes=\(taken.stall.best) expected=\(totalBytesExpectedToWrite) rounds=\(DownloadStall.limit), failed")
            downloadTask.cancel()
            taken.continuation.resume(throwing: ShortDownloadError(bytes: taken.stall.best,
                                                                   stated: max(totalBytesExpectedToWrite, 0)))
            return
        }
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
            Logger.library.error("DOWNLOAD unplaced task=\(downloadTask.taskIdentifier), no destination, failed")
            handler?.continuation.resume(throwing: URLError(.unknown))
            return
        }
        // A download task "succeeds" even for HTTP 4xx/5xx. The error page
        // would be stored as an audio track and break playback silently
        // (CoreMedia -12864). Validate the status before keeping anything.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            Logger.library.error("DOWNLOAD status task=\(downloadTask.taskIdentifier) status=\(http.statusCode), failed")
            handler?.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        // A body that ended early reports success when the server sent no
        // length or a chunked body lost its last chunk (measured): the size
        // the source states decides. An orphan has no stated size here; the
        // resume and the player hold the file to it later.
        var held = handler?.statedBytes
        if held == nil, let claim = handler?.claim {
            let answer = downloadTask.response
            let http = answer as? HTTPURLResponse
            let total = http?.statusCode == 206
                ? TrackFileSize.total(contentRange: http?.value(forHTTPHeaderField: "Content-Range")) : nil
            let byAnswer = TrackFileSize.statedByAnswer(claim, answerLength: answer?.expectedContentLength ?? -1,
                                                        answerTotal: total, answerType: answer?.mimeType)
            held = byAnswer.stated
            if let unheld = byAnswer.unheld {
                Logger.library.notice("DOWNLOAD size unheld file=\(destination.lastPathComponent, privacy: .public) reason=\(unheld.rawValue, privacy: .public) claimed=\(claim.size)")
            }
        }
        if let stated = held {
            let bytes = TrackFileSize.bytes(at: location)
            switch TrackFileSize.verdict(bytes: bytes, stated: stated) {
            case .short:
                Logger.library.error("DOWNLOAD short file=\(destination.lastPathComponent, privacy: .public) bytes=\(bytes ?? 0) stated=\(stated), not kept")
                handler?.continuation.resume(throwing: ShortDownloadError(bytes: bytes ?? 0, stated: stated))
                return
            case .larger:
                Logger.library.notice("DOWNLOAD larger file=\(destination.lastPathComponent, privacy: .public) bytes=\(bytes ?? 0) stated=\(stated), kept")
            case .unread:
                Logger.library.error("DOWNLOAD size unread file=\(destination.lastPathComponent, privacy: .public) stated=\(stated), kept")
            case .whole, .unstated:
                break
            }
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
            Logger.library.error("DOWNLOAD not stored task=\(downloadTask.taskIdentifier) reason=\(FailureReason.of(error), privacy: .public), failed")
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
            // Domain and code only: the error itself names the address.
            Logger.library.error("DOWNLOAD ended task=\(task.taskIdentifier) reason=\(FailureReason.of(error), privacy: .public), failed")
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
