// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The download marks as rows in `maer.sqlite`, one per book: a row is the
/// mark of a complete download and its offline start source; the documents
/// of the builds before are poured into the rows once (keyed by file name)
/// and set aside; a folder without a mark, or a mark without a folder, is
/// not a download; a deleted download leaves its row; the Downloads
/// directory carries the backup exclusion. Every case runs over a documents
/// directory and a database file of its own.
@MainActor
struct DownloadManagerRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var downloads: URL { directory.appendingPathComponent("Downloads", isDirectory: true) }
        var meta: URL { directory.appendingPathComponent("DownloadsMeta", isDirectory: true) }
        func manager() -> DownloadManager { DownloadManager(documents: directory, database: database) }
        func rows() throws -> [String: LibraryItemDetail] {
            guard let reader = try database.readerNow() else { return [:] }
            return try KeyedRowStore<LibraryItemDetail>.loadNow(table: .downloadMeta, reader: reader).rows
        }
        /// A finished download of the builds before: a folder with bytes and
        /// its document beside it.
        func plant(_ id: String, bytes: Int, document: Bool = true) throws {
            let folder = downloads.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: folder.appendingPathComponent("0.m4b"))
            if document {
                try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
                try JSONEncoder().encode(detail(id)).write(to: meta.appendingPathComponent("\(id).json"))
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

    @Test("die Dokumente werden einmal in die Zeilen gegossen und beiseitegelegt; Zeile plus Ordner ist ein Download, jedes allein nicht")
    func documentsArePouredOnceAndSetAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try home.plant("done", bytes: 300)
        try home.plant("remnant", bytes: 100, document: false)

        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == ["done"], "a folder without a mark is an aborted remnant")
        #expect(manager.totalDownloadsSize == 300)
        #expect(manager.loadCachedDetail(forItemId: "done")?.media.duration == 1234)
        await manager.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == ["done"])
        let document = home.meta.appendingPathComponent("done.json")
        let aside = document.appendingPathExtension("migrated")
        #expect(!FileManager.default.fileExists(atPath: document.path))
        #expect(FileManager.default.fileExists(atPath: aside.path), "set aside, never deleted")
        #expect(DocumentMigration.isExcludedFromBackup(aside))

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
        try home.plant("a", bytes: 10)
        try home.plant("b", bytes: 20)
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

    @Test("das Downloads-Verzeichnis traegt das Backup-Zeichen einmal; ein unlesbares Dokument bleibt beiseite und zaehlt nicht")
    func theDirectoryCarriesTheExclusionAndCorruptStaysAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try home.plant("broken", bytes: 5, document: false)
        try FileManager.default.createDirectory(at: home.meta, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: home.meta.appendingPathComponent("broken.json"))

        let manager = home.manager()
        await manager.ensureScanned()
        #expect(DocumentMigration.isExcludedFromBackup(home.downloads), "the exclusion sits on the directory")
        #expect(manager.downloadedItemIds.isEmpty, "unreadable is not a mark")
        await manager.awaitPendingWrites()
        #expect(try home.rows().isEmpty, "nothing was poured")
        #expect(FileManager.default.fileExists(atPath: home.meta.appendingPathComponent("broken.json.corrupt").path),
                "the unreadable file is preserved by the seam, never migrated")
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
}
#endif
