// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The download marks as rows in `maer.sqlite`, one per book: a row is the
/// mark of a complete download and its offline start source; a folder
/// without a mark, or a mark without a folder, is not a download; a deleted download leaves its row; the Downloads
/// directory carries the backup exclusion. Every case runs over a documents
/// directory and a database file of its own.
@MainActor
struct DownloadManagerRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var downloads: URL { directory.appendingPathComponent("Downloads", isDirectory: true) }
        func manager() -> DownloadManager { DownloadManager(documents: directory, database: database) }
        func rows() throws -> [String: LibraryItemDetail] {
            guard let reader = try database.readerNow() else { return [:] }
            return try KeyedRowStore<LibraryItemDetail>.loadNow(table: .downloadMeta, reader: reader).rows
        }
        /// A finished download: a folder with bytes and, unless left out,
        /// its mark in the rows.
        func plant(_ id: String, bytes: Int, mark: Bool = true) async throws {
            let folder = downloads.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: folder.appendingPathComponent("0.m4b"))
            if mark {
                let rows = try await KeyedRowStore<LibraryItemDetail>(connection: try database.connection(), table: .downloadMeta)
                _ = try await rows.apply(previous: [:], current: [id: detail(id)])
            }
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    private static func detail(_ id: String, tracks: [ABSAudioTrack]? = nil) -> LibraryItemDetail {
        LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Book \(id)", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 1234, chapters: nil, tracks: tracks),
            userMediaProgress: nil)
    }

    /// A source whose tracks have no address: the download loop skips them
    /// and ends the way every download ends, at the mark.
    private final class MarkOnlyProvider: AudioProvider {
        var providerId: String { "mark-only" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            throw NSError(domain: "mark-only", code: 404)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("Zeile plus Ordner ist ein Download, jedes allein nicht")
    func aRowAndAFolderAreADownload() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.plant("done", bytes: 300)
        try await home.plant("remnant", bytes: 100, mark: false)

        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == ["done"], "a folder without a mark is an aborted remnant")
        #expect(manager.totalDownloadsSize == 300)
        #expect(manager.loadCachedDetail(forItemId: "done")?.media.duration == 1234)

        // A mark without its folder is not a download either.
        try FileManager.default.removeItem(at: home.downloads.appendingPathComponent("done", isDirectory: true))
        let again = home.manager()
        await again.ensureScanned()
        #expect(again.downloadedItemIds.isEmpty, "the folder is gone, the mark alone does not count")
        #expect(again.loadCachedDetail(forItemId: "done") != nil, "the row itself is left in place")
    }

    @Test("ein geloeschter Download verlaesst seine Zeile; der naechste Start kennt ihn nicht mehr")
    func aDeletedDownloadLeavesItsRow() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.plant("a", bytes: 10)
        try await home.plant("b", bytes: 20)
        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == ["a", "b"])
        manager.deleteDownload(itemId: "a")
        await manager.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == ["b"])
        #expect(!FileManager.default.fileExists(atPath: home.downloads.appendingPathComponent("a").path))
        let again = home.manager()
        await again.ensureScanned()
        #expect(again.downloadedItemIds == ["b"])
        #expect(again.totalDownloadsSize == 20)
    }

    @Test("die Regel fuer unfertige Downloads: geraeumt nur ohne Marke, ohne Lauf, mit gelesenen Marken und nach sieben Tagen")
    func theRemnantRule() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        let young = now.addingTimeInterval(-6 * 24 * 3600)
        #expect(DownloadManager.remnantClears(marksRead: true, complete: false, active: false, changed: old, now: now))
        #expect(!DownloadManager.remnantClears(marksRead: true, complete: false, active: false, changed: young, now: now))
        #expect(!DownloadManager.remnantClears(marksRead: true, complete: true, active: false, changed: old, now: now))
        #expect(!DownloadManager.remnantClears(marksRead: true, complete: false, active: true, changed: old, now: now))
        #expect(!DownloadManager.remnantClears(marksRead: false, complete: false, active: false, changed: old, now: now),
                "marks not read make every download look unfinished")
        #expect(!DownloadManager.remnantClears(marksRead: true, complete: false, active: false, changed: nil, now: now),
                "no age, no verdict")
    }

    @Test("ein unfertiger Download, sieben Tage unberuehrt, wird beim Start geraeumt; ein juengerer und ein fertiger bleiben")
    func anOldRemnantIsClearedAtStart() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.plant("done", bytes: 300)
        try await home.plant("old", bytes: 100, mark: false)
        try await home.plant("young", bytes: 100, mark: false)
        func age(_ id: String, days: Double) throws {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 24 * 3600)],
                                                  ofItemAtPath: home.downloads.appendingPathComponent(id).path)
        }
        try age("done", days: 30)
        try age("old", days: 8)
        try age("young", days: 6)
        let manager = home.manager()
        await manager.ensureScanned()
        await manager.awaitPendingWrites()
        func exists(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: home.downloads.appendingPathComponent(id).path)
        }
        #expect(!exists("old"), "a remnant untouched for eight days stays")
        #expect(exists("young"), "a remnant of six days was cleared")
        #expect(exists("done"), "a complete download was cleared")
        #expect(manager.downloadedItemIds == ["done"])
    }

    /// Between a resume and the start of its download `phase` is clear and
    /// `controls` stands. The folders turn old only after the start scan, so
    /// the clearing is run by hand, with a free remnant beside it to show
    /// the clearing does clear.
    @Test("ein unfertiger Download, der gerade fortgesetzt wird, wird nicht geraeumt, auch wenn er alt ist")
    func aResumingDownloadIsNeverCleared() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.plant("resuming", bytes: 100, mark: false)
        try await home.plant("free", bytes: 100, mark: false)
        let manager = home.manager()
        await manager.ensureScanned()
        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        for id in ["resuming", "free"] {
            try FileManager.default.setAttributes([.modificationDate: old],
                                                  ofItemAtPath: home.downloads.appendingPathComponent(id).path)
        }
        manager._testHoldAsResuming(Self.detail("resuming"))
        manager._testClearRemnants(["resuming": old, "free": old], now: Date())
        await manager.awaitPendingWrites()
        func exists(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: home.downloads.appendingPathComponent(id).path)
        }
        #expect(!exists("free"), "the free remnant of eight days stayed, so the clearing never ran")
        #expect(exists("resuming"), "a download being resumed was cleared")
    }

    /// The scan saw an old folder; it changed before the clearing. The age
    /// that decides is the one on the disk when clearing.
    @Test("das Alter wird beim Raeumen gelesen: ein Ordner, der seit dem Scan geaendert wurde, bleibt")
    func theAgeIsReadWhenClearing() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.plant("touched", bytes: 100, mark: false)
        try await home.plant("stale", bytes: 100, mark: false)
        let manager = home.manager()
        await manager.ensureScanned()
        let old = Date().addingTimeInterval(-8 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: home.downloads.appendingPathComponent("stale").path)
        manager._testClearRemnants(["touched": old, "stale": old], now: Date())
        await manager.awaitPendingWrites()
        func exists(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: home.downloads.appendingPathComponent(id).path)
        }
        #expect(!exists("stale"), "the stale remnant stayed, so the clearing never ran")
        #expect(exists("touched"), "a folder changed since the scan was cleared on the scan's age")
    }

    /// The line of a cleared remnant names its files and bytes; they come
    /// from here, so a complete download that lost its mark would show.
    @Test("ein Ordner wird mit Dateizahl und Bytes vermessen")
    func aFolderIsMeasured() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try await home.plant("rest", bytes: 100, mark: false)
        let folder = home.downloads.appendingPathComponent("rest", isDirectory: true)
        try Data(repeating: 1, count: 23).write(to: folder.appendingPathComponent("1.m4b"))
        let contents = DownloadManager.folderContents(folder)
        #expect(contents.files == 2)
        #expect(contents.bytes == 123)
        let empty = DownloadManager.folderContents(home.downloads.appendingPathComponent("absent"))
        #expect(empty.files == 0 && empty.bytes == 0, "a missing folder measures nothing")
    }

    @Test("das Downloads-Verzeichnis traegt das Backup-Zeichen")
    func theDirectoryCarriesTheExclusion() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let manager = home.manager()
        await manager.ensureScanned()
        let excluded = (try? home.downloads.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup
        #expect(excluded == true, "the exclusion sits on the directory")
    }

    @Test("die Marke landet, bevor der Download als fertig gilt: ein frischer Start liest sie ohne Warten")
    func theMarkLandsBeforeTheDownloadCountsAsFinished() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let manager = home.manager()
        await manager.ensureScanned()
        let book = Self.detail("fresh", tracks: [
            ABSAudioTrack(index: 0, startOffset: 0, duration: 1234, contentUrl: "/nowhere/0.m4b", metadata: nil)
        ])

        await manager.download(item: book, provider: MarkOnlyProvider(), kind: nil)
        #expect(manager.isDownloaded(itemId: "fresh"), "the download ended")
        // Read straight from the file, without awaitPendingWrites: the row
        // was on disk before the download counted as finished.
        #expect(Set(try home.rows().keys) == ["fresh"], "the mark landed before the state went to finished")
        let again = home.manager()
        await again.ensureScanned()
        #expect(again.downloadedItemIds == ["fresh"], "a fresh start counts the folder by its mark")

        // The progress rewrite takes the same door and has landed when it returns.
        await manager.updateCachedProgress(itemId: "fresh", progress: MediaProgress(
            currentTime: 42, duration: nil, progress: nil, isFinished: nil, lastUpdate: nil))
        #expect(try home.rows()["fresh"]?.userMediaProgress?.currentTime == 42,
                "landed before the call returned")
    }

    /// The kind a download is started as stays with it: a fresh start reads
    /// it back, deleting the download takes it away, and a download started
    /// without a kind has none (so no mass deletion reaches it).
    @Test("die Art eines Downloads wird beim Start festgehalten, ueberlebt einen Neustart und geht mit dem Loeschen")
    func theKindIsRecordedAndSurvivesAndLeavesWithTheDownload() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let manager = home.manager()
        await manager.ensureScanned()
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "/nowhere/0.m4b", metadata: nil)

        await manager.download(item: Self.detail("sub:album:7", tracks: [track]),
                               provider: MarkOnlyProvider(), kind: .audiobooks)
        await manager.download(item: Self.detail("sub:album:8", tracks: [track]),
                               provider: MarkOnlyProvider(), kind: nil)
        #expect(manager.kinds == ["sub:album:7": .audiobooks], "ohne Art wird nichts festgehalten")

        let again = home.manager()
        #expect(again.kinds == ["sub:album:7": .audiobooks], "die Art ueberlebt einen Neustart")

        manager.deleteDownload(itemId: "sub:album:7")
        #expect(manager.kinds.isEmpty, "die Art geht mit dem Download")
        #expect(home.manager().kinds.isEmpty, "und auch aus der Ablage")
    }

    /// A source that names an original as its large cover, the way the
    /// catalogue names an archive item's while the session holds its files.
    /// The host does not exist, so storing the covers asks no real server.
    private final class OriginalCoverProvider: AudioProvider {
        static let grid = URL(string: "https://covers.invalid/services/img/session-witness")!
        static let original = URL(string: "https://covers.invalid/download/session-witness/front.jpg")!
        var providerId: String { "original-cover" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            throw NSError(domain: "original-cover", code: 404)
        }
        func coverURL(forItemId itemId: String) -> URL? { Self.grid }
        func largeCoverURL(forItemId itemId: String) -> URL? { Self.original }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("nach einem Neustart und nach einem Wechsel des Servers nennen Fegelauf und Loeschen die Cover, die der Download sicherte")
    func aRestartStillNamesTheKeptOriginal() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let grid = OriginalCoverProvider.grid
        let original = OriginalCoverProvider.original

        let manager = home.manager()
        await manager.ensureScanned()
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "/nowhere/0.mp3", metadata: nil)
        await manager.download(item: Self.detail("lva:session-witness", tracks: [track]),
                               provider: OriginalCoverProvider(), kind: nil)
        #expect(manager.isDownloaded(itemId: "lva:session-witness"), "the precondition: the download ended")

        // A restart: the session builds only the item image service again.
        let again = home.manager()
        let active = await again.activeCovers(address: { _ in grid }, largeAddress: { _ in grid },
                                              idMovePending: { false })
        #expect(active.urls.contains(original), "the maintenance names the kept original: \(active.urls)")
        #expect(active.urls.contains(grid))

        // Another server's client names its own host for the same id; the
        // covers the download kept stay among the active ones.
        let other = try #require(URL(string: "https://other-server.example/cover/session-witness"))
        let switched = await again.activeCovers(address: { _ in other }, largeAddress: { _ in other },
                                                idMovePending: { false })
        #expect(switched.urls.contains(grid) && switched.urls.contains(original),
                "after a switch the maintenance names the kept covers: \(switched.urls)")

        again.deleteDownload(itemId: "lva:session-witness")
        #expect(DownloadManager.readSessionCovers(from: Ablage(directory: home.directory)).isEmpty,
                "the remembered original leaves with the download")
    }
}
#endif
