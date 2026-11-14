// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A catalogue source page counts the titles it shows in more than one row
/// and says so in one line per pass: that is how the question "does the
/// page show a title twice" is measured on the page itself.
struct CatalogPageOverlapTests {
    @Test("a title in two rows counts once as a duplicate, one twice in the same row does not")
    func aTitleInTwoRowsCounts() {
        let count = CatalogPageOverlap.count(rows: [["a", "b", "c"], ["c", "d"], [], ["b", "c", "e", "e"]])
        #expect(count.rows == 3, "an empty row counted")
        #expect(count.titles == 5)
        #expect(count.duplicates == 2, "the titles in two rows or more are b and c")
        #expect(count.examples == ["b", "c"])
        #expect(CatalogPageOverlap.count(rows: [["x", "x"], ["y"]]).duplicates == 0,
                "a title twice in one row counted as standing in two rows")
        #expect(CatalogPageOverlap.count(rows: [["a", "b", "c", "d"], ["a", "b", "c", "d"]]).examples == ["a", "b", "c"],
                "the line carries at most three examples")
    }

    @Test("a feed page stays silent, a page with shelves speaks only once they have answered")
    func onlyRowsThePageShowsSpeak() {
        #expect(!CatalogPageOverlap.speaks(feedBased: true, hasShelves: false, shelvesLoaded: false),
                "a feed page draws a list, its items are no row")
        #expect(!CatalogPageOverlap.speaks(feedBased: true, hasShelves: false, shelvesLoaded: true))
        #expect(!CatalogPageOverlap.speaks(feedBased: false, hasShelves: true, shelvesLoaded: false),
                "a pass cut short before the shelves answered")
        #expect(CatalogPageOverlap.speaks(feedBased: false, hasShelves: true, shelvesLoaded: true))
        #expect(CatalogPageOverlap.speaks(feedBased: false, hasShelves: false, shelvesLoaded: false),
                "a catalogue page without shelves speaks after its rows")
    }

    @Test("the source page writes the line after every pass of the shelves", .needsTheSources)
    func thePageSaysItAfterEachPass() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        #expect(code.contains("logOverlap(by: \"open\")") && code.contains("logOverlap(by: \"stock\")"),
                "a pass of the shelves ends without the line")
        #expect(code.contains("CatalogPageOverlap.count(rows: split.rows.map"),
                "the line counts what the page draws, the split")
        #expect(code.contains("CatalogPageOverlap.speaks(feedBased: source.isFeedBased"),
                "the line asks the rule whether this page has rows to count")
    }

    private struct Title: Identifiable { let id: String }

    private static func ids(_ rows: [[Title]]) -> [[String]] { rows.map { $0.map(\.id) } }

    private static func titles(_ ids: [String]) -> [Title] { ids.map(Title.init) }

    @Test("shared titles go to the shorter row: two shelves with the same six titles end up equally long")
    func sharedTitlesSpreadEvenly() {
        let six = (1...6).map { "x\($0)" }
        let kept = Self.ids(CatalogPageOverlap.balanced([Self.titles(six), Self.titles(six)], buffer: nil, limit: 12))
        #expect(kept == [["x1", "x3", "x5"], ["x2", "x4", "x6"]], "three and three, not six and none: \(kept)")
        let withOwn = [Self.titles(["a", "b", "s"]), Self.titles(["s", "t"]), Self.titles(["t", "u", "v", "w"])]
        #expect(Self.ids(CatalogPageOverlap.balanced(withOwn, buffer: nil, limit: 12)) == [["a", "b"], ["s", "t"], ["u", "v", "w"]],
                "own titles stay; the middle row holds none of its own, so it is the shortest and gets both shared ones")
    }

    @Test("Popular is the buffer: if it shares titles with a shelf, the title stays in the shelf, and Popular refills from its stock")
    func popularRefillsFromItsStock() {
        let popular = Self.titles((1...30).map { "p\($0)" })
        let shelf = Self.titles((1...5).map { "p\($0)" } + (1...7).map { "s\($0)" })
        let kept = CatalogPageOverlap.balanced([popular, shelf], buffer: 0, limit: 12)
        #expect(Self.ids(kept)[1] == shelf.map(\.id), "the shelf keeps all twelve")
        #expect(Self.ids(kept)[0] == (6...17).map { "p\($0)" }, "popular shows twelve from deeper in its thirty")
        #expect(CatalogPageOverlap.refilled(popular, to: kept[0], limit: 12) == 5)
        #expect(CatalogPageOverlap.shorter([popular, shelf], to: kept, limit: 12) == 0)
    }

    @Test("every title once, no row above 12, equal stocks give the same page, a row drops out only elsewhere entirely")
    func theInvariantsHold() {
        let pool = (0..<40).map { "t\($0)" }
        let stocks = (0..<7).map { row in Self.titles((0..<20).map { pool[($0 * (row + 1) + row * 3) % pool.count] }) }
        let kept = CatalogPageOverlap.balanced(stocks, buffer: 0, limit: 12)
        let rows = Self.ids(kept)
        let count = CatalogPageOverlap.count(rows: rows)
        #expect(count.duplicates == 0, "a title stands twice: \(count.examples)")
        let longest = rows.map(\.count).max() ?? 0
        #expect(longest <= 12, "a row longer than twelve: \(rows.map(\.count))")
        for _ in 0..<20 {
            #expect(Self.ids(CatalogPageOverlap.balanced(stocks, buffer: 0, limit: 12)) == rows, "the same stocks drew another page")
        }
        let shownAll = Set(rows.joined())
        for (index, row) in rows.enumerated() where row.isEmpty {
            let lost = stocks[index].map(\.id).filter { !shownAll.contains($0) }
            #expect(lost.isEmpty, "row \(index) went empty though \(lost) stand nowhere")
        }
        let none = [Self.titles(["a", "b"]), Self.titles(["a", "b"]), Self.titles(["c"])]
        #expect(CatalogPageOverlap.emptied(none, to: CatalogPageOverlap.balanced(none, buffer: nil, limit: 12)) == 0,
                "two rows with the same titles share them")
        let whole = [Self.titles(["a", "b"]), Self.titles(["a", "b"])]
        #expect(CatalogPageOverlap.emptied(whole, to: CatalogPageOverlap.balanced(whole, buffer: 0, limit: 12)) == 1,
                "the buffer whose whole stock stands in the shelf goes")
        let noStock: [[Title]] = [[], Self.titles(["x"])]
        #expect(CatalogPageOverlap.emptied(noStock, to: CatalogPageOverlap.balanced(noStock, buffer: 0, limit: 12)) == 0,
                "a row without a stock of its own is no emptied row")
    }

    /// The page draws the split and its rows read their share of it, so no
    /// row cuts its own stock past the rule.
    @Test("the source page draws the distribution, no row cuts its stock itself", .needsTheSources)
    func thePageDrawsTheSplit() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        let page = try #require(code.range(of: "struct CatalogSourcePage: View"))
        let next = code.range(of: "struct CatalogPopularPage", range: page.upperBound..<code.endIndex)
        let body = code[page.upperBound..<(next?.lowerBound ?? code.endIndex)]
        #expect(body.contains("CatalogPageOverlap.balanced(stocks, buffer: 0,"), "the overview does not split its rows, Popular first as the buffer")
        #expect(!body.contains("RowPreview.cut("), "a row of the overview cuts its own stock again")
        #expect(body.components(separatedBy: "LazyHStack").count - 1 == 1, "a row of the overview draws its own strip")
        #expect(body.components(separatedBy: "previewStrip(").count - 1 == 5,
                "the one strip and its four rows (popular, new at LibriVox, shelf, decade)")
    }
}
#endif
