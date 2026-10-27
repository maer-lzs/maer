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
    private static func release(_ names: [String]) throws -> ArchiveDecoder.MetadataResponse {
        let files = names.map { "{\"name\": \"\($0).mp3\", \"length\": \"60\", \"title\": \"Song \($0)\", \"format\": \"VBR MP3\"}" }
        let json = "{\"files\": [\(files.joined(separator: ","))], \"metadata\": {\"title\": \"Witness Release\"}}"
        return try ArchiveDecoder.decodeMetadata(Data(json.utf8))
    }

    private static func freshAlbum() -> String { "lva:album-songs-witness-\(UUID().uuidString)" }

    @Test("alle Lieder aus einer Antwort in Reihenfolge, ein fehlendes wird genannt")
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

    @Test("ohne Antwort spielt, was die Sitzung schon haelt, der Rest wird genannt")
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

    @Test("ohne Zahl zaehlt und baut eine Antwort die Lieder, ein Titel ausserhalb des Archivs fragt nichts")
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

    @Test("ohne Antwort bleiben die gehaltenen Lieder, ohne Lieder spielt die Kachel den Titel")
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
        #expect(await menu.songs().map(\.id) == [fresh], "the long-press Shuffle starts nothing")
    }

    @Test("ein Buendel ueber der Grenze spielt als Titel")
    func aBundlePastTheCapPlaysAsItsTitle() async throws {
        let names = (0...FreeCatalog.defaultTrackCap).map { "t\($0)" }
        let meta = try Self.release(names)
        #expect(await ArchiveMusicLoader.albumSongs(albumId: Self.freshAlbum()) { _ in meta }.isEmpty)
    }

    @Test("die Kachel nimmt den Weg des Wurfs, eine ausgefallene Antwort steht einmal im Log", .needsTheSources)
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

    @Test("die Katalogseite nimmt die Liste des Anbieters ueber den Lader und nennt fehlende Lieder mit Zahl", .needsTheSources)
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

    @Test("eine sichtbare Zeile nennt die Zahl fehlender Lieder, deutsch und englisch in Einzahl und Mehrzahl")
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
