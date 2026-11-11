// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The offline song (GT 3.2): a server song that lies on the device as a
/// track of a downloaded album plays offline from a Mär list too, and the
/// player and the tile answer "is it here" at the one place.
@MainActor
struct OfflineSongTests {
    static func track(_ index: Int, _ songId: String, _ duration: Double) -> ABSAudioTrack {
        ABSAudioTrack(index: index, startOffset: Double(index) * 100, duration: duration,
                      contentUrl: songId, metadata: ABSFileMetadata(size: 1))
    }

    static func album(_ id: String, songs: [String], author: String = "Beispielband") -> LibraryItemDetail {
        LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Album \(id)", authorName: author, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: Double(songs.count) * 100,
                chapters: songs.enumerated().map { ABSChapter(id: $0.offset, start: Double($0.offset) * 100,
                                                              end: Double($0.offset + 1) * 100, title: "Titel \($0.element)") },
                tracks: songs.enumerated().map { track($0.offset, $0.element, 100 + Double($0.offset)) }),
            userMediaProgress: nil)
    }

    // MARK: - The rule

    @Test("Offline-Lied: ein Lied im fertigen Album- oder Playlist-Download desselben Servers ist gefunden, sonst nicht")
    func theIndexFindsHeldSongs() {
        let details = [
            "sub:album:A": Self.album("sub:album:A", songs: ["x", "y"]),
            "jf:playlist:P": Self.album("jf:playlist:P", songs: ["y"]),
            "sub:album:B": Self.album("sub:album:B", songs: ["z"]),
            "book-1": Self.album("book-1", songs: ["x"]),
        ]
        let index = SongInDownload.index(details: details,
                                         downloaded: ["sub:album:A", "jf:playlist:P", "book-1"])
        #expect(index["sub:song:x"] == .init(downloadId: "sub:album:A", trackIndex: 0))
        #expect(index["sub:song:y"] == .init(downloadId: "sub:album:A", trackIndex: 1))
        #expect(index["jf:song:y"] == .init(downloadId: "jf:playlist:P", trackIndex: 0),
                "the same raw id on the other server is another song")
        #expect(index["sub:song:z"] == nil, "an album that is not complete holds nothing")
        #expect(index.count == 3, "a book is no song holder: \(index)")
        #expect(ItemNamespace.songHolderNamespace("sub:album:A") == "sub:")
        #expect(ItemNamespace.songHolderNamespace("jf:playlist:P") == "jf:")
        #expect(ItemNamespace.songHolderNamespace("sub:song:x") == nil)
        #expect(ItemNamespace.songHolderNamespace("maerplaylist:1") == nil)
        #expect(ItemNamespace.isServerSong("jf:song:y") && ItemNamespace.isServerSong("sub:song:x"))
        #expect(!ItemNamespace.isServerSong("sub:album:A") && !ItemNamespace.isServerSong("rss:x:1"))
    }

    @Test("Offline-Lied: das Lied als eigener Titel, aus dem Album geschnitten: Dauer, Name, Kuenstler, ein Stueck")
    func theSongIsCutFromItsAlbum() throws {
        let holder = Self.album("sub:album:A", songs: ["x", "y"])
        let detail = try #require(SongInDownload.detail(songId: "sub:song:y",
                                                        place: .init(downloadId: "sub:album:A", trackIndex: 1),
                                                        in: holder))
        #expect(detail.id == "sub:song:y")
        #expect(detail.media.duration == 101)
        #expect(detail.media.metadata?.title == "Titel y")
        #expect(detail.media.metadata?.authorName == "Beispielband")
        #expect(detail.media.tracks?.count == 1)
        #expect(detail.media.tracks?.first?.startOffset == 0 && detail.media.tracks?.first?.contentUrl == "y")
        #expect(SongInDownload.detail(songId: "sub:song:q", place: .init(downloadId: "sub:album:A", trackIndex: 7),
                                      in: holder) == nil, "a track the detail does not hold is no song")
    }

    // MARK: - The one question, on a real downloader

    @Test("Offline-Lied: Spieler und Karte fragen dieselbe Stelle, ein Lied aus dem geladenen Album ist da und hat sein Detail")
    func playerAndTileAgree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-song-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let albumId = "sub:album:A"
        let folder = downloads.appendingPathComponent(albumId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64).write(to: folder.appendingPathComponent("0.mp3"))
        try Data(repeating: 7, count: 64).write(to: folder.appendingPathComponent("1.mp3"))
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let marks = try await KeyedRowStore<LibraryItemDetail>(connection: try database.connection(), table: .downloadMeta)
        _ = try await marks.replaceAll([albumId: Self.album(albumId, songs: ["x", "y"])])
        let manager = DownloadManager(documents: directory, database: database)
        await manager.ensureScanned()
        #expect(manager.downloadedItemIds == [albumId], "the precondition: the album is a complete download")

        #expect(manager.isDownloaded(itemId: "sub:song:y"), "the song of the album is here")
        #expect(!manager.isDownloaded(itemId: "sub:song:q"), "a song of no download is not")
        #expect(!manager.isDownloaded(itemId: "jf:song:y"), "the same raw id on the other server is not")
        #expect(!manager.isDeletableDownload(itemId: "sub:song:y"), "nothing of its own to delete")
        #expect(manager.downloadState(of: ["sub:song:y", "sub:song:x"]) == .init(anyHere: true, allHere: true),
                "a Mär list of the album's songs counts as here")
        let detail = try #require(manager.loadCachedDetail(forItemId: "sub:song:y"), "the player's start source")
        #expect(detail.media.tracks?.count == 1 && detail.media.duration == 101)
        #expect(manager.loadCachedDetail(forItemId: albumId)?.media.tracks?.count == 2, "the album's own stays")

        // Gone with the album: the index follows the set of downloads.
        manager.deleteDownload(itemId: albumId)
        #expect(!manager.isDownloaded(itemId: "sub:song:y"))
        #expect(manager.loadCachedDetail(forItemId: "sub:song:y") == nil)
    }

    @Test("Offline-Lied: die Datei des Liedes ist die Datei seines Stuecks im Album, als Stueck 0", .needsTheSources)
    func theFileIsTheAlbumsTrack() throws {
        let flat = try FetchAnswerTests.squeezedSource("Sources/Networking/DownloadManager.swift")
        #expect(flat.contains("let dir = itemDirectory(place.downloadId), let file = Self.trackMap(in: dir)[place.trackIndex] else { return [:] } return [0: file]"))
        #expect(flat.contains("if songPlace(itemId) != nil { return true }"), "the one question")
    }
}
#endif
