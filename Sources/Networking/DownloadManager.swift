// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// Manages locally downloaded audiobooks. Each book gets its own subfolder
/// "Downloads/{itemId}/0.{ext}", "1.{ext}", …. Multi-file books (several audio
/// files instead of one M4B) are downloaded completely, not just the first
/// file. The associated book details (chapters, duration, track order) are
/// one row per book in `download_meta`, and that row is also the MARK that a
/// download is complete (landed after the last track, before the download
/// counts as finished).
///
/// The detail is the key to real offline listening: without it the app
/// would have to fetch chapters/duration from the server on every book open.
/// Even when the audio files are already present locally.
///
/// Deliberately a device-wide singleton like `KeychainStore`: downloads are a
/// device-storage concept, not a session-specific dependency.
@MainActor
final class DownloadManager {
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
        /// The source this download began with: a resume asks it, never the
        /// source of whichever download started last. Weak, so a source
        /// that is gone is gone here too.
        weak var provider: (any AudioProvider)?
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

    /// The two notifiers. The manager itself is observed by nobody: a
    /// progress step used to wake every observer, also the ones that only
    /// read which items are downloaded (measured: 104 wakes for a download
    /// of 100 steps). A view observes the notifier it reads.
    let stock = DownloadStock()
    let progress = DownloadProgress()
    static var stock: DownloadStock { shared.stock }
    static var progress: DownloadProgress { shared.progress }

    private(set) var downloadedItemIds: Set<String> {
        get { stock.downloadedItemIds }
        set { stock.downloadedItemIds = newValue }
    }
    /// Phase per book: downloading (weighted progress), paused, or failed.
    private(set) var phase: [String: DownloadPhase] {
        get { progress.phase }
        set { progress.phase = newValue }
    }
    private var controls: [String: DownloadControl] = [:]
    /// Coalescing for progress publishes. URLSession reports every chunk, but
    /// publishing the @Published `phase` re-renders every observing view (all
    /// cover cells, episode rows, the library). Only meaningful steps go out.
    private var lastPublishedFraction: [String: Double] = [:]

    /// Publish a download fraction only when `ProgressPublishRule` says so:
    /// at least one percent since the last publish, the end, or the switch
    /// to "size unknown" once. Cuts the invalidation storm during downloads
    /// from dozens per second to about a hundred per download.
    private func publishProgress(itemId: String, fraction: Double) {
        var current: Double?
        if case .downloading(let shown) = phase[itemId] { current = shown }
        switch ProgressPublishRule.outcome(current: current,
                                           lastPublished: lastPublishedFraction[itemId],
                                           fraction: fraction) {
        case .skip:
            return
        case .indeterminate:
            phase[itemId] = .downloading(-1)
        case .fraction(let value):
            lastPublishedFraction[itemId] = value
            phase[itemId] = .downloading(value)
        }
    }
    /// Cached instead of computed. The view reads it on every render; a disk
    /// scan per progress tick would be expensive.
    private(set) var totalDownloadsSize: Int64 {
        get { stock.totalDownloadsSize }
        set { stock.totalDownloadsSize = newValue }
    }

    /// The startup filesystem scan. Awaitable via `ensureScanned()` so
    /// IMPERATIVE consumers of `downloadedItemIds` in the launch window
    /// (offline path, CarPlay, maintenance) don't race the detached walk and
    /// see an empty set (that produced an empty library despite downloads).
    private var scanTask: Task<Void, Never>?

    /// Waits until the startup download scan has been merged (no-op afterwards).
    func ensureScanned() async {
        await scanTask?.value
    }

    /// The one directory of the audio files, created and marked once.
    private let downloadsDirectory: URL
    private let keeper: RowKeeper<LibraryItemDetail>
    /// Whether the start missed marks (`RowChain.startIncomplete`).
    var startIncomplete: Bool { keeper.startIncomplete }
    /// The details of every complete download, keyed by item id: the rows
    /// in memory, the mark of completion, and the offline start source.
    private var details: [String: LibraryItemDetail] = [:]

    /// The kind each download was started as, named by the surface that
    /// started it. A Subsonic or Jellyfin title carries a music prefix
    /// whether it is an album or a book, and only the surface knows which tab
    /// it stands in; asked later, the answer would depend on a loaded
    /// library. Kept in its own small file beside the downloads, so it
    /// survives a restart and needs nothing loaded. A download started
    /// without a kind has none, and no deletion per kind reaches it.
    private(set) var kinds: [String: DownloadKind] = [:]
    /// The last walk could not list the download folder: what the manager
    /// knows of its downloads is then incomplete.
    private(set) var scanUnreadable = false
    /// The kinds are a document of the app, so they go through the seam.
    private let kindsAblage: Ablage
    nonisolated static let kindsDocument = "download-kinds.json"
    /// The cover addresses a download kept when it was stored, per item
    /// (`keptCoverURLs`). The addresses built now can name other ones: an
    /// archive item names its original only while the session holds its
    /// files, and after a switch of the music server the client of the new
    /// server names its own host. This small document beside the kinds lets
    /// the delete and the cover maintenance name the kept covers after a
    /// restart and after a switch.
    private var sessionCovers: [String: [URL]] = [:]
    nonisolated static let sessionCoversDocument = "download-covers.json"

    init(documents: URL, database: MaerDatabase) {
        self.downloadsDirectory = Self.prepareDownloadsDirectory(in: documents)
        self.keeper = RowKeeper(database: database, table: .downloadMeta, label: "DOWNLOADS")
        self.kindsAblage = Ablage(directory: documents)
        loadDetails()
        kinds = Self.readKinds(from: kindsAblage)
        let readCovers = Self.readSessionCovers(from: kindsAblage)
        sessionCovers = Self.keptForm(readCovers)
        // A document of an earlier build kept the sign-in parts of the
        // addresses: rewritten at once without them.
        if sessionCovers != readCovers { writeSessionCovers() }
        // The full filesystem walk (every download folder + every file's size)
        // used to run synchronously here. On the main actor, BEFORE first
        // paint, scaling with the number of downloads. Scan off-main instead
        // and publish the result one tick later.
        let downloadsDir = downloadsDirectory
        let marked = Set(details.keys)
        // A mark without tracks says nothing about the files: not counted.
        let expected = details.compactMapValues { $0.media.tracks?.count }.filter { $0.value > 0 }
        scanTask = Task { [weak self] in
            // detached because the filesystem walk runs off the MainActor before first paint
            let scan = await Task.detached(priority: .userInitiated) {
                Self.scanDownloads(downloadsDir: downloadsDir, marked: marked, expected: expected)
            }.value
            guard let self else { return }
            self.scanUnreadable = !scan.readable
            // Merge: a download finished while scanning must not be dropped.
            // But a download DELETED while scanning must not come back either
            // (the stale scan still contains it). Re-check the mark, the
            // criterion deleteDownload removes, at merge time.
            let stillPresent = scan.ids.filter { self.details[$0] != nil }
            self.downloadedItemIds.formUnion(stillPresent)
            if stillPresent == scan.ids, self.downloadedItemIds == scan.ids {
                // The walk already measured every folder, off the main actor.
                self.stock.setSizes(scan.sizes)
            } else {
                self.recalculateTotalSize()
            }
            self.clearOldRemnants(scan.remnants, now: Date())
            self.hasScanned = true
        }
    }

    /// Whether the startup scan is merged, so `downloadedItemIds` names every
    /// download. Before it, a question "is this not downloaded" has no answer.
    private(set) var hasScanned = false

    /// The one kind the source of this title serves today, if it serves only
    /// one (`DownloadKind.sole`). Read now, never stored. For downloads from
    /// before the kind was recorded.
    func soleKind(of itemId: String) -> DownloadKind? {
        DownloadKind.sole(servedTypes: source(of: itemId).mediaTypes)
    }

    /// The source that answers for this title, by its id. One question, asked
    /// by the kind, the local check and the start of a download.
    private func source(of itemId: String) -> any AudioProvider {
        AppSession.shared.provider(for: itemId)
    }

    /// The recorded kinds, or none. A missing document is the normal first
    /// start. An unreadable one lies aside as `.corrupt` (the seam's rule) and
    /// reads as none: every title then stands without a kind, which no mass
    /// deletion reaches, so the failure costs a sorting and never a download.
    /// An unknown kind name is left out rather than guessed.
    nonisolated static func readKinds(from ablage: Ablage) -> [String: DownloadKind] {
        (ablage.loadNow([String: String].self, name: kindsDocument).value ?? [:])
            .compactMapValues(DownloadKind.init(rawValue:))
    }

    /// The remembered session covers, or none. A missing or unreadable
    /// document reads as none (the seam logs and lays aside an unreadable
    /// one): the delete and the maintenance then name only the forms built
    /// now. An address that does not parse is left out.
    nonisolated static func readSessionCovers(from ablage: Ablage) -> [String: [URL]] {
        (ablage.loadNow([String: [String]].self, name: sessionCoversDocument).value ?? [:])
            .mapValues { $0.compactMap(URL.init(string:)) }
            .filter { !$0.value.isEmpty }
    }

    /// The kept covers in the form the document holds: each address without
    /// its sign-in parts (`ImageCache.addressWithoutSignIn`). It names the
    /// same file, and no token, key or salt reaches the disk.
    nonisolated static func keptForm(_ covers: [String: [URL]]) -> [String: [URL]] {
        covers.mapValues { urls in
            var kept: [URL] = []
            for url in urls.map(ImageCache.addressWithoutSignIn) where !kept.contains(url) { kept.append(url) }
            return kept
        }
    }

    /// Written right away, like the kinds.
    private func writeSessionCovers() {
        do {
            try kindsAblage.saveNow(Self.keptForm(sessionCovers).mapValues { $0.map(\.absoluteString) },
                                    name: Self.sessionCoversDocument)
        } catch {
            // Dropping is bearable, because the seam has already logged the
            // failure, and a cover that is not remembered only loses its
            // protection at the next maintenance.
        }
    }

    /// Remembers the kept covers of a stored download, or forgets the entry
    /// when it has none.
    func noteSessionCovers(of itemId: String, grid: URL?, large: URL?) {
        let urls = Self.keptForm([itemId: Self.keptCoverURLs(grid: grid, large: large)])[itemId] ?? []
        let entry: [URL]? = urls.isEmpty ? nil : urls
        guard sessionCovers[itemId] != entry else { return }
        sessionCovers[itemId] = entry
        writeSessionCovers()
    }

    /// Written right away: the document is small, and a new manager on the
    /// same folder reads it back at once.
    private func writeKinds() {
        do {
            try kindsAblage.saveNow(kinds.mapValues(\.rawValue), name: Self.kindsDocument)
        } catch {
            // Dropping is bearable, because the seam has already logged the
            // failure, and a kind that did not land only means the title
            // stands without one, which no deletion per kind reaches.
        }
    }

    /// The rows; a failed read starts empty with the base unknown.
    private func loadDetails() {
        // A Gutenberg title downloaded before its rules existed reads
        // readable too (`FreeCatalog.gutenbergReadable`).
        details = (keeper.startNow() ?? [:]).mapValues(FreeCatalog.gutenbergReadable)
        // Marks read after a failed start join the ones this run wrote; a
        // download this run marked again is the newer mark.
        keeper.adopt = { [weak self] read in
            guard let self else { return }
            self.details = RowKeeper.union(read: read.mapValues(FreeCatalog.gutenbergReadable), run: self.details)
            self.songIndexFor = nil
        }
        Logger.library.notice("DOWNLOADS start: marked=\(self.details.count)")
    }

    /// Creates `Downloads/` if needed and excludes it from iCloud and device
    /// backups, ONCE on the directory: audiobooks are large and do not belong
    /// in the iPhone backup, and the directory's mark covers every file
    /// written into it later. Set on every start, so installs from before
    /// (which marked file by file) carry it too. A failure is logged.
    private nonisolated static func prepareDownloadsDirectory(in documents: URL) -> URL {
        let dir = documents.appendingPathComponent("Downloads", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            BackupExclusion.mark(dir, label: "downloads")
        } catch {
            Logger.library.error("DOWNLOADS directory prepare failed reason=\(String(describing: error), privacy: .public)")
        }
        return dir
    }

    /// Off-main startup scan: completed download ids (marked in the rows AND
    /// their folder present) plus the size of each in one walk.
    /// The walk over the download folders. `readable` is false when the
    /// folder itself could not be listed: then the empty answer means
    /// "unknown", never "no downloads". `remnants` are the folders without
    /// a mark, with the moment they were last changed.
    /// Whether a download lies whole: every track of the title as a file
    /// of its index. One count for the end of a download and the start.
    nonisolated static func isComplete(trackCount: Int, present: Set<Int>) -> Bool {
        trackCount > 0 && Set(0..<trackCount).isSubset(of: present)
    }

    /// `expected` holds the number of tracks of each marked title; a marked
    /// folder that lacks one is no download (a build before the count
    /// marked it), counts as a remnant and can be loaded again.
    nonisolated static func scanDownloads(downloadsDir: URL, marked: Set<String>, expected: [String: Int] = [:])
        -> (ids: Set<String>, sizes: [String: Int64], readable: Bool, remnants: [String: Date]) {
        let dirs: [URL]
        do {
            dirs = try FileManager.default.contentsOfDirectory(
                at: downloadsDir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        } catch {
            Logger.library.error("DOWNLOADS scan unreadable reason=\(String(describing: error), privacy: .public)")
            return ([], [:], false, [:])
        }
        var ids = Set<String>()
        var sizes: [String: Int64] = [:]
        var remnants: [String: Date] = [:]
        for dir in dirs
        where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let itemId = dir.lastPathComponent
            // The mark is written only after a complete download. A folder
            // without a mark is an aborted remnant (kept for resume, not counted).
            guard marked.contains(itemId) else {
                if let changed = lastChanged(dir) { remnants[itemId] = changed }
                continue
            }
            if let count = expected[itemId], !isComplete(trackCount: count, present: Set(trackMap(in: dir).keys)) {
                Logger.library.error("DOWNLOADS marked but not whole, can be loaded again tracks=\(count) present=\(trackMap(in: dir).count)")
                if let changed = lastChanged(dir) { remnants[itemId] = changed }
                continue
            }
            ids.insert(itemId)
            sizes[itemId] = folderContents(dir).bytes
        }
        return (ids, sizes, true, remnants)
    }

    /// The files directly in a download folder and their bytes.
    nonisolated static func folderContents(_ dir: URL) -> (files: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let bytes = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (files.count, bytes)
    }

    /// When a download folder last changed, read from the disk now (a fresh
    /// URL, so no cached value); nil when it cannot be read.
    nonisolated static func lastChanged(_ dir: URL) -> Date? {
        (try? URL(fileURLWithPath: dir.path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// How long an unfinished download is kept for a resume.
    nonisolated static let remnantKeepSeconds: TimeInterval = 7 * 24 * 3600

    /// Whether an unfinished download folder is cleared at the start: the
    /// marks were read, there is no mark of a complete download, nothing runs
    /// or is paused for it in this session, and it is untouched for seven
    /// days. Marks not read make every complete download look unfinished,
    /// so then nothing is cleared; a folder whose last change is unknown
    /// stays too: no age, no verdict.
    nonisolated static func remnantClears(marksRead: Bool, complete: Bool, active: Bool,
                                          changed: Date?, now: Date) -> Bool {
        guard marksRead, !complete, !active, let changed else { return false }
        return now.timeIntervalSince(changed) >= remnantKeepSeconds
    }

    /// Whether a download runs, is paused or is being resumed for this item
    /// in this session. A resume clears `phase` before its download starts
    /// while `controls` stands, so both are asked.
    private func downloadHolds(_ itemId: String) -> Bool {
        phase[itemId] != nil || controls[itemId] != nil
    }

    /// The remnants of the start scan that are old enough go through the one
    /// delete of the downloads, with a line per folder: its size and file
    /// count tell a complete download that lost its mark from a remnant.
    /// The scan's age only picks the candidates: a folder can change between
    /// the scan and now, so the age that decides is read when clearing.
    private func clearOldRemnants(_ remnants: [String: Date], now: Date) {
        let marksRead = !startIncomplete
        var old: [String: Date] = [:]
        for (itemId, scanned) in remnants
        where Self.remnantClears(marksRead: marksRead, complete: false, active: false, changed: scanned, now: now) {
            let changed = Self.lastChanged(itemDirectory(itemId))
            if Self.remnantClears(marksRead: marksRead, complete: details[itemId] != nil,
                                  active: downloadHolds(itemId), changed: changed, now: now),
               let changed {
                old[itemId] = changed
            }
        }
        guard !old.isEmpty else { return }
        for (itemId, changed) in old {
            let contents = Self.folderContents(downloadsDirectory.appendingPathComponent(itemId, isDirectory: true))
            let days = Int(now.timeIntervalSince(changed) / 86_400)
            Logger.library.notice("DOWNLOADS remnant cleared item=\(itemId, privacy: .private(mask: .hash)) files=\(contents.files) bytes=\(contents.bytes) untouched=\(days)d")
        }
        deleteDownloads(Set(old.keys))
    }

    #if DEBUG
    /// For witnesses: a download held as between a resume and its start
    /// (`controls` stands, `phase` is clear), and the clearing of the start
    /// scan run on remnants handed in.
    func _testHoldAsResuming(_ detail: LibraryItemDetail) { controls[detail.id] = DownloadControl(detail: detail) }
    /// For witnesses: a download paused with the source it began with.
    func _testHoldAsPaused(_ detail: LibraryItemDetail, provider: (any AudioProvider)?) {
        controls[detail.id] = DownloadControl(detail: detail, provider: provider)
        phase[detail.id] = .paused(0)
    }
    func _testClearRemnants(_ remnants: [String: Date], now: Date) { clearOldRemnants(remnants, now: now) }
    #endif

    /// The size of every download, measured on the disk, and their sum. Run
    /// after every way that changes a download's files, so `sizeByItem` is
    /// the disk's answer and no view has to walk a folder while it renders.
    private func recalculateTotalSize() {
        sizeMeasurements += 1
        stock.setSizes(Dictionary(uniqueKeysWithValues: downloadedItemIds.map { ($0, downloadSize(forItemId: $0)) }))
    }

    /// How often the sizes were measured, for the witnesses: a pass that
    /// moved no complete download measures nothing.
    private(set) var sizeMeasurements = 0

    /// Free space iOS would grant for user-important data (more generous
    /// than plain free space. Includes purgeable caches).
    private func freeDiskBytes() -> Int64? {
        let values = try? downloadsDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
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
        if source(of: itemId).capabilities.contains(.alwaysLocal) { return true }
        // A server song that lies here as a track of a downloaded album or
        // playlist is here too. The player and the tile both ask this line.
        if songPlace(itemId) != nil { return true }
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
        guard case .paused = phase[itemId], let control = controls[itemId] else { return }
        guard let provider = control.provider else {
            // The source this download began with is gone: the title says
            // so instead of staying paused without a way on.
            Logger.library.notice("DOWNLOAD resume without its source: \(itemId, privacy: .public)")
            controls[itemId] = nil
            phase[itemId] = .failed(String(localized: "Not available on this device: the source is not set up here"))
            return
        }
        // Clear the paused phase so the isDownloading guard lets us restart.
        phase[itemId] = nil
        // The kind recorded at the start carries over; resuming names none.
        Task { await download(item: control.detail, provider: provider, kind: kinds[itemId]) }
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
        if case .audio(let ext) = sniffAudio(url) { return ext }
        return nil
    }

    /// What the first bytes of a file say: its audio container, no audio at
    /// all, or nothing, because the file could not be read. A read that
    /// fails is no verdict about the file.
    nonisolated enum AudioSniff: Equatable {
        case audio(String)
        case notAudio
        case unreadable
    }

    nonisolated static func sniffAudio(_ url: URL) -> AudioSniff {
        let handle: FileHandle
        let head: Data
        do {
            handle = try FileHandle(forReadingFrom: url)
            head = try handle.read(upToCount: 12) ?? Data()
        } catch {
            return .unreadable
        }
        defer { try? handle.close() }
        guard head.count >= 4 else { return .notAudio }
        let b = [UInt8](head)
        // MP4/M4A/M4B: "ftyp" at offset 4
        if head.count >= 8, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return .audio("m4b") }
        if Array(b[0..<4]) == [0x66, 0x4C, 0x61, 0x43] { return .audio("flac") }
        if Array(b[0..<4]) == [0x4F, 0x67, 0x67, 0x53] { return .audio("ogg") }
        if Array(b[0..<4]) == [0x52, 0x49, 0x46, 0x46] { return .audio("wav") }
        if Array(b[0..<4]) == [0x46, 0x4F, 0x52, 0x4D] { return .audio("aiff") }
        if Array(b[0..<4]) == [0x63, 0x61, 0x66, 0x66] { return .audio("caf") }
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33, head.count >= 10 {
            // ID3v2: syncsafe tag size at bytes 6-9; frame header follows.
            let tagSize = (Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])
            let frame: Data
            do {
                try handle.seek(toOffset: UInt64(10 + tagSize))
                frame = try handle.read(upToCount: 2) ?? Data()
            } catch {
                return .unreadable
            }
            guard frame.count == 2 else { return .notAudio }
            return classifyFrameSync([UInt8](frame)).map { .audio($0) } ?? .notAudio
        }
        return classifyFrameSync(b).map { .audio($0) } ?? .notAudio
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
    /// returns the playable URL; nil for non-audio garbage. A file that
    /// cannot be read keeps its name and stays: the folder's self-heal
    /// removes what is not in the track map, and a read error must never
    /// make a good track garbage.
    nonisolated static func repairedAudioURL(_ url: URL) -> URL? {
        let real: String
        switch sniffAudio(url) {
        case .audio(let ext): real = ext
        case .notAudio: return nil
        case .unreadable:
            Logger.library.error("DOWNLOAD sniff unreadable file=\(url.lastPathComponent, privacy: .public), kept as it is")
            return url
        }
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

    /// Local audio files of a COMPLETE download, keyed by track index. A
    /// server song held in another download gets its one file as track 0.
    func localTrackMap(forItemId itemId: String) -> [Int: URL] {
        if downloadedItemIds.contains(itemId) { return Self.trackMap(in: itemDirectory(itemId)) }
        guard let place = songPlace(itemId),
              let file = Self.trackMap(in: itemDirectory(place.downloadId))[place.trackIndex] else { return [:] }
        return [0: file]
    }

    /// Cached book details (chapters, duration, tracks) for the offline case.
    /// Loaded when the server is unreachable but the book was downloaded locally.
    /// A server song held in another download gets its one-track detail cut
    /// from that download's.
    func loadCachedDetail(forItemId itemId: String) -> LibraryItemDetail? {
        if let own = details[itemId] { return own }
        guard let place = songPlace(itemId), let holder = details[place.downloadId] else { return nil }
        return SongInDownload.detail(songId: itemId, place: place, in: holder)
    }

    /// Where a server song lies inside a complete download, if it does. The
    /// index is rebuilt when the set of complete downloads changes, which is
    /// also when a detail arrives or leaves (`saveDetail` precedes the mark),
    /// and when `rekey` rewrites the songs of a download that stays.
    private func songPlace(_ itemId: String) -> SongInDownload.Place? {
        guard ItemNamespace.isServerSong(itemId) else { return nil }
        let downloaded = downloadedItemIds
        if songIndexFor != downloaded {
            songIndex = SongInDownload.index(details: details, downloaded: downloaded)
            songIndexFor = downloaded
        }
        return songIndex[itemId]
    }
    private var songIndex: [String: SongInDownload.Place] = [:]
    private var songIndexFor: Set<String>?

    /// What of several ids is here, by the one rule per id. For a tile that
    /// stands for more than one download (a Mär playlist); asked by views
    /// that observe `stock` themselves.
    func downloadState(of ids: [String]) -> PlaylistPresentation.DownloadState {
        PlaylistPresentation.downloadState(downloaded: ids.map { isDownloaded(itemId: $0) })
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
        keeper.write(emptying: .refused) { [weak self] in self?.details }
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
    func startDownload(itemId: String, kind: DownloadKind) async {
        let provider = source(of: itemId)
        do {
            let detail = try await provider.fetchItemDetail(itemId: itemId)
            await download(item: detail, provider: provider, kind: kind)
        } catch {
            phase[itemId] = .failed(String(localized: "Download failed: \(ErrorSentence.of(error))"))
            Logger.library.error("DOWNLOAD detail fetch failed for \(itemId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// `kind` is the kind the surface that starts the download shows the
    /// title as. `nil` only where no surface is involved (the player healing
    /// its own tracks); such a download is left out of every deletion per
    /// kind and falls only with its own delete or with deleting everything.
    func download(item: LibraryItemDetail, provider: any AudioProvider, kind: DownloadKind?) async {
        guard !isDownloading(itemId: item.id) else { return }
        if let kind, kinds[item.id] != kind {
            kinds[item.id] = kind
            writeKinds()
        }
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
        // A sign-in the tracks need that cannot be read now sends nothing
        // without it, and nothing failed: no request, no phase. A later
        // start asks again; the automatic run picks every episode it wants
        // that is not on the disk.
        guard provider.streamAuthHeaders(forItemId: itemId) != nil else {
            Logger.library.notice("DOWNLOAD waits, the sign-in cannot be read now: \(itemId, privacy: .public)")
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

        // Carry mid-file resume data over from a pause. Used once, and ONLY
        // for the exact track it was captured from (see resumeTrackIndex).
        var carriedResumeData = controls[itemId]?.resumeData
        let carriedResumeIndex = controls[itemId]?.resumeTrackIndex
        controls[itemId] = DownloadControl(detail: item, provider: provider, resumeData: nil)
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
                let stated = TrackFileSize.stated(
                    track.metadata?.size, downloadsTheOriginalFile: provider.capabilities.contains(.downloadsTheOriginalFile))
                // A source that may transcode holds the file to its size only
                // once the answer shows the original (Subsonic states a type).
                let claim = stated == nil
                    ? TrackFileSize.claim(size: track.metadata?.size, contentType: track.metadata?.contentType) : nil

                // Resume-by-skip: tracks from an earlier attempt are kept,
                // unless one holds fewer bytes than its source states; that
                // one is loaded again.
                if let existing = existingTracks[index] {
                    let bytes = TrackFileSize.bytes(at: existing)
                    let verdict = TrackFileSize.verdict(bytes: bytes, stated: stated)
                    if verdict == .short {
                        Logger.library.error("DOWNLOAD resume short track=\(index) bytes=\(bytes ?? 0) stated=\(stated ?? 0), loaded again")
                        // bearable, because the new download replaces the file and a file left here is held to its size again before it plays
                        try? FileManager.default.removeItem(at: existing)
                    } else {
                        // A size that cannot be read is no verdict: the track stays.
                        if verdict == .unread {
                            Logger.library.error("DOWNLOAD resume size unread track=\(index) stated=\(stated ?? 0), kept")
                        }
                        completedFraction += perTrackWeight
                        phase[itemId] = .downloading(completedFraction)
                        continue
                    }
                }

                var request = URLRequest(url: remoteURL)
                // The headers for THIS address: a sign-in bound to a host
                // travels only there. A sign-in that stops being readable
                // between two tracks holds the download like a pause: the
                // track is not requested without it.
                guard let trackHeaders = provider.streamAuthHeaders(forItemId: itemId, to: remoteURL) else {
                    Logger.library.notice("DOWNLOAD holds, the sign-in cannot be read now: \(itemId, privacy: .public) track=\(index)")
                    throw DownloadCancelledError(resumeData: nil)
                }
                for (field, value) in trackHeaders {
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
                    statedBytes: stated,
                    claim: claim,
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

            // Loaded means every track lies here as a file: a track the
            // source gave no address for, or that did not land, makes the
            // download fail, and the title does not count as offline.
            let present = Set(Self.trackMap(in: dir).keys)
            guard Self.isComplete(trackCount: tracks.count, present: present) else {
                Logger.library.error("DOWNLOADS incomplete tracks=\(tracks.count) present=\(present.count), not marked")
                throw URLError(.resourceUnavailable)
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

            // Persist the cover in both forms (`keptCoverURLs`). Survives iOS
            // cache purges offline. Both forms are remembered beside the
            // downloads (`noteSessionCovers`), so a later session or another
            // server's client still names them.
            let grid = provider.coverURL(forItemId: itemId)
            let large = provider.largeCoverURL(forItemId: itemId)
            for url in Self.keptCoverURLs(grid: grid, large: large) {
                await Artwork.persist(url)
            }
            noteSessionCovers(of: itemId, grid: grid, large: large)

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
            // Keep partial files: the next attempt fetches only missing tracks,
            // and a track that ended with resume data (a silent host, the
            // session's resource limit) continues at its byte, as after a pause.
            if let data = Self.resumeData(of: error) {
                let inFlight = controls[itemId]?.inFlightTrackIndex
                controls[itemId]?.resumeData = data
                controls[itemId]?.resumeTrackIndex = inFlight
            }
            phase[itemId] = .failed(String(localized: "Download failed: \(ErrorSentence.of(error))"))
            controls[itemId]?.currentTask = nil
            lastPublishedFraction[itemId] = nil
        }
    }

    /// The resume data a failed download left: from the silence rule, or
    /// in the error's own information (the resource limit).
    nonisolated static func resumeData(of error: Error) -> Data? {
        if let silent = error as? SilentHostError { return silent.resumeData }
        return (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
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
        deleteDownloads(downloadedItemIds)
    }

    func deleteDownload(itemId: String) {
        deleteDownloads([itemId])
    }

    /// Deletes several downloads with one write of the marks, one of the
    /// kinds and one measurement: per item they made a delete of many a
    /// freeze of many walks over every folder.
    func deleteDownloads(_ itemIds: Set<String>) {
        guard !itemIds.isEmpty else { return }
        var kindsChanged = false
        var sessionCoversChanged = false
        for itemId in itemIds {
            try? FileManager.default.removeItem(at: itemDirectory(itemId))
            // The mark leaves with the files, whether or not the folder went.
            details.removeValue(forKey: itemId)
            if kinds.removeValue(forKey: itemId) != nil { kindsChanged = true }
            let owner = source(of: itemId)
            for url in coverURLs(of: itemId, grid: owner.coverURL(forItemId: itemId),
                                 large: owner.largeCoverURL(forItemId: itemId)) {
                Artwork.forget(url)
            }
            if sessionCovers.removeValue(forKey: itemId) != nil { sessionCoversChanged = true }
            downloadedItemIds.remove(itemId)
        }
        // The marks leave with the deleted downloads, the last one too.
        keeper.write(emptying: .allowed) { [weak self] in self?.details }
        if kindsChanged { writeKinds() }
        if sessionCoversChanged { writeSessionCovers() }
        recalculateTotalSize()
    }

    /// The covers the downloads hold, for the cover store's maintenance: the
    /// answer to "which covers are active?". It waits for the scan (before
    /// it, no download is known), and it counts every download whose cover
    /// address cannot be built now (a music title while its server's client
    /// is missing), because then the answer is incomplete and nothing may
    /// be demoted on it. The answer is incomplete as well while a music
    /// download waits for Navidrome's id move (`movePending`): the address
    /// built now names the new form, the kept cover still stands under the
    /// old one until the move renames it. And it is incomplete when the walk
    /// could not list the download folder or the start could not read the
    /// marks: zero downloads then is no answer, it is a blind spot.
    struct ActiveCovers: Sendable {
        let urls: [URL]
        let unresolved: Int
        let movePending: Bool
        /// The folder walk or the marks could not be read, all of them or a
        /// row that did not decode: the downloads then are "unknown", and
        /// nothing may be demoted on it.
        var unreadable = false
        var knowsAll: Bool { unresolved == 0 && !movePending && !unreadable }
    }

    /// The covers a download keeps: the grid's form and the large views'
    /// form where they differ. The large form alone is not enough: an
    /// archive item names its original only while the session holds it
    /// (`FreeCatalogProvider.largeCoverURL`), and after a restart both views
    /// ask the item image service until the files are read again.
    nonisolated static func keptCoverURLs(grid: URL?, large: URL?) -> [URL] {
        var urls: [URL] = []
        for url in [grid, large].compactMap({ $0 }) where !urls.contains(url) { urls.append(url) }
        return urls
    }

    /// Every cover a download holds: the forms built now and the ones it
    /// kept when it was stored.
    private func coverURLs(of itemId: String, grid: URL?, large: URL?) -> [URL] {
        var urls = Self.keptCoverURLs(grid: grid, large: large)
        let builtKept = urls.map(ImageCache.addressWithoutSignIn)
        for url in sessionCovers[itemId] ?? [] where !builtKept.contains(url) { urls.append(url) }
        return urls
    }

    func activeCovers(address: (String) -> URL? = { AppSession.shared.coverURL(forItemId: $0) },
                      largeAddress: (String) -> URL? = { AppSession.shared.largeCoverURL(forItemId: $0) },
                      idMovePending: () -> Bool = { NavidromeRekeyRun.isPending() }) async -> ActiveCovers {
        await ensureScanned()
        let itemIds = downloadedItemIds.sorted()
        var urls: [URL] = []
        var unresolved = 0
        for itemId in itemIds {
            guard let url = address(itemId) else { unresolved += 1; continue }
            urls += coverURLs(of: itemId, grid: url, large: largeAddress(itemId))
        }
        let movePending = itemIds.contains(where: SubsonicProvider.owns(itemId:)) && idMovePending()
        return ActiveCovers(urls: urls, unresolved: unresolved, movePending: movePending,
                            unreadable: scanUnreadable || keeper.startIncomplete)
    }

    /// Re-key a finished download from the old item id
    /// to its successor (folder + metadata move) so the file stays offline
    /// usable under the new id instead of orphaning. No-op unless the source is
    /// downloaded and the target is free. Returns whether an adoption happened.
    @discardableResult
    func adoptDownload(from oldItemId: String, to newItemId: String) -> Bool {
        guard let kindMoved = moveDownload(from: oldItemId, to: newItemId) else { return false }
        keeper.write(emptying: .refused) { [weak self] in self?.details }
        if kindMoved { writeKinds() }
        // The folder moved whole: its size moves with the key.
        recalculateTotalSize()
        return true
    }

    /// The move itself, without the stock's writes and measurement, so a
    /// pass over many downloads pays those once. Nil when nothing moved;
    /// otherwise whether a kind moved along.
    private func moveDownload(from oldItemId: String, to newItemId: String) -> Bool? {
        guard downloadedItemIds.contains(oldItemId),
              !downloadedItemIds.contains(newItemId) else { return nil }
        do {
            try FileManager.default.moveItem(at: itemDirectory(oldItemId), to: itemDirectory(newItemId))
        } catch {
            Logger.rss.error("download adopt failed: \(FailureReason.of(error), privacy: .public)")
            return nil
        }
        // The mark moves with the folder, and carries the new id inside (the
        // document used to keep the old one).
        if let old = details.removeValue(forKey: oldItemId) {
            details[newItemId] = LibraryItemDetail(id: newItemId, media: old.media,
                                                   userMediaProgress: old.userMediaProgress)
        }
        // The kind moves with the download, or the successor would fall out
        // of its kind's deletion.
        var kindMoved = false
        if let kind = kinds.removeValue(forKey: oldItemId) {
            kinds[newItemId] = kind
            kindMoved = true
        }
        // The remembered session covers move too, or the delete and the
        // maintenance of the successor would miss them.
        if let covers = sessionCovers.removeValue(forKey: oldItemId) {
            sessionCovers[newItemId] = covers
            writeSessionCovers()
        }
        downloadedItemIds.remove(oldItemId)
        downloadedItemIds.insert(newItemId)
        return kindMoved
    }

    /// Whether a complete download would move under `map`.
    func wouldMove(_ map: (String) -> String) -> Bool {
        details.keys.contains { map($0) != $0 }
    }

    /// Moves every complete download to the ids `map` gives (folder, mark
    /// and kind) and rewrites the song ids in its tracks; then every folder
    /// without a mark, an interrupted download, whose resume finds its parts
    /// by the folder name alone. A download whose new id is already taken
    /// stays under its old one. The marks, the kinds and the sizes are
    /// written and measured once for the whole pass. `onMove` hears every
    /// complete download that moved, so what hangs on its id beside the
    /// folder (the persistent cover) can follow. Returns how many downloads
    /// changed and how many there are; nil while the start could not read
    /// the marks, which may name downloads the memory lacks.
    func rekey(_ map: (String) -> String,
               onMove: (_ oldId: String, _ newId: String) -> Void = { _, _ in }) -> (changed: Int, total: Int)? {
        if keeper.startReadFailed { return nil }
        let total = details.count
        var changed = 0
        var marksChanged = false
        var kindsChanged = false
        var moved = false
        for oldId in details.keys.sorted() {
            let newId = map(oldId)
            if newId != oldId {
                guard let kindMoved = moveDownload(from: oldId, to: newId) else {
                    Logger.library.notice("REKEY download stays under its old id: the new one is taken or the move failed")
                    continue
                }
                marksChanged = true
                moved = true
                if kindMoved { kindsChanged = true }
                onMove(oldId, newId)
            }
            guard let detail = details[newId] else { continue }
            let rekeyed = NavidromeRekey.downloadDetail(detail, id: newId, holder: oldId, map)
            if rekeyed != detail {
                details[newId] = rekeyed
                marksChanged = true
            }
            if newId != oldId || rekeyed != detail { changed += 1 }
        }
        let remnants = rekeyRemnants(map)
        if marksChanged {
            keeper.write(emptying: .refused) { [weak self] in self?.details }
            songIndexFor = nil
        }
        if kindsChanged { writeKinds() }
        // Only a complete download is measured: an interrupted one is no
        // download (`downloadedItemIds`), so its move changes no size.
        if moved { recalculateTotalSize() }
        // A folder that could not be listed is "not now": the pass stays
        // open and runs again, what moved above stays moved.
        guard let remnants else { return nil }
        if remnants.found > 0 {
            Logger.library.notice("REKEY interrupted downloads moved=\(remnants.moved) stayed=\(remnants.found - remnants.moved)")
        }
        return (changed + remnants.moved, total + remnants.found)
    }

    /// The folders without a mark (interrupted downloads, kept for resume)
    /// move to the ids `map` gives, so a resume under the new id finds its
    /// parts. One that is downloading or held for a resume right now
    /// (`phase` or `controls`: a resume clears the phase before its download
    /// runs), or whose new folder exists, stays. Returns how many such
    /// folders there were and how many moved; nil when the folder of the
    /// downloads exists but could not be listed. A missing one holds none.
    private func rekeyRemnants(_ map: (String) -> String) -> (found: Int, moved: Int)? {
        let fm = FileManager.default
        let folders: [String]
        if fm.fileExists(atPath: downloadsDirectory.path) {
            do {
                folders = try fm.contentsOfDirectory(atPath: downloadsDirectory.path)
            } catch {
                Logger.library.error("REKEY interrupted downloads not listed, the pass runs again: \(FailureReason.of(error), privacy: .public)")
                return nil
            }
        } else {
            folders = []
        }
        var found = 0
        var moved = 0
        for oldId in folders.sorted() where details[oldId] == nil && !downloadedItemIds.contains(oldId) {
            let newId = map(oldId)
            guard newId != oldId else { continue }
            found += 1
            guard !downloadHolds(oldId),
                  !fm.fileExists(atPath: itemDirectory(newId).path) else { continue }
            do {
                try fm.moveItem(at: itemDirectory(oldId), to: itemDirectory(newId))
                moved += 1
            } catch {
                Logger.library.error("REKEY interrupted download not moved: \(FailureReason.of(error), privacy: .public)")
            }
        }
        return (found, moved)
    }
}

/// The downloaded stock: which items are here and how big they are. It
/// changes when a download finishes, is deleted, moves, or the disk is
/// scanned, never on a progress step. Written only by `DownloadManager`.
@MainActor
final class DownloadStock: ObservableObject {
    @Published fileprivate(set) var downloadedItemIds: Set<String> = []
    @Published fileprivate(set) var totalDownloadsSize: Int64 = 0
    /// The size of each download as the disk had it at the last change of
    /// its files; the sum is `totalDownloadsSize`.
    @Published fileprivate(set) var sizeByItem: [String: Int64] = [:]

    fileprivate func setSizes(_ sizes: [String: Int64]) {
        sizeByItem = sizes
        totalDownloadsSize = sizes.values.reduce(0, +)
    }
}

/// The progress of running downloads, one step per percent. Written only by
/// `DownloadManager`. Nobody observes it whole: a view observes the object
/// of ITS item (`item(_:)`), which notifies only when that item's phase
/// changes, so a cover wakes for its own download and no other.
@MainActor
final class DownloadProgress {
    fileprivate(set) var phase: [String: DownloadManager.DownloadPhase] = [:] {
        didSet {
            for id in Set(oldValue.keys).union(phase.keys) where oldValue[id] != phase[id] {
                items[id]?.object?.phase = phase[id]
            }
        }
    }

    /// Held weakly: an item's object lives as long as a view holds it. It
    /// can leave this table only when nobody holds it any more, so a view
    /// that took it before a download ended sees how it ended.
    private struct Held { weak var object: ItemDownloadProgress? }
    private var items: [String: Held] = [:]

    func item(_ itemId: String) -> ItemDownloadProgress {
        if let held = items[itemId]?.object { return held }
        let made = ItemDownloadProgress(phase: phase[itemId])
        items[itemId] = Held(object: made)
        // Entries whose views are gone are dropped now and then, never one
        // that is still held.
        if items.count > 256 { items = items.filter { $0.value.object != nil } }
        return made
    }
}

/// The phase of ONE item's download, for the views that show it.
@MainActor
final class ItemDownloadProgress: ObservableObject {
    @Published fileprivate(set) var phase: DownloadManager.DownloadPhase?

    fileprivate init(phase: DownloadManager.DownloadPhase?) { self.phase = phase }
}
