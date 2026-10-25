// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every catalogue area page carries "Play something at random" in its
/// menu, with the draw of its catalogue; no row grows a button of its own.
struct CatalogAreaShuffleTests {
    @Test("der Buch-Wurf fragt die eine Basis der Quelle, in den Sprachen, wo die Quelle mehrere hat")
    func theBookDrawAsksTheSourcesBase() throws {
        let librivox = try #require(CatalogShuffle.bookQuery(for: .librivox, languageCodes: ["de"]))
        #expect(librivox.hasPrefix(try #require(ArchiveOrgClient.archiveBaseQuery(for: .librivox)) + " AND ("))
        #expect(librivox.contains("language:"))
        #expect(CatalogShuffle.bookQuery(for: .archiveBooks, languageCodes: [])
                == ArchiveOrgClient.archiveBaseQuery(for: .archiveBooks))
        // Old Time Radio is drawn whole, like its rows.
        #expect(CatalogShuffle.bookQuery(for: .oldTimeRadio, languageCodes: ["de"])
                == ArchiveOrgClient.archiveBaseQuery(for: .oldTimeRadio))
        #expect(CatalogShuffle.bookQuery(for: .gutenberg, languageCodes: ["de"]) == nil)
        #expect(CatalogShuffle.bookQuery(for: .oerr, languageCodes: ["de"]) == nil)
    }

    @Test("jede Bereichsseite traegt den Wurf ihres Katalogs im Menue, keine Reihe einen neuen Knopf", .needsTheSources)
    func everyAreaPageCarriesItsDraw() throws {
        func text(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .replacing(#/\s+/#, with: " ")
        }
        let music = try text("Sources/Views/Music/ArchiveMusicPages.swift")
        #expect(music.contains(".pageActions(\"catalog-actions\") { CatalogShuffleEntry { await CatalogShuffle.play(area: area, coordinator: playerCoordinator) } }"))
        #expect(music.contains(".pageActions(\"catalog-actions\") { CatalogShuffleEntry { await CatalogShuffle.play(area: ArchiveMusicCatalog.shellacAll, coordinator: playerCoordinator) } }"))
        let jamendo = try text("Sources/Views/Music/MusicLibraryPages.swift")
        #expect(jamendo.contains(".pageActions(\"catalog-actions\") { CatalogShuffleEntry { await CatalogShuffle.playJamendo(coordinator: playerCoordinator) } }"))
        let source = try text("Sources/Views/CatalogSourcePage.swift")
        #expect(source.contains(".pageActions(\"catalog-actions\", shown: !source.isFeedBased) { CatalogShuffleEntry { await CatalogShuffle.playBook(source: source, coordinator: playerCoordinator) } }"))
        // The entry is built in one place.
        var labels: [String: Int] = [:]
        var rowButtons = 0
        for (name, raw) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) {
            let stripped = SyncContractFenceTests.stripped(raw)
            let count = stripped.components(separatedBy: "Label(\"Play something at random\"").count - 1
            if count > 0 { labels[name] = count }
            rowButtons += stripped.components(separatedBy: ".catalogShuffle(area:").count - 1
            rowButtons += stripped.components(separatedBy: ".jamendoShuffle(").count - 1
        }
        #expect(labels == ["TabContentLayout.swift": 1], "\(labels)")
        // The row buttons that stood before: the shellac rows, the netlabels
        // and Jamendo rows of the music tab and of the music catalogue area.
        #expect(rowButtons == 7)
    }
}
#endif
