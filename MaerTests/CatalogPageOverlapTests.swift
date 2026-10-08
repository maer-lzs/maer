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

    @Test("die Quellen-Seite schreibt die Zeile nach jedem Durchgang der Regale", .needsTheSources)
    func thePageSaysItAfterEachPass() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        #expect(code.contains("logOverlap(by: \"open\")") && code.contains("logOverlap(by: \"stock\")"),
                "a pass of the shelves ends without the line")
        #expect(code.contains("CatalogPageOverlap.count(rows: shownRows)"))
    }
}
#endif
