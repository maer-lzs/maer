// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import AVFoundation
import OSLog

/// Manages locally downloaded audiobooks. Each book gets its own subfolder
/// "Downloads/{itemId}/0.{ext}", "1.{ext}", …. Multi-file books (several audio
/// files instead of one M4B) are downloaded completely, not just the first
/// file. The associated book details (chapters, duration, track order) are
/// one row per book in `download_meta`, and that row is also the MARK that a
/// download is complete (landed after the last track, before the download
/// counts as finished). The documents of
/// the builds before ("DownloadsMeta/{itemId}.json") are poured once and
/// set aside.
///
/// The detail is the key to real offline listening: without it the app
/// would have to fetch chapters/duration from the server on every book open.
/// Even when the audio files are already present locally.
///
/// Deliberately a device-wide singleton like `KeychainStore`: downloads are a
/// device-storage concept, not a session-specific dependency.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager(
        documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        database: MaerDatabase.shared
    )

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

    /// Live control state of a running/paused download (in-memory only.
    /// After a relaunch, partial folders are picked up via resume-by-skip).
    private struct DownloadControl {
        var detail: LibraryItemDetail
        var currentTask: URLSessionDownloadTask?
        var pendingPause = false
        var pendingCancel = false
        var resumeData: Data?
        /// Track index the in-flight transfer belongs to. Binds `resumeData`
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
    /// Coalescing for progress publishes. URLSession reports every chunk, but
    /// publishing the @Published `phase` re-renders every observing view (all
    /// cover cells, episode rows, the library). Only meaningful steps go out.
    private var lastPublishedFraction: [String: Double] = [:]

    /// Publish a download fraction only when it moved ≥1% since the last
    /// publish (or reached the end). Cuts the invalidation storm during
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
    /// Cached instead of computed. The view reads it on every render; a disk
    /// scan per progress tick would be expensive.
    @Published private(set) var totalDownloadsSize: Int64 = 0

    /// The startup filesystem scan. Awaitable via `ensureScanned()` so
    /// IMPERATIVE consumers of `downloadedItemIds` in the launch window
    /// (offline path, CarPlay, maintenance) don't race the detached walk and
    /// see an empty set (that produced an empty library despite downloads).
    private var scanTask: Task<Void, Never>?

    /// Waits until the startup download scan has been merged (no-op afterwards).
    func ensureScanned() async {
        await scanTask?.value
    }

    /// The container's documents directory: `Downloads/` lives in it, and
    /// so did the documents of the builds before.
    private let documents: URL
    /// The one directory of the audio files, created and marked once.
    private let downloadsDirectory: URL
    private let keeper: RowKeeper<LibraryItemDetail>
    /// The details of every complete download, keyed by item id: the rows
    /// in memory, the mark of completion, and the offline start source.
    private var details: [String: LibraryItemDetail] = [:]

    init(documents: URL, database: MaerDatabase) {
        self.documents = documents
        self.downloadsDirectory = Self.prepareDownloadsDirectory(in: documents)
        self.keeper = RowKeeper(database: database, table: .downloadMeta, label: "DOWNLOADS")
        loadDetails()
        // The full filesystem walk (every download folder + every file's size)
        // used to run synchronously here. On the main actor, BEFORE first
        // paint, scaling with the number of downloads. Scan off-main instead
        // and publish the result one tick later.
        let downloadsDir = downloadsDirectory
        let marked = Set(details.keys)
        scanTask = Task { [weak self] in
            // detached because the filesystem walk runs off the MainActor before first paint
            let scan = await Task.detached(priority: .userInitiated) {
                Self.scanDownloads(downloadsDir: downloadsDir, marked: marked)
            }.value
            guard let self else { return }
            // Merge: a download finished while scanning must not be dropped.
            // But a download DELETED while scanning must not come back either
            // (the stale scan still contains it). Re-check the mark, the
            // criterion deleteDownload removes, at merge time.
            let stillPresent = scan.ids.filter { self.details[$0] != nil }
            self.downloadedItemIds.formUnion(stillPresent)
            self.totalDownloadsSize = stillPresent == scan.ids
                ? scan.totalSize
                : self.downloadedItemIds.reduce(0) { $0 + self.downloadSize(forItemId: $1) }
        }
    }

    /// The rows first; the documents of the builds before only when the rows
    /// hold nothing, poured once (keyed by their file name, the id the folder
    /// carries) and set aside. A failed row read falls back to the documents
    /// that were set aside, the living ones on top, and migrates nothing.
    private func loadDetails() {
        let start = keeper.startNow()
        var pouring: [URL] = []
        if let rows = start.rows {
            details = rows
        } else if start.failed {
            let (aside, _) = Self.readDocuments(in: metadataDirectory, suffix: ".json.migrated")
            let (living, _) = Self.readDocuments(in: metadataDirectory, suffix: ".json")
            details = aside.merging(living) { _, live in live }
        } else {
            let (found, files) = Self.readDocuments(in: metadataDirectory, suffix: ".json")
            details = found
            pouring = files
        }
        Logger.library.notice("DOWNLOADS start: marked=\(self.details.count) migrate=\(pouring.count)")
        if !pouring.isEmpty { keeper.pour(details, settingAside: pouring) }
    }

    /// Every document `<itemId><suffix>` in the directory, read through the
    /// seam (an unreadable one is kept aside there and skipped here). The
    /// file name is the id: an adopted download used to move only the file.
    private nonisolated static func readDocuments(in directory: URL, suffix: String)
        -> (details: [String: LibraryItemDetail], files: [URL]) {
        let ablage = Ablage(directory: directory)
        var found: [String: LibraryItemDetail] = [:]
        var files: [URL] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []   // tragbar, weil ein fehlendes Verzeichnis keine Dokumente hat
        for name in names where name.hasSuffix(suffix) {
            let itemId = String(name.dropLast(suffix.count))
            guard !itemId.isEmpty,
                  let detail = ablage.loadNow(LibraryItemDetail.self, name: name).value else { continue }
            found[itemId] = LibraryItemDetail(id: itemId, media: detail.media, userMediaProgress: detail.userMediaProgress)
            files.append(directory.appendingPathComponent(name))
        }
        return (found, files)
    }

    /// Creates `Downloads/` if needed and excludes it from iCloud and device
    /// backups, ONCE on the directory: audiobooks are large and do not belong
    /// in the iPhone backup, and the directory's mark covers every file
    /// written into it later. Set on every start, so installs from before
    /// (which marked file by file) carry it too. A failure is logged.
    private nonisolated static func prepareDownloadsDirectory(in documents: URL) -> URL {
        var dir = documents.appendingPathComponent("Downloads", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        } catch {
            Logger.library.error("DOWNLOADS directory prepare failed reason=\(String(describing: error), privacy: .public)")
        }
        return dir
    }

    /// Off-main startup scan: completed download ids (marked in the rows AND
    /// their folder present) plus their total size in one walk.
    private nonisolated static func scanDownloads(downloadsDir: URL, marked: Set<String>)
        -> (ids: Set<String>, totalSize: Int64) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: downloadsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return ([], 0) }
        var ids = Set<String>()
        var total: Int64 = 0
        for dir in dirs
        where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let itemId = dir.lastPathComponent
            // The mark is written only after a complete download. A folder
            // without a mark is an aborted remnant (kept for resume, not counted).
            guard marked.contains(itemId) else { continue }
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

    /// Free space iOS would grant for user-important data (more generous
    /// than plain free space. Includes purgeable caches).
    private func freeDiskBytes() -> Int64? {
        let values = try? downloadsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Where the documents of the builds before lived; read for the one-time
    /// pour and the fallback only, never created any more.
    private var metadataDirectory: URL {
        documents.appendingPathComponent("DownloadsMeta", isDirectory: true)
    }

    private func itemDirectory(_ itemId: String) -> URL {
        downloadsDirectory.appendingPathComponent(itemId, isDirectory: true)
    }

    // (The startup scan lives in `scanDownloads` above. Each book has its own
    // subfolder named after the item id; Audiobookshelf ids can contain
    // underscores, so folders avoid ambiguity when mapping files to books.)

    /// Can this play without a network? The name says „downloaded", the
    /// question is OFFLINE AVAILABILITY, and the two are not the same: an
    /// imported local file is available offline and was never downloaded.
    /// For the other question ask `isDeletableDownload`.
    func isDownloaded(itemId: String) -> Bool {
        // Offline available is what LIES here: an own file, or a completed
        // download. The rule used to read "cannot be downloaded, therefore
        // already here". Which is true for local files and false for every
        // stream. Catalogue items and radio carry no download capability
        // either, so they counted as offline available while nothing of them
        // plays without a network.
        if AppSession.shared.provider(for: itemId).capabilities.contains(.alwaysLocal) { return true }
        return downloadedItemIds.contains(itemId)
    }

    /// Did WE fetch this, so that deleting it frees space and gives something
    /// back? The question every „Delete Download" control has to ask.
    ///
    /// Six of them asked `isDownloaded` instead, which is true for an
    /// imported local file as well. On such a book the menu offered „Delete
    /// Download", the tap removed a `Downloads/` folder that never existed,
    /// the entry stayed, the control stayed, and nothing said a word. No file
    /// was lost (local audio lives in `LocalAudio/`, downloads in
    /// `Downloads/`), but a destructive control that does nothing and reports
    /// nothing is exactly what rule 3 forbids.
    ///
    /// Deliberately NOT „is it downloaded": the difference to the predicate
    /// above is the whole reason this exists, and a reader has to see it.
    func isDeletableDownload(itemId: String) -> Bool {
        downloadedItemIds.contains(itemId)
    }

    func isDownloading(itemId: String) -> Bool {
        if case .downloading = phase[itemId] { return true }
        return false
    }

    /// True if an incomplete download folder exists (aborted/failed earlier).
    /// A new download will only fetch the missing files.
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
            // Nothing in flight. Clear state directly.
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
    /// after a server rescan, hidden files). Track 0 became junk and
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
    /// An ID3 tag says NOTHING about the codec. It can prefix MP3 *or*
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
    /// AVFoundation trusts the extension. An MP3 stored as ".m4b" (ABS
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
        guard !AppStorageKeys.bool(AppStorageKeys.downloadExtensionRepairDone) else { return }
        Task { [weak self] in
            // Launch window: the startup scan may still be running. An empty
            // id set here would mark the one-time repair "done" without doing it.
            await self?.ensureScanned()
            guard let dirs = self?.downloadedItemIds.map({ self!.itemDirectory($0) }) else { return }
            // detached because the repair is disk work off the MainActor and must finish once started
            Task.detached(priority: .utility) {
                for dir in dirs {
                    Self.repairFolder(dir)
                }
                AppStorageKeys.set(true, for: AppStorageKeys.downloadExtensionRepairDone)
            }
        }
    }

    /// ONE-TIME deep validation (flagged): let AVFoundation itself verify
    /// every local track. The definitive check for files that pass the
    /// magic-byte sniff but still fail to parse (truncated legacy files,
    /// the source of lingering -12864 preload errors and silently skipped
    /// tracks). Unplayable files are deleted; the auto-heal re-downloads
    /// them the next time the book is opened.
    func performDeepValidation() {
        guard !AppStorageKeys.bool(AppStorageKeys.downloadDeepValidationDone) else { return }
        Task { [weak self] in
            await self?.ensureScanned()
            guard let self else { return }
            self.runDeepValidation(dirs: self.downloadedItemIds.map { self.itemDirectory($0) })
        }
    }

    private func runDeepValidation(dirs: [URL]) {
        // detached because the validation is disk work off the MainActor and must finish once started
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
            AppStorageKeys.set(true, for: AppStorageKeys.downloadDeepValidationDone)
        }
    }

    /// Local audio files of a COMPLETE download, keyed by track index.
    func localTrackMap(forItemId itemId: String) -> [Int: URL] {
        guard downloadedItemIds.contains(itemId) else { return [:] }
        return Self.trackMap(in: itemDirectory(itemId))
    }

    /// Cached book details (chapters, duration, tracks) for the offline case.
    /// Loaded when the server is unreachable but the book was downloaded locally.
    func loadCachedDetail(forItemId itemId: String) -> LibraryItemDetail? {
        details[itemId]
    }

    /// The cached detail is the START SOURCE of a
    /// downloaded book. And it was written exactly ONCE, at download time.
    /// Its progress therefore stayed frozen at whatever it was back then,
    /// forever. Generated data must not freeze a derived value. The flushed
    /// witness fixed only the case where THIS
    /// device pushed; a book downloaded here and listened to on ANOTHER
    /// device has no witness at all and still opened at 0 offline.
    ///
    /// Only the progress field is rewritten, deliberately: chapters, tracks
    /// and duration are the reason this file exists, and a partial answer
    /// must never shrink them.
    func updateCachedProgress(itemId: String, progress: MediaProgress) async {
        guard downloadedItemIds.contains(itemId),
              let existing = details[itemId] else { return }
        await saveDetail(LibraryItemDetail(id: existing.id, media: existing.media,
                                           userMediaProgress: progress))
    }

    /// The row is the mark of a complete download and the offline start
    /// source; the memory answers at once, the keeper writes the diff and
    /// logs a failure, and the next download writes the row again. The call
    /// returns only once the row has landed: a download counts as finished
    /// after its mark is on disk, or a kill between the last track and the
    /// write would leave a complete folder without a mark, counted as an
    /// aborted remnant at the next start. The register in `RowKeepers`
    /// covers the way into the background; this covers the kill after it.
    private func saveDetail(_ detail: LibraryItemDetail) async {
        details[detail.id] = detail
        keeper.write(details)
        await keeper.awaitPendingWrites()
    }

    /// Waits for every queued write of the rows (tests, teardown).
    func awaitPendingWrites() async {
        await keeper.awaitPendingWrites()
    }

    /// Downloads all tracks of a book (one for M4B books, several for multi-file
    /// books). Sequentially, with overall progress weighted across all tracks.
    /// Fetch an item's detail from ITS OWN source and start the download.
    ///
    /// Six surfaces wrote these three steps by hand, and they did not agree.
    /// Two asked the player coordinator for a provider, which answers for the
    /// library and not for the item, so an entry from another source got the
    /// wrong one. And all six swallowed a failed fetch with `try?` and a
    /// return: the button did nothing and said nothing, while the automatic
    /// download loop right next door caught the error and reported it.
    ///
    /// The failure travels the way every other download failure does, through
    /// `phase`, so every surface that already shows a download state shows
    /// this one too. No new channel for a case that has one.
    func startDownload(itemId: String) async {
        let provider = AppSession.shared.provider(for: itemId)
        do {
            let detail = try await provider.fetchItemDetail(itemId: itemId)
            await download(item: detail, provider: provider)
        } catch {
            phase[itemId] = .failed(String(localized: "Download failed: \(error.localizedDescription)"))
            Logger.library.error("DOWNLOAD detail fetch failed for \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func download(item: LibraryItemDetail, provider: any AudioProvider) async {
        guard !isDownloading(itemId: item.id) else { return }
        let tracks = (item.media.tracks ?? []).enumerated().sorted { l, r in
            // Stable: fall back to the original position when the server
            // index is missing/equal. Swift's sort is not stability-guaranteed,
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
        // excluded from the map. A re-download run replaces exactly those.
        if downloadedItemIds.contains(itemId),
           Self.trackMap(in: itemDirectory(itemId)).count >= tracks.count {
            return
        }
        // Fail fast when the disk clearly cannot hold the remaining tracks.
        // A mid-download abort would otherwise surface as a cryptic write
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
        // Carry mid-file resume data over from a pause. Used once, and ONLY
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
                // is known or exactly between two tracks. Honor it here, not
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
                // request URL. Applied to another index it would store the
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
                // The backup exclusion sits on the Downloads directory, once.

                completedFraction += perTrackWeight
            }

            // Save book details (chapters, duration, tracks) for real offline
            // opening. Without it even a downloaded book would still need a
            // server request on open. The row lands before anything below
            // runs; the cover persist can go to the network.
            await saveDetail(item)

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

            // Persist the cover. Survives iOS cache purges offline.
            await Artwork.persist(provider.coverURL(forItemId: itemId))

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
        // The mark leaves with the files, whether or not the folder went.
        details.removeValue(forKey: itemId)
        keeper.write(details)
        Artwork.forget(AppSession.shared.coverURL(forItemId: itemId))
        downloadedItemIds.remove(itemId)
        recalculateTotalSize()
    }

    /// The cover addresses of everything downloaded, for the cover store's
    /// maintenance: it keeps exactly these and returns the rest to the cache.
    var downloadedCoverURLs: [URL] {
        downloadedItemIds.compactMap { AppSession.shared.coverURL(forItemId: $0) }
    }

    /// Re-key a finished download from the old item id
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
        // The mark moves with the folder, and carries the new id inside (the
        // document used to keep the old one).
        if let old = details.removeValue(forKey: oldItemId) {
            details[newItemId] = LibraryItemDetail(id: newItemId, media: old.media,
                                                   userMediaProgress: old.userMediaProgress)
            keeper.write(details)
        }
        downloadedItemIds.remove(oldItemId)
        downloadedItemIds.insert(newItemId)
        return true
    }
}
