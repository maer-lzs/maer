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

    @Test("der Index antwortet, was der Scan antwortet")
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

    /// Rot-Probe: ein Begriff, der nur als TEIL eines Fachs vorkommt,
    /// trifft nicht; das war die Teilstring-Falle, die der Scan bewusst
    /// nicht hat.
    @Test("kein Teilstring-Treffer")
    func noSubstringHit() {
        let index = CatalogStockIndex(stock: stock)
        #expect(index.matching(terms: ["mystery"]).isEmpty)
        #expect(index.matching(terms: ["science"]).isEmpty)
    }

    @Test("jeder Eintrag hoechstens einmal, in Bestandsordnung")
    func eachEntryOnceInOrder() {
        let index = CatalogStockIndex(stock: stock)
        #expect(index.matching(terms: ["fiction", "science fiction", "adventure"]) == [0, 1, 3])
    }
}
#endif
