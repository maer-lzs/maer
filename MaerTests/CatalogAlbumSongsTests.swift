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

    @Test("faellt die Zahl aus, zaehlt der Lader kein Lied und die Kachel spielt den Titel selbst")
    func withoutTheCountTheTilePlaysTheTitle() async {
        var router = ItemRouter.empty
        router.provider = { _ in FailedLoadTests.DeadAddressProvider() }
        let album = Self.freshAlbum()
        #expect(await ArchiveMusicLoader.albumSongs(albumId: album, router: router).isEmpty)
        let title = LibraryItem(id: album, media: nil, addedAt: nil)
        let menu = CollectionMenuItems.catalog(title, playerCoordinator: PlayerCoordinator(provider: MockProvider()),
                                               router: router)
        #expect(menu.offersShuffle)
        #expect(await menu.songs().map(\.id) == [album], "the long-press Shuffle starts nothing")
    }

    @Test("die Kachel nimmt den Weg des Wurfs, ein ausgefallenes Detail steht im Log", .needsTheSources)
    func theTileTakesTheDrawsWay() throws {
        let menu = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicView.swift"), encoding: .utf8))
        let loader = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/ArchiveMusicLoader.swift"), encoding: .utf8))
        #expect(menu.contains("await CatalogShuffleSongs.songs(of: item) {"))
        #expect(!menu.contains("songs: { await ArchiveMusicLoader.albumSongs(albumId: item.id, router: router) }"))
        #expect(loader.contains("CATALOG album songs, detail failed for"))
        #expect(!loader.contains("try? await router.provider(albumId).fetchItemDetail"), "the detail fails silently again")
    }

    @Test("die Katalogseite nimmt die Liste des Anbieters ueber den Lader und nennt fehlende Lieder mit Zahl", .needsTheSources)
    func thePageTakesTheProvidersList() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        let loader = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/ArchiveMusicLoader.swift"), encoding: .utf8))
        #expect(page.contains("ArchiveMusicLoader.albumSongs(albumId: itemId, count: tracks.count)"))
        #expect(loader.contains("FreeCatalogProvider.shared.albumSongs(albumId: albumId, count: count)"))
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
