// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import AVFoundation
import OSLog

/// Manages locally downloaded audiobooks. Each book gets its own subfolder
/// "Downloads/{itemId}/0.{ext}", "1.{ext}", … — multi-file books (several audio
/// files instead of one M4B) are downloaded completely, not just the first
/// file. The associated book details (chapters, duration, track order) live
/// separately under "DownloadsMeta/{itemId}.json".
///
/// The metadata file is the key to real offline listening: without it the app
/// would have to fetch chapters/duration from the server on every book open —
/// even when the audio files are already present locally.
///
/// Deliberately a device-wide singleton like `KeychainStore`: downloads are a
/// device-storage concept, not a session-specific dependency.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Per-book download lifecycle for the UI.
    enum DownloadPhase: Equatable {
        case downloading(Double)
        case paused(Double)
        case failed(String)

        var progress: Double? {
            switch self {
            case .downloading(let p), .paused(let p): return p
            case .failed: return nil
            }
        }
    }

    /// Live control state of a running/paused download (in-memory only —
    /// after a relaunch, partial folders are picked up via resume-by-skip).
    private struct DownloadControl {
        var detail: LibraryItemDetail
        var currentTask: URLSessionDownloadTask?
        var pendingPause = false
        var pendingCancel = false
        var resumeData: Data?
        /// Track index the in-flight transfer belongs to — binds `resumeData`
        /// to ITS track. Consumed by "the first non-skipped track", the resume
        /// data of track N could otherwise continue as track M's file when M's
        /// file disappeared between pause and resume (wrong audio under that
        /// index).
        var inFlightTrackIndex: Int?
        var resumeTrackIndex: Int?
    }

    @Published private(set) var downloadedItemIds: Set<String> = []
    /// Phase per book: downloading (weighted progress), paused, or failed.
    @Published private(set) var phase: [String: DownloadPhase] = [:]
    private var controls: [String: DownloadControl] = [:]
    /// Coalescing for progress publishes — URLSession reports every chunk, but
    /// publishing the @Published `phase` re-renders every observing view (all
    /// cover cells, episode rows, the library). Only meaningful steps go out.
    private var lastPublishedFraction: [String: Double] = [:]

    /// Publish a download fraction only when it moved ≥1% since the last
    /// publish (or reached the end) — cuts the invalidation storm during
    /// downloads from dozens per second to at most ~100 per download.
    private func publishProgress(itemId: String, fraction: Double) {
        guard case .downloading = phase[itemId] else { return }
        // -1 = indeterminate (server sent no size); publish once so the ring
        // switches to a spinner instead of sitting empty at 0.
        if fraction < 0 {
            if case .downloading(let current) = phase[itemId], current < 0 { return }
            phase[itemId] = .downloading(-1)
            return
        }
        let last = lastPublishedFraction[itemId] ?? -1
        guard fraction - last >= 0.01 || fraction >= 1 else { return }
        lastPublishedFraction[itemId] = fraction
        phase[itemId] = .downloading(fraction)
    }
    /// Cached instead of computed — the view reads it on every render; a disk
    /// scan per progress tick would be expensive.
    @Published private(set) var totalDownloadsSize: Int64 = 0

    /// The startup filesystem scan — awaitable via `ensureScanned()` so
    /// IMPERATIVE consumers of `downloadedItemIds` in the launch window
    /// (offline path, CarPlay, maintenance) don't race the detached walk and
    /// see an empty set (that produced an empty library despite downloads).
    private var scanTask: Task<Void, Never>?

    /// Waits until the startup download scan has been merged (no-op afterwards).
    func ensureScanned() async {
        await scanTask?.value
    }

    private init() {
        // The full filesystem walk (every download folder + every file's size)
        // used to run synchronously here — on the main actor, BEFORE first
        // paint, scaling with the number of downloads. Scan off-main instead
        // and publish the result one tick later.
        let downloadsDir = downloadsDirectory   // also creates the directories
        let metaDir = metadataDirectory
        scanTask = Task { [weak self] in
            let scan = await Task.detached(priority: .userInitiated) {
                Self.scanDownloads(downloadsDir: downloadsDir, metaDir: metaDir)
            }.value
            guard let self else { return }
            // Merge: a download finished while scanning must not be dropped —
            // but a download DELETED while scanning must not come back either
            // (the stale scan still contains it). Re-check the meta file, the
            // criterion deleteDownload removes, at merge time.
            let stillPresent = scan.ids.filter { id in
                FileManager.default.fileExists(
                    atPath: metaDir.appendingPathComponent("\(id).json").path)
            }
            self.downloadedItemIds.formUnion(stillPresent)
            self.totalDownloadsSize = stillPresent == scan.ids
                ? scan.totalSize
                : self.downloadedItemIds.reduce(0) { $0 + self.downloadSize(forItemId: $1) }
        }
    }

    /// Off-main startup scan: completed download ids (meta file present) plus
    /// their total size in one walk.
    private nonisolated static func scanDownloads(downloadsDir: URL, metaDir: URL)
        -> (ids: Set<String>, totalSize: Int64) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: downloadsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return ([], 0) }
        var ids = Set<String>()
        var total: Int64 = 0
        for dir in dirs
        where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let itemId = dir.lastPathComponent
            // The meta file is only written after a complete download — a folder
            // without meta is an aborted remnant (kept for resume, not counted).
            guard FileManager.default.fileExists(
                atPath: metaDir.appendingPathComponent("\(itemId).json").path) else { continue }
            ids.insert(itemId)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            total += files.reduce(0) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
        return (ids, total)
    }

    private func recalculateTotalSize() {
        totalDownloadsSize = downloadedItemIds.reduce(0) { $0 + downloadSize(forItemId: $1) }
    }

    private var downloadsDirectory: URL {
        makeDirectory(named: "Downloads")
    }

    /// Free space iOS would grant for user-important data (more generous
    /// than plain free space — includes purgeable caches).
    private func freeDiskBytes() -> Int64? {
        let values = try? downloadsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private var metadataDirectory: URL {
        makeDirectory(named: "DownloadsMeta")
    }

    private func itemDirectory(_ itemId: String) -> URL {
        downloadsDirectory.appendingPathComponent(itemId, isDirectory: true)
    }

    private func makeDirectory(named name: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // (The startup scan lives in `scanDownloads` above — each book has its own
    // subfolder named after the item id; Audiobookshelf ids can contain
    // underscores, so folders avoid ambiguity when mapping files to books.)

    func isDownloaded(itemId: String) -> Bool {
        // Offline available is what LIES here: an own file, or a completed
        // download. The rule used to read "cannot be downloaded, therefore
        // already here" — which is true for local files and false for every
        // stream. Catalogue items and radio carry no download capability
        // either, so they counted as offline available while nothing of them
        // plays without a network.
        if AppSession.shared.provider(for: itemId).capabilities.contains(.alwaysLocal) { return true }
        return downloadedItemIds.contains(itemId)
    }

    func isDownloading(itemId: String) -> Bool {
        if case .downloading = phase[itemId] { return true }
        return false
    }

    /// True if an incomplete download folder exists (aborted/failed earlier) —
    /// a new download will only fetch the missing files.
    func hasPartialDownload(itemId: String) -> Bool {
        guard !downloadedItemIds.contains(itemId) else { return false }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: itemDirectory(itemId), includingPropertiesForKeys: nil)) ?? []
        return !files.isEmpty
    }

    /// Pause: cancel the current track transfer, keeping resume data.
    func pauseDownload(itemId: String) {
        guard case .downloading = phase[itemId], var control = controls[itemId] else { return }
        control.pendingPause = true
        controls[itemId] = control
        control.currentTask?.cancel { _ in /* resume data arrives via delegate */ }
    }

    /// Resume a paused download (continues mid-file via resume data).
    func resumeDownload(itemId: String) {
        guard case .paused = phase[itemId],
              let control = controls[itemId],
              let provider = resumeProvider else { return }
        // Clear the paused phase so the isDownloading guard lets us restart.
        phase[itemId] = nil
        Task { await download(item: control.detail, provider: provider) }
    }

    /// Abort: stop the transfer, keep completed tracks (a later download
    /// fetches only the missing files), clear the visible state.
    func cancelDownload(itemId: String) {
        guard var control = controls[itemId] else {
            phase[itemId] = nil
            return
        }
        control.pendingCancel = true
        controls[itemId] = control
        if case .paused = phase[itemId] {
            // Nothing in flight — clear state directly.
            controls[itemId] = nil
            phase[itemId] = nil
        } else {
            control.currentTask?.cancel()
        }
    }

    /// Client used for resumes (set on each download start).
    private weak var resumeProvider: (any AudioProvider)?

    /// All locally downloaded audio files of a book, sorted by track order
    /// (filename = track index). Preferred by the player to avoid streaming (and
    /// thus latency/data volume).
    /// Strict per-track lookup: filename base MUST be the track index.
    /// Positional sorting silently mapped the wrong files to tracks as soon
    /// as the folder contained anything unexpected (duplicate extensions
    /// after a server rescan, hidden files) — track 0 became junk and
    /// playback failed silently.
    nonisolated private static func trackMap(in dir: URL) -> [Int: URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        )) ?? []
        var map: [Int: URL] = [:]
        for file in files {
            guard let index = Int(file.deletingPathExtension().lastPathComponent) else { continue }
            // Corruption guard + extension repair: reject non-audio garbage,
            // and rename files whose extension lies about the container.
            guard let playable = Self.repairedAudioURL(file) else { continue }
            let file = playable
            // Duplicate variants (e.g. 3.mp3 + 3.m4b): keep the newest.
            if let existing = map[index] {
                let newDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let oldDate = (try? existing.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if newDate > oldDate { map[index] = file }
            } else {
                map[index] = file
            }
        }
        return map
    }

    /// Magic-byte sniff: real container type of the file, nil if it is no
    /// plausible audio at all (HTML/JSON error pages, any size).
    /// An ID3 tag says NOTHING about the codec — it can prefix MP3 *or*
    /// ADTS-AAC. Skip the tag and classify the first real frame header
    /// (layer bits 00 = ADTS/AAC, otherwise MPEG audio = mp3).
    // internal (not private): unit-tested with synthetic byte patterns.
    nonisolated static func sniffedAudioExtension(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 12), head.count >= 4 else { return nil }
        let b = [UInt8](head)
        defer { try? handle.close() }
        // MP4/M4A/M4B: "ftyp" at offset 4
        if head.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "m4b" }
        if Array(b[0..<4]) == [0x66, 0x4C, 0x61, 0x43] { return "flac" }
        if Array(b[0..<4]) == [0x4F, 0x67, 0x67, 0x53] { return "ogg" }
        if Array(b[0..<4]) == [0x52, 0x49, 0x46, 0x46] { return "wav" }
        if Array(b[0..<4]) == [0x46, 0x4F, 0x52, 0x4D] { return "aiff" }
        if Array(b[0..<4]) == [0x63, 0x61, 0x66, 0x66] { return "caf" }
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33, head.count >= 10 {
            // ID3v2: syncsafe tag size at bytes 6-9; frame header follows.
            let tagSize = (Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])
            try? handle.seek(toOffset: UInt64(10 + tagSize))
            guard let frame = try? handle.read(upToCount: 2), frame.count == 2 else { return nil }
            return classifyFrameSync([UInt8](frame))
        }
        return classifyFrameSync(b)
    }

    /// 0xFFEx/Fx sync word: layer bits 00 → ADTS (AAC), else MPEG audio.
    nonisolated static func classifyFrameSync(_ b: [UInt8]) -> String? {
        guard b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 else { return nil }
        return (b[1] & 0x06) == 0 ? "aac" : "mp3"
    }

    /// The extension MUST match the real container: for local file URLs
    /// AVFoundation trusts the extension — an MP3 stored as ".m4b" (ABS
    /// content URLs often carry no extension, the download defaulted to m4b)
    /// fails to parse (-12864) and plays silence. Renames if needed and
    /// returns the playable URL; nil for non-audio garbage.
    nonisolated static func repairedAudioURL(_ url: URL) -> URL? {
        guard let real = sniffedAudioExtension(url) else { return nil }
        // mp4-family extensions are interchangeable for the parser.
        let mp4Family = ["m4b", "m4a", "mp4"]
        let current = url.pathExtension.lowercased()
        if current == real || (mp4Family.contains(current) && real == "m4b") { return url }
        let target = url.deletingPathExtension().appendingPathExtension(real)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }

    nonisolated private static func repairFolder(_ dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for file in files {
            _ = Self.repairedAudioURL(file)
        }
    }

    /// ONE-TIME migration (flagged): repair the extensions of all existing
    /// downloads from builds that named tracks by the URL default. New
    /// downloads are repaired right at completion, so this never re-runs.
    func performMaintenance() {
        guard !UserDefaults.standard.bool(forKey: AppStorageKeys.downloadExtensionRepairDone) else { return }
        Task { [weak self] in
            // Launch window: the startup scan may still be running — an empty
            // id set here would mark the one-time repair "done" without doing it.
            await self?.ensureScanned()
            guard let dirs = self?.downloadedItemIds.map({ self!.itemDirectory($0) }) else { return }
            Task.detached(priority: .utility) {
                for dir in dirs {
                    Self.repairFolder(dir)
                }
                UserDefaults.standard.set(true, forKey: AppStorageKeys.downloadExtensionRepairDone)
            }
        }
    }

    /// ONE-TIME deep validation (flagged): let AVFoundation itself verify
    /// every local track — the definitive check for files that pass the
    /// magic-byte sniff but still fail to parse (truncated legacy files,
    /// the source of lingering -12864 preload errors and silently skipped
    /// tracks). Unplayable files are deleted; the auto-heal re-downloads
    /// them the next time the book is opened.
    func performDeepValidation() {
        guard !UserDefaults.standard.bool(forKey: AppStorageKeys.downloadDeepValidationDone) else { return }
        Task { [weak self] in
            await self?.ensureScanned()
            guard let self else { return }
            self.runDeepValidation(dirs: self.downloadedItemIds.map { self.itemDirectory($0) })
        }
    }

    private func runDeepValidation(dirs: [URL]) {
        Task.detached(priority: .utility) {
            for dir in dirs {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                )) ?? []
                for file in files {
                    let playable = (try? await AVURLAsset(url: file).load(.isPlayable)) ?? false
                    if !playable {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
            UserDefaults.standard.set(true, forKey: AppStorageKeys.downloadDeepValidationDone)
        }
    }

    /// Local audio files of a COMPLETE download, keyed by track index.
    func localTrackMap(forItemId itemId: String) -> [Int: URL] {
        guard downloadedItemIds.contains(itemId) else { return [:] }
        return Self.trackMap(in: itemDirectory(itemId))
    }

    /// Cached book details (chapters, duration, tracks) for the offline case —
    /// loaded when the server is unreachable but the book was downloaded locally.
    func loadCachedDetail(forItemId itemId: String) -> LibraryItemDetail? {
        let url = metadataDirectory.appendingPathComponent("\(itemId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryItemDetail.self, from: data)
    }

    private func saveDetail(_ detail: LibraryItemDetail) {
        let url = metadataDirectory.appendingPathComponent("\(detail.id).json")
        guard let data = try? JSONEncoder().encode(detail) else { return }
        try? data.write(to: url)
    }

    /// Downloads all tracks of a book (one for M4B books, several for multi-file
    /// books) — sequentially, with overall progress weighted across all tracks.
    func download(item: LibraryItemDetail, provider: any AudioProvider) async {
        guard !isDownloading(itemId: item.id) else { return }
        let tracks = (item.media.tracks ?? []).enumerated().sorted { l, r in
            // Stable: fall back to the original position when the server
            // index is missing/equal — Swift's sort is not stability-guaranteed,
            // and download naming vs. playback order MUST agree.
            let li = l.element.index ?? l.offset
            let ri = r.element.index ?? r.offset
            return li == ri ? l.offset < r.offset : li < ri
        }.map(\.element)
        guard !tracks.isEmpty else {
            phase[item.id] = .failed(String(localized: "No downloadable track found."))
            return
        }

        let itemId = item.id
        // "Downloaded" alone is not enough: corrupted/undersized tracks are
        // excluded from the map — a re-download run replaces exactly those.
        if downloadedItemIds.contains(itemId),
           Self.trackMap(in: itemDirectory(itemId)).count >= tracks.count {
            return
        }
        // Fail fast when the disk clearly cannot hold the remaining tracks —
        // a mid-download abort would otherwise surface as a cryptic write
        // error. Tracks without size metadata are skipped in the sum; 200 MB
        // margin keeps the system from running into its own low-space state.
        let alreadyPresent = Self.trackMap(in: itemDirectory(itemId))
        let missingBytes = tracks.enumerated()
            .filter { alreadyPresent[$0.offset] == nil }
            .compactMap { $0.element.metadata?.size }
            .reduce(Int64(0), +)
        if missingBytes > 0, let free = freeDiskBytes(),
           free < missingBytes + 200 * 1024 * 1024 {
            phase[itemId] = .failed(String(localized: "Not enough free storage for this download."))
            return
        }

        resumeProvider = provider
        // Carry mid-file resume data over from a pause — used once, and ONLY
        // for the exact track it was captured from (see resumeTrackIndex).
        var carriedResumeData = controls[itemId]?.resumeData
        let carriedResumeIndex = controls[itemId]?.resumeTrackIndex
        controls[itemId] = DownloadControl(detail: item, resumeData: nil)
        phase[itemId] = .downloading(0)
        let dir = itemDirectory(itemId)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let perTrackWeight = 1.0 / Double(tracks.count)
        var completedFraction: Double = 0
        // Index-keyed presence check: a track counts as present no matter
        // which extension an earlier attempt used.
        let existingTracks = Self.trackMap(in: dir)

        do {
            for (index, track) in tracks.enumerated() {
                // Pause/cancel can be requested before the current task handle
                // is known or exactly between two tracks — honor it here, not
                // only via the in-flight task cancellation.
                if controls[itemId]?.pendingCancel == true || controls[itemId]?.pendingPause == true {
                    throw DownloadCancelledError(resumeData: nil)
                }
                guard let remoteURL = provider.streamURL(forContentPath: track.contentUrl) else { continue }
                let ext = remoteURL.pathExtension.isEmpty ? "m4b" : remoteURL.pathExtension
                let destination = dir.appendingPathComponent("\(index).\(ext)")

                // Resume-by-skip: tracks from an earlier attempt are kept.
                if existingTracks[index] != nil {
                    completedFraction += perTrackWeight
                    phase[itemId] = .downloading(completedFraction)
                    continue
                }

                var request = URLRequest(url: remoteURL)
                for (field, value) in provider.streamAuthHeaders(forItemId: itemId) {
                    request.setValue(value, forHTTPHeaderField: field)
                }

                let baseProgress = completedFraction
                // Resume data only for ITS track (a resumed transfer ignores the
                // request URL — applied to another index it would store the
                // wrong audio under that file name).
                let resumeData = carriedResumeIndex == index ? carriedResumeData : nil
                if resumeData != nil { carriedResumeData = nil }
                controls[itemId]?.inFlightTrackIndex = index
                try await FileDownloader.shared.download(
                    request: request,
                    to: destination,
                    resumeData: resumeData,
                    onProgress: { fraction in
                        Task { @MainActor in
                            // -1 = indeterminate (no server size); pass the
                            // sentinel through instead of scaling it.
                            let value = fraction < 0 ? -1 : baseProgress + fraction * perTrackWeight
                            DownloadManager.shared.publishProgress(itemId: itemId, fraction: value)
                        }
                    },
                    onTask: { task in
                        Task { @MainActor in
                            DownloadManager.shared.controls[itemId]?.currentTask = task
                        }
                    }
                )
                controls[itemId]?.currentTask = nil

                // Exclude from iCloud/device backups — audiobooks are large and
                // don't belong in the iPhone backup.
                var destinationVar = destination
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                try? destinationVar.setResourceValues(resourceValues)

                completedFraction += perTrackWeight
            }

            // Save book details (chapters, duration, tracks) for real offline
            // opening — without it even a downloaded book would still need a
            // server request on open.
            saveDetail(item)

            // Fix extensions right away (ABS content URLs often carry no
            // extension; the real container decides what AVFoundation can play).
            Self.repairFolder(dir)

            // Self-heal the folder: drop duplicate-extension leftovers and
            // foreign files so the strict index mapping stays unambiguous.
            let keep = Set(Self.trackMap(in: dir).values.map(\.lastPathComponent))
            let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in all where !keep.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }

            // Persist the cover — survives iOS cache purges offline.
            await ImageCache.shared.makePersistent(
                itemId: itemId,
                coverURL: provider.coverURL(forItemId: itemId)
            )

            downloadedItemIds.insert(itemId)
            phase[itemId] = nil
            controls[itemId] = nil
            lastPublishedFraction[itemId] = nil
            recalculateTotalSize()
        } catch let cancelled as DownloadCancelledError {
            let progress = phase[itemId]?.progress ?? 0
            if controls[itemId]?.pendingCancel == true {
                // Abort: clear visible state, keep completed tracks on disk.
                phase[itemId] = nil
                controls[itemId] = nil
                lastPublishedFraction[itemId] = nil
            } else {
                // Pause: remember resume data for a mid-file continuation.
                let inFlight = controls[itemId]?.inFlightTrackIndex
                controls[itemId]?.resumeData = cancelled.resumeData
                controls[itemId]?.resumeTrackIndex = inFlight
                controls[itemId]?.pendingPause = false
                phase[itemId] = .paused(progress)
                // Reset the coalescing anchor so the first ticks after a resume
                // are published again (purely visual).
                lastPublishedFraction[itemId] = nil
            }
        } catch {
            // Keep partial files: the next attempt fetches only missing tracks.
            phase[itemId] = .failed(String(localized: "Download failed: \(error.localizedDescription)"))
            controls[itemId]?.currentTask = nil
            lastPublishedFraction[itemId] = nil
        }
    }

    /// Used storage of a book in bytes (0 if nothing is stored).
    func downloadSize(forItemId itemId: String) -> Int64 {
        let dir = itemDirectory(itemId)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func deleteAllDownloads() {
        for itemId in downloadedItemIds {
            deleteDownload(itemId: itemId)
        }
    }

    func deleteDownload(itemId: String) {
        try? FileManager.default.removeItem(at: itemDirectory(itemId))
        let metaURL = metadataDirectory.appendingPathComponent("\(itemId).json")
        try? FileManager.default.removeItem(at: metaURL)
        ImageCache.shared.removePersistent(itemId: itemId)
        downloadedItemIds.remove(itemId)
        recalculateTotalSize()
    }

    /// Y51 premium replacement: re-key a finished download from the old item id
    /// to its successor (folder + metadata move) so the file stays offline
    /// usable under the new id instead of orphaning. No-op unless the source is
    /// downloaded and the target is free. Returns whether an adoption happened.
    @discardableResult
    func adoptDownload(from oldItemId: String, to newItemId: String) -> Bool {
        guard downloadedItemIds.contains(oldItemId),
              !downloadedItemIds.contains(newItemId) else { return false }
        let fm = FileManager.default
        do {
            try fm.moveItem(at: itemDirectory(oldItemId), to: itemDirectory(newItemId))
        } catch {
            Logger.rss.error("download adopt failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let oldMeta = metadataDirectory.appendingPathComponent("\(oldItemId).json")
        let newMeta = metadataDirectory.appendingPathComponent("\(newItemId).json")
        try? fm.moveItem(at: oldMeta, to: newMeta)
        downloadedItemIds.remove(oldItemId)
        downloadedItemIds.insert(newItemId)
        return true
    }
}
