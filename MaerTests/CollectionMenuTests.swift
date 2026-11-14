// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The long press on an album or a playlist tile offers the same entries
/// everywhere, from one place (`CollectionMenuItems`).
struct CollectionMenuTests {
    static func flat(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    @Test("only an archive album has songs to shuffle, a song and a Jamendo title do not")
    func onlyAnArchiveAlbumShuffles() {
        #expect(CollectionMenuItems.shuffles(catalog: "lva:some-release"))
        #expect(!CollectionMenuItems.shuffles(catalog: CatalogSongID.make(album: "lva:some-release", index: 2)))
        #expect(!CollectionMenuItems.shuffles(catalog: "jam:7"))
        #expect(!CollectionMenuItems.shuffles(catalog: "lv:123"))
    }

    @Test("the entries stand once and in one order, every album and playlist tile takes them", .needsTheSources)
    func everyTileTakesTheOneMenu() throws {
        let music = try Self.flat("Sources/Views/Music/MusicView.swift")
        guard let start = music.range(of: "structCollectionMenuItems:View{"),
              let end = music.range(of: "extensionCollectionMenuItems{", range: start.upperBound..<music.endIndex)
        else { Issue.record("CollectionMenuItems is gone"); return }
        let menu = String(music[start.upperBound..<end.lowerBound])
        let order = ["Label(\"Play\"", "Label(\"PlayNext\"", "Label(\"PlayLast\"", "ShufflePlayButton(",
                     "AddToPlaylistButton(", "Label(\"Details\""]
        let positions = order.map { menu.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil), "an entry is missing: \(zip(order, positions).filter { $0.1 == nil }.map(\.0))")
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted(), "the entries changed their order")
        // The album cell, the playlist card and the catalogue music tiles.
        #expect(music.contains(".musicItemMenu(item:item,playerCoordinator:playerCoordinator,isAlbum:true)"))
        #expect(music.contains("ifisAlbum{CollectionMenuItems("))
        #expect(music.contains("CollectionMenuItems.catalog(item,playerCoordinator:playerCoordinator)"))
        #expect(try Self.flat("Sources/Views/Music/PlaylistCard.swift").contains(".contextMenu{CollectionMenuItems("))
        #expect(try Self.flat("Sources/Views/BrowseRow.swift")
            .contains("CollectionMenuItems.catalog(item,playerCoordinator:playerCoordinator)"))
    }
}
#endif
