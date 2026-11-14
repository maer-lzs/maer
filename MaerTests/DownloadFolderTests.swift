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
/// and a guid like `a/../../x` taken as the name is a folder outside. The
/// name is `folderName`, the id lies in `.item-id`, and an older folder
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
    @Test("the name of a download folder: safe characters, at most 64, hyphen, 16 hex characters")
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

    @Test("an episode with a guid like a/../../x loads into a folder directly under Downloads and deletes nothing outside")
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
        // A folder outside that is not there yet: the load makes none.
        let unborn = home.directory.appendingPathComponent("y", isDirectory: true)
        await manager.download(item: Self.detail("rss:k:a/../../y", tracks: [track]), provider: MarkOnlyProvider(), kind: nil)
        #expect(!FileManager.default.fileExists(atPath: unborn.path), "the load makes no folder outside the downloads")

        manager.deleteDownload(itemId: Self.escaping)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path),
                "the delete leaves the folder outside alone")
        #expect(!FileManager.default.fileExists(atPath: folder.path), "and removes the download's own")
    }

    @Test("a download in the new form counts after a restart, read from .item-id")
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

    /// The end of a download drops every file of the folder that is no
    /// track. The id file stays, or the next start reads the folder by its
    /// name and the download counts for no id.
    @Test("the cleanup at the end of a download leaves the id of the folder in place")
    func theIdFileOutlivesTheEndOfADownload() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let id = "rss:k:https://ex.com/b.mp3"
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: id), isDirectory: true)
        try home.plantTrack(in: folder)
        let leftover = folder.appendingPathComponent("notes.txt")
        try Data("left over".utf8).write(to: leftover)

        let manager = home.manager()
        await manager.ensureScanned()
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "/nowhere/0.m4b", metadata: nil)
        await manager.download(item: Self.detail(id, tracks: [track]), provider: MarkOnlyProvider(), kind: nil)
        #expect(manager.downloadedItemIds == [id], "the precondition: the download ends whole")
        #expect(!FileManager.default.fileExists(atPath: leftover.path), "the precondition: the folder is cleared of what is no track")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(DownloadManager.idFileName).path))
        #expect(DownloadManager.itemId(ofFolder: folder) == id)
        #expect(manager.localTrackMap(forItemId: id)[0] != nil, "the track stays")
    }

    @Test("an old folder that carries the id itself as its name still counts and can be deleted")
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

    /// An older folder of a guid with "/" is named by the raw id and lies
    /// nested: the start walk sees only the outermost name. The start moves
    /// it to its own name, and the download counts.
    @Test("a nested folder of a guid with a slash counts again after the update")
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
        #expect(!FileManager.default.fileExists(atPath: home.downloads.appendingPathComponent("rss:k:https:").path),
                "the emptied folders the nested one lay in stay")
    }

    @Test("a folder whose .item-id names another id counts for none")
    func aForeignIdFileIsRefused() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: "rss:k:one"), isDirectory: true)
        try home.plantTrack(in: folder)
        #expect(DownloadManager.settle(folder, for: "rss:k:two"))
        try await home.mark("rss:k:two")

        #expect(DownloadManager.itemId(ofFolder: folder) == nil)
        #expect(DownloadManager.itemId(ofFolder: folder, known: DownloadManager.knownFolders(of: ["rss:k:one"])) == nil,
                "a file that names another id is refused for a marked folder too")
        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds.isEmpty)
    }

    @Test("a finished download whose folder does not carry the id counts through its recorded id")
    func aMarkedFolderWithoutItsIdFileCounts() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let id = "rss:k:https://ex.com/c.mp3"
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: id), isDirectory: true)
        try home.plantTrack(in: folder)
        try await home.mark(id)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(DownloadManager.idFileName).path),
                "the precondition: the folder carries no id file")

        let manager = home.manager()
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == [id], "a whole download is no remnant because its id file is missing")
        #expect(DownloadManager.itemId(ofFolder: folder) == folder.lastPathComponent, "without a mark the folder stands for its name")
    }

    @Test("a folder that cannot carry its id is a failed download, and a file that is too long is not read")
    func aFolderThatCannotCarryItsIdFailsTheDownload() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        // Longer than the id file may be: the folder cannot be settled.
        let id = "rss:k:" + String(repeating: "a", count: DownloadManager.idFileLimit)
        let folder = home.downloads.appendingPathComponent(DownloadManager.folderName(of: id), isDirectory: true)
        try home.plantTrack(in: folder)

        let manager = home.manager()
        await manager.ensureScanned()
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "/nowhere/0.m4b", metadata: nil)
        await manager.download(item: Self.detail(id, tracks: [track]), provider: MarkOnlyProvider(), kind: nil)
        #expect(!manager.downloadedItemIds.contains(id), "a download counts whose folder does not carry its id")
        #expect(manager.phase[id] == .failed(String(localized: "Download failed")))

        // The same id written by another hand is not read back.
        try Data(id.utf8).write(to: folder.appendingPathComponent(DownloadManager.idFileName))
        #expect(DownloadManager.itemId(ofFolder: folder) == nil, "an id file past the limit is read")
        #expect(!DownloadManager.settle(folder, for: id))
    }

    @Test("every place gets only a direct child of Downloads")
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
