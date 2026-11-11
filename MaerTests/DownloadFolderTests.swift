// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The folder of a download is always one folder directly in the downloads,
/// whatever the item id holds: an episode's id carries the guid of its feed,
/// and a guid like `a/../../x` named a folder outside before. The name is
/// `folderName`, the id lies in `.item-id`, and a folder a build before
/// named by the id itself still counts. Every case runs over a documents
/// directory and a database file of its own.
@MainActor
struct DownloadFolderTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var downloads: URL { directory.appendingPathComponent("Downloads", isDirectory: true) }
        func manager() -> DownloadManager { DownloadManager(documents: directory, database: database) }
        /// The mark of a complete download, as a finished download writes it.
        func mark(_ id: String) async throws {
            let rows = try await KeyedRowStore<LibraryItemDetail>(connection: try database.connection(), table: .downloadMeta)
            _ = try await rows.apply(previous: [:], current: [id: DownloadFolderTests.detail(id)])
        }
        /// A folder at `folder` with one track of real sound (the folder's
        /// self-heal drops a file that does not read as audio). Its name.
        @discardableResult
        func plantTrack(in folder: URL) throws -> String {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let tone = try TickWorkTests().tone(seconds: 1)
            let name = "0.\(tone.pathExtension)"
            try FileManager.default.moveItem(at: tone, to: folder.appendingPathComponent(name))
            return name
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    private static func detail(_ id: String, tracks: [ABSAudioTrack]? = nil) -> LibraryItemDetail {
        LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Episode", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 60, chapters: nil, tracks: tracks),
            userMediaProgress: nil)
    }

    /// A source whose tracks have no address: the download loop skips them
    /// and ends at the mark.
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

    private static let escaping = "rss:k:a/../../x"

    /// The values a second implementation of the rule must give too.
    @Test("der Name eines Download-Ordners: sichere Zeichen, hoechstens 64, Bindestrich, 16 Hexzeichen")
    func theFolderName() {
        #expect(DownloadManager.folderName(of: Self.escaping) == "rss_k_a_______x-80a0e278a9898246")
        #expect(DownloadManager.folderName(of: "rss:k:https://ex.com/a.mp3") == "rss_k_https___ex_com_a_mp3-ee0cbade3a236da5")
        #expect(DownloadManager.folderName(of: "sub:album:62000") == "sub_album_62000-00f75ef2b217e2ec",
                "a short hash gets zeros in front")
        #expect(DownloadManager.folderName(of: "x🎧") == "x__-95c6332d0fa0b24b", "one sign per UTF-16 unit")
        #expect(DownloadManager.folderName(of: String(repeating: "a", count: 100))
                == String(repeating: "a", count: 64) + "-1900dafab04497b7")
        #expect(DownloadManager.folderName(of: "") == "-14650fb0739d0383")
        for id in [Self.escaping, "..", ".", "/", "a/b", "rss:k:https://ex.com/a.mp3"] {
            let name = DownloadManager.folderName(of: id)
            #expect(!name.contains("/") && !name.contains(".") && !name.contains(":"), "no separator in \(name)")
        }
    }

    @Test("eine Folge mit einer guid wie a/../../x laedt in einen Ordner direkt unter Downloads und loescht nichts ausserhalb")
    func anEscapingGuidStaysInTheDownloads() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let outside = home.directory.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))

        let manager = home.manager()
        await manager.ensureScanned()
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "/nowhere/0.m4b", metadata: nil)
        await manager.download(item: Self.detail(Self.escaping, tracks: [track]), provider: MarkOnlyProvider(), kind: nil)
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: Self.escaping))
        #expect(FileManager.default.fileExists(atPath: folder.path), "the load writes into its own folder")
        #expect(DownloadManager.itemId(ofFolder: folder) == Self.escaping, "the folder carries its id")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"],
                "nothing lands outside the downloads")

        manager.deleteDownload(itemId: Self.escaping)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path),
                "the delete leaves the folder outside alone")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "and removes the download's own")
    }

    @Test("ein Download in neuer Form zaehlt nach einem Neustart, gelesen aus .item-id")
    func aNewFolderCountsAfterARestart() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let id = "rss:k:https://ex.com/a.mp3"
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: id), isDirectory: true)
        let name = try home.plantTrack(in: folder)
        let bytes = try #require(try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent(name).path)[.size] as? Int64)
        #expect(DownloadManager.settle(folder, for: id))
        try await home.mark(id)

        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == [id])
        #expect(manager.totalDownloadsSize == bytes, "the .item-id is no part of the size")
        #expect(manager.localTrackMap(forItemId: id)[0]?.lastPathComponent == name)
    }

    @Test("ein alter Ordner, der die Kennung selbst als Namen traegt, gilt weiter und laesst sich loeschen")
    func anOldFolderStillCounts() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let id = "rss:k:episode-7"
        let old = home.downloads.appendingPathComponent(id, isDirectory: true)
        let name = try home.plantTrack(in: old)
        try await home.mark(id)

        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == [id], "no title is lost by the update")
        #expect(manager.localTrackMap(forItemId: id)[0]?.standardizedFileURL
                == old.appendingPathComponent(name).standardizedFileURL)
        manager.deleteDownload(itemId: id)
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    /// A build before named the folder of a guid with "/" by the raw id: the
    /// folder lay nested, the start walk saw only the outermost name, and the
    /// download counted as gone after a restart. The start moves it to its
    /// own name.
    @Test("ein verschachtelter Ordner einer guid mit Schraegstrich zaehlt nach dem Update wieder")
    func aNestedFolderIsFoundAgain() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let id = "rss:k:https://ex.com/a.mp3"
        let name = try home.plantTrack(in: home.downloads.appendingPathComponent(id, isDirectory: true))
        try await home.mark(id)

        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == [id], "the nested download counts")
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: id))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        #expect(DownloadManager.itemId(ofFolder: folder) == id)
    }

    @Test("ein Ordner, dessen .item-id eine andere Kennung nennt, zaehlt fuer keine")
    func aForeignIdFileIsRefused() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: "rss:k:one"), isDirectory: true)
        try home.plantTrack(in: folder)
        #expect(DownloadManager.settle(folder, for: "rss:k:two"))
        try await home.mark("rss:k:two")

        #expect(DownloadManager.itemId(ofFolder: folder) == nil)
        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds.isEmpty)
    }

    @Test("jede Stelle bekommt nur ein direktes Kind von Downloads")
    func everyFolderIsADirectChild() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        for id in [Self.escaping, "..", ".", "a/b", "", "rss:k:plain"] {
            let folder = try #require(DownloadManager.folder(of: id, in: home.downloads))
            #expect(folder.standardizedFileURL.deletingLastPathComponent().path == home.downloads.standardizedFileURL.path)
        }
    }
}
#endif
