// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The catalog's chain asks whether a reading is heard, a LibriVox book keeps
/// the names of its sections, and the download and the book's page read a
/// detail's tracks and chapters the way the player does.
struct CatalogChainCleanupTests {
    @Test("a reading whose mark stands at its end or says played is heard; one in the middle or without a mark is not")
    func aHeardReading() {
        let atTheEnd = ProgressMark.entry(position: 1200, duration: 1200, nowMs: 1)
        let inTheMiddle = ProgressMark.entry(position: 600, duration: 1200, nowMs: 1)
        #expect(ChapterEntryRules.heardToTheEnd(stored: atTheEnd), "a reading heard to its end counts as unheard")
        #expect(!ChapterEntryRules.heardToTheEnd(stored: inTheMiddle))
        #expect(!ChapterEntryRules.heardToTheEnd(stored: nil))
    }

    @Test("a LibriVox book's sections keep their names as the names of its parts")
    func theSectionsKeepTheirNames() throws {
        let book = try JSONDecoder().decode(LibriVoxBook.self, from: Data(ChapterChainCatalogTests.book.utf8))
        let tracks = FreeCatalog.tracks(from: book.sections)
        #expect(tracks.map { $0.metadata?.title } == ["Peter Breaks Through", "The Shadow"],
                "the sections lost their names")
        let chapters = ChapterModel.trackChapters(tracks, duration: 1200)
        #expect(chapters.map(\.title) == ["Peter Breaks Through", "The Shadow"])
    }

    @Test("the catalog's menu asks whether the reading is heard, the download orders its tracks and the book's page resolves its chapters as the player does", .needsTheSources)
    func oneWayEach() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let menu = try #require(ABSPodcastRefreshTests.body(of: "struct CatalogQueueButtons",
                                                            in: try code("Sources/Views/TabContentLayout.swift")))
        #expect(menu.contains("ChapterEntryRules.heardToTheEnd("), "the catalog's menu offers the chain for a heard reading")
        let download = try code("Sources/Networking/DownloadManager.swift")
        #expect(download.contains("ChapterModel.ordered("), "the download orders the tracks on its own")
        #expect(!download.contains("l.element.index ?? l.offset"), "the download keeps its own copy of the order")
        let page = try code("Sources/Views/BookDetailScreen.swift")
        #expect(page.contains("ChapterModel.resolved(detail:"), "the book's page resolves its chapters on its own way")
    }
}
#endif
