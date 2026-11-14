// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The index must answer exactly what the scan answered; otherwise a
/// shelf would silently change its stock the day the index replaces the
/// scan.
struct CatalogStockIndexTests {
    private func entry(_ id: String, _ subjects: [String]) -> CatalogStockEntry {
        CatalogStockEntry(id: id, title: id, creator: nil, subjects: subjects,
                          downloads: 1, licenseurl: nil, year: nil)
    }

    private var stock: CatalogStock {
        CatalogStock(surface: "t", takenAt: 0, entries: [
            entry("a", ["Fiction"]),
            entry("b", ["Detective and mystery stories; Fiction"]),
            entry("c", ["History -- Europe"]),
            entry("d", ["Science fiction, Adventure"]),
            entry("e", []),
        ])
    }

    @Test("the index answers what the scan answers")
    func indexEqualsScan() {
        let index = CatalogStockIndex(stock: stock)
        for terms in [["fiction"], ["europe"], ["adventure", "history"], ["Fiction"],
                      ["detective and mystery stories"], ["nothing"], []] {
            let scanned = stock.entries.enumerated()
                .filter { CatalogStockRules.belongs($0.element, toShelfTerms: terms) }
                .map(\.offset)
            #expect(index.matching(terms: terms) == scanned, "terms \(terms)")
        }
    }

    /// Red test: a term that occurs only as a PART of a shelf
    /// does not match; that was the substring trap that the scan deliberately
    /// does not have.
    @Test("no substring hit")
    func noSubstringHit() {
        let index = CatalogStockIndex(stock: stock)
        #expect(index.matching(terms: ["mystery"]).isEmpty)
        #expect(index.matching(terms: ["science"]).isEmpty)
    }

    @Test("every entry at most once, in stock order")
    func eachEntryOnceInOrder() {
        let index = CatalogStockIndex(stock: stock)
        #expect(index.matching(terms: ["fiction", "science fiction", "adventure"]) == [0, 1, 3])
    }
}
#endif
