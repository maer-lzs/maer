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
    @Test("ein Titel in zwei Reihen zaehlt einmal als doppelt, einer zweimal in derselben Reihe nicht")
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

    @Test("eine Feed-Seite schweigt, eine Seite mit Regalen spricht erst, wenn sie geantwortet haben")
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

    @Test("die Quellen-Seite schreibt die Zeile nach jedem Durchgang der Regale", .needsTheSources)
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

    /// On the overview each title stands once, in the first row of the page
    /// that shows it; a later row fills from deeper in its own stock, a row
    /// that keeps nothing comes back empty and is counted.
    @Test("auf der Uebersicht steht jeder Titel einmal, in der ersten Reihe der Seitenfolge; eine spaetere Reihe fuellt aus ihrem Bestand nach")
    func eachTitleStandsInItsFirstRowOnly() {
        let stocks = [["a", "b", "c"], ["b", "d", "e", "f"], ["a", "c"], ["g", "g", "h"]]
            .map { $0.map(Title.init) }
        let kept = CatalogPageOverlap.firstRowOnly(stocks, limit: 2)
        let rows = Self.ids(kept)
        #expect(rows == [["a", "b"], ["d", "e"], ["c"], ["g", "h"]], "rows: \(rows)")
        let count = CatalogPageOverlap.count(rows: rows)
        #expect(count.duplicates == 0, "a title stands twice: \(count.examples)")
        let fullyShown = [["a", "b"], ["b", "a"], ["c"]].map { $0.map(Title.init) }
        let emptiedRows = Self.ids(CatalogPageOverlap.firstRowOnly(fullyShown, limit: 12))
        #expect(emptiedRows == [["a", "b"], [], ["c"]], "rows: \(emptiedRows)")
        #expect(CatalogPageOverlap.emptied(fullyShown, to: CatalogPageOverlap.firstRowOnly(fullyShown, limit: 12)) == 1)
        let noStock: [[Title]] = [[], ["x"].map(Title.init)]
        #expect(CatalogPageOverlap.emptied(noStock, to: CatalogPageOverlap.firstRowOnly(noStock, limit: 12)) == 0,
                "a row without a stock of its own is no emptied row")
    }

    /// The page draws the split and its rows read their share of it, so no
    /// row cuts its own stock past the rule.
    @Test("die Quellen-Seite zeichnet die Verteilung, keine Reihe schneidet ihren Bestand selbst", .needsTheSources)
    func thePageDrawsTheSplit() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        let page = try #require(code.range(of: "struct CatalogSourcePage: View"))
        let next = code.range(of: "struct CatalogPopularPage", range: page.upperBound..<code.endIndex)
        let body = code[page.upperBound..<(next?.lowerBound ?? code.endIndex)]
        #expect(body.contains("CatalogPageOverlap.firstRowOnly("), "the overview does not split its rows")
        #expect(!body.contains("RowPreview.cut("), "a row of the overview cuts its own stock again")
    }
}
#endif
