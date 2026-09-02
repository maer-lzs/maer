// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which entries of a kept stock carry which subject, built ONCE.
///
/// A shelf used to be answered by scanning the whole stock and
/// normalising every subject of every entry against the shelf's terms.
/// Measured with a stock the size of the archive audiobooks (75.000
/// entries, 18 shelves): 7,3 seconds on the main actor for one page
/// appearance, which is the "the page takes long to switch to" report.
/// The normalisation is the same work whether it happens per shelf or
/// once; here it happens once, and a shelf is then a union of buckets.
///
/// The membership rule is `CatalogStockRules.belongs` verbatim: every
/// normalised part of a subject counts, and the whole lowercased subject
/// counts too. The witness holds the two equal on a fixture.
nonisolated struct CatalogStockIndex: Sendable {
    /// Lowercased subject part → indices into `stock.entries`, ascending.
    private let buckets: [String: [Int]]

    init(stock: CatalogStock) {
        var buckets: [String: [Int]] = [:]
        for (index, entry) in stock.entries.enumerated() {
            var keys = Set<String>()
            for subject in entry.subjects {
                for part in CatalogGenreAxis.normalizedParts(subject) { keys.insert(part) }
                keys.insert(subject.lowercased())
            }
            for key in keys { buckets[key, default: []].append(index) }
        }
        self.buckets = buckets
    }

    /// Entry indices that belong to ANY of the terms, each once, in
    /// stock order. Empty terms answer nothing, as the scan did.
    func matching(terms: [String]) -> [Int] {
        guard !terms.isEmpty else { return [] }
        var seen = Set<Int>()
        var result: [Int] = []
        for term in terms {
            for index in buckets[term.lowercased()] ?? [] where seen.insert(index).inserted {
                result.append(index)
            }
        }
        return result.sorted()
    }
}
