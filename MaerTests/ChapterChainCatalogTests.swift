// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A catalog reading goes into Up Next chapter by chapter like a book: its
/// detail is there without a row of this run, its stand is the device's
/// own, and both menus offer it through one button.
@MainActor
struct ChapterChainCatalogTests {
    static let book = """
    {"id":"816","title":"Peter Pan","totaltimesecs":1200,"sections":[
      {"title":"Peter Breaks Through","listen_url":"https://example.org/1.mp3","playtime":"10:00"},
      {"title":"The Shadow","listen_url":"https://example.org/2.mp3","playtime":"10:00"}]}
    """

    @Test("a LibriVox book no row of this run showed asks LibriVox once and gives its sections as tracks")
    func aLibriVoxBookWithoutARow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("librivox-cold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FreeCatalogProvider(ablage: Ablage(directory: directory))
        var asked: [String] = []
        let answer = try JSONDecoder().decode(LibriVoxBook.self, from: Data(Self.book.utf8))
        provider.fetchLibriVoxBook = { asked.append($0); return answer }
        let detail = try await provider.fetchItemDetail(itemId: "lv:816")
        #expect(detail.media.tracks?.count == 2, "the book's sections did not become its tracks")
        #expect(asked == ["816"], "LibriVox was asked \(asked)")
        #expect(ChapterModel.resolved(detail: detail).chapters.count == 2)
    }

    @Test("a reading's stand comes from the device's own store when the library does not hold it")
    func theStandOfAReading() {
        let source = BookChapterSource(playing: { nil }, listed: { _ in nil }, listedPosition: { _ in nil },
                                       storedPosition: { $0 == "lv:816" ? 700 : nil },
                                       fetch: { _ in throw URLError(.notConnectedToInternet) }, changed: {})
        #expect(source.position(of: "lv:816") == 700, "the reading's stand was \(source.position(of: "lv:816"))")
        #expect(source.position(of: "lv:1") == 0)
    }

    @Test("the book's card and the catalog's menus offer the chain through one button, and only it says the words", .needsTheSources)
    func oneButton() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try code("Sources/Views/BookGridComponents.swift").contains("ChapterChainButton("),
                "the book's card builds its own chain button")
        #expect(try code("Sources/Views/TabContentLayout.swift").contains("ChapterChainButton("),
                "the catalog's menu offers no chain")
        let saying = ProjectFileIntegrityTests.sourceFiles().filter {
            (try? String(contentsOf: $0, encoding: .utf8))?.contains("\"Chapter by Chapter in Up Next\"") == true
        }.map(\.lastPathComponent)
        #expect(saying == ["ChapterChainButton.swift"], "the words stand in \(saying)")
    }
}
#endif
