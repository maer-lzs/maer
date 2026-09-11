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

    private static func detail(_ id: String) -> LibraryItemDetail {
        LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Book \(id)", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 1234, chapters: nil, tracks: nil),
            userMediaProgress: nil)
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
}
#endif
