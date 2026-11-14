// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The songs of a catalogue album come from one list at the catalogue: in
/// order, from one metadata answer for the whole release, and a song that
/// builds nothing is named instead of dropping out. The page plays the rest
/// and writes the count in its log line. A tile's long-press Shuffle whose
/// count fails plays the release as its one title and logs the failure.
@MainActor
struct CatalogAlbumSongsTests {
    private static func release(_ names: [String], collection: String? = nil) throws -> ArchiveDecoder.MetadataResponse {
        let files = names.map { "{\"name\": \"\($0).mp3\", \"length\": \"60\", \"title\": \"Song \($0)\", \"format\": \"VBR MP3\"}" }
        let collectionField = collection.map { ", \"collection\": [\"\($0)\"]" } ?? ""
        let json = "{\"files\": [\(files.joined(separator: ","))], \"metadata\": {\"title\": \"Witness Release\"\(collectionField)}}"
        return try ArchiveDecoder.decodeMetadata(Data(json.utf8))
    }

    private static func freshAlbum() -> String { "lva:album-songs-witness-\(UUID().uuidString)" }

    @Test("all songs from an answer in order, a missing one is named")
    func songsInOrderAndTheMissingNamed() async throws {
        let album = Self.freshAlbum()
        let meta = try Self.release(["a", "b", "c"])
        var asked = 0
        let answer = await FreeCatalogProvider.shared.albumSongs(albumId: album, count: 4) { _ in
            asked += 1
            return meta
        }
        #expect(asked == 1, "the release was asked once per song")
        #expect(answer.songs.map(\.id) == (0..<3).map { CatalogSongID.make(album: album, index: $0) })
        #expect(answer.songs.map(\.title) == ["Song a", "Song b", "Song c"])
        #expect(answer.songs.allSatisfy { $0.media?.tracks?.count == 1 }, "a song is not one track")
        #expect(answer.missing == [3])
    }

    @Test("without an answer what the session already holds plays, the rest is named")
    func withoutAnAnswerTheHeldSongsStay() async throws {
        let album = Self.freshAlbum()
        let meta = try Self.release(["a", "b"])
        _ = await FreeCatalogProvider.shared.albumSongs(albumId: album, count: 1) { _ in meta }
        var asked = 0
        let answer = await FreeCatalogProvider.shared.albumSongs(albumId: album, count: 2) { _ in
            asked += 1
            throw URLError(.notConnectedToInternet)
        }
        #expect(answer.songs.map(\.id) == [CatalogSongID.make(album: album, index: 0)])
        #expect(answer.missing == [1])
        #expect(asked == 1)
    }

    @Test("without a count an answer counts and builds the songs, a title outside the archive asks nothing")
    func withoutTheCountOneAnswerCountsAndBuilds() async throws {
        let album = Self.freshAlbum()
        let meta = try Self.release(["a", "b", "c"])
        var asked = 0
        let songs = await ArchiveMusicLoader.albumSongs(albumId: album) { _ in
            asked += 1
            return meta
        }
        #expect(asked == 1, "the count and the songs came from two answers")
        #expect(songs.map(\.id) == (0..<3).map { CatalogSongID.make(album: album, index: $0) })
        var foreign = 0
        #expect(await ArchiveMusicLoader.albumSongs(albumId: "jam:1234") { _ in foreign += 1; return meta }.isEmpty)
        #expect(foreign == 0, "a title outside the archive asked the archive")
    }

    @Test("without an answer the held songs stay, without songs the tile plays the title")
    func withoutAnAnswerTheTileKeepsItsHeldSongs() async throws {
        let album = Self.freshAlbum()
        let meta = try Self.release(["a", "b"])
        _ = await FreeCatalogProvider.shared.albumSongs(albumId: album, count: 2) { _ in meta }
        let held = await ArchiveMusicLoader.albumSongs(albumId: album) { _ in throw URLError(.notConnectedToInternet) }
        #expect(held.map(\.id) == (0..<2).map { CatalogSongID.make(album: album, index: $0) },
                "the held songs were given away")

        let fresh = Self.freshAlbum()
        let title = LibraryItem(id: fresh, media: nil, addedAt: nil)
        let menu = CollectionMenuItems.catalog(title, playerCoordinator: PlayerCoordinator(provider: MockProvider())) {
            await ArchiveMusicLoader.albumSongs(albumId: $0) { _ in throw URLError(.notConnectedToInternet) }
        }
        #expect(menu.offersShuffle)
        #expect(await menu.songs().items.map(\.id) == [fresh], "the long-press Shuffle starts nothing")
    }

    @Test("the shuffle of a tile remembers form and album from its answer like the detail fetch")
    func theShuffleKeepsFormAndDetail() async throws {
        let album = Self.freshAlbum()
        let meta = try Self.release(["a", "b", "c"], collection: "netlabels")
        let provider = FreeCatalogProvider.shared
        #expect(provider.archiveForm(itemId: album) == nil)
        let songs = await provider.releaseSongs(albumId: album) { _ in meta }
        #expect(songs.count == 3)
        #expect(provider.archiveForm(itemId: album) == .album, "the release's collections were not kept")
        #expect(provider.libraryItem(forId: album)?.media?.tracks?.count == 3, "the release's detail was not kept")
    }

    @Test("a bundle over the limit plays as a title")
    func aBundlePastTheCapPlaysAsItsTitle() async throws {
        let names = (0...FreeCatalog.defaultTrackCap).map { "t\($0)" }
        let meta = try Self.release(names)
        #expect(await ArchiveMusicLoader.albumSongs(albumId: Self.freshAlbum()) { _ in meta }.isEmpty)
    }

    @Test("the tile takes the path of the shuffle, a failed answer appears once in the log", .needsTheSources)
    func theTileTakesTheDrawsWay() throws {
        let menu = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicView.swift"), encoding: .utf8))
        let loader = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/ArchiveMusicLoader.swift"), encoding: .utf8))
        let provider = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/FreeCatalogProvider.swift"), encoding: .utf8))
        #expect(menu.contains("await CatalogShuffleSongs.songs(of: item, albumSongs: albumSongs)"))
        #expect(loader.contains("await catalog.releaseSongs(albumId: albumId, metadata: metadata)"))
        #expect(!loader.contains("fetchItemDetail"), "the count comes from a second answer again")
        #expect(provider.contains("CATALOG album songs, release answer failed for"))
    }

    @Test("the catalog page takes the list of the provider through the loader and names missing songs with a count", .needsTheSources)
    func thePageTakesTheProvidersList() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        let loader = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/ArchiveMusicLoader.swift"), encoding: .utf8))
        #expect(page.contains("ArchiveMusicLoader.albumSongs(albumId: itemId, count: tracks.count)"))
        #expect(loader.contains("await catalog.albumSongs(albumId: albumId, count: count)"))
        #expect(loader.contains("CATALOG album songs missing=\\(answer.missing.count)"))
        #expect(!page.contains("resolveItem(forId: CatalogSongID.make"), "the page resolves the songs one by one again")
        // The count reaches the line under the buttons.
        #expect(page.contains("missingSongs = answer.missing"))
        #expect(page.contains("Self.missingSongsLine(count: missingSongs)"))
    }

    @Test("a visible line names the number of missing songs, German and English in singular and plural")
    func theLineCountsTheMissingSongs() throws {
        #expect(ArchiveSeriesPage.missingSongsLine(count: 0) == nil)
        #expect(ArchiveSeriesPage.missingSongsLine(count: 1) == String(localized: "\(1) tracks not available"))
        func line(_ count: Int, _ language: String) throws -> String {
            let bundle = try #require(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            return String(format: bundle.localizedString(forKey: "%lld tracks not available", value: nil, table: nil),
                          locale: Locale(identifier: language), count)
        }
        #expect(try line(1, "de") == "1 Titel nicht verfügbar")
        #expect(try line(3, "de") == "3 Titel nicht verfügbar")
        #expect(try line(1, "en") == "1 track not available")
        #expect(try line(3, "en") == "3 tracks not available")
    }
}
#endif
