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
/// and writes the count in its log line.
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

    @Test("die Katalogseite nimmt die Liste des Anbieters und nennt fehlende Lieder mit Zahl", .needsTheSources)
    func thePageTakesTheProvidersList() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        #expect(page.contains("FreeCatalogProvider.shared.albumSongs(albumId: itemId, count: tracks.count)"))
        #expect(page.contains("CATALOG album songs missing=\\(answer.missing.count)"))
        #expect(!page.contains("resolveItem(forId: CatalogSongID.make"), "the page resolves the songs one by one again")
    }
}
#endif
