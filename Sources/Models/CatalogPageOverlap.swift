// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How many titles a catalogue source page shows in more than one row.
/// Each row of the page asks its own query and no row leaves out what
/// another shows, so a title with two subjects can stand twice on one
/// screen; this counts it, for the page's log line.
nonisolated enum CatalogPageOverlap {
    struct Count: Equatable {
        /// Rows with at least one title.
        let rows: Int
        /// Distinct titles over all rows.
        let titles: Int
        /// Distinct titles that stand in two rows or more.
        let duplicates: Int
        /// Up to three of them, sorted, as evidence in the line.
        let examples: [String]
    }

    /// `rows` holds the ids each row shows, in page order. A title twice in
    /// the same row counts once for that row.
    static func count(rows: [[String]]) -> Count {
        var seenIn: [String: Int] = [:]
        for row in rows {
            for id in Set(row) { seenIn[id, default: 0] += 1 }
        }
        let twice = seenIn.filter { $0.value > 1 }.keys.sorted()
        return Count(rows: rows.filter { !$0.isEmpty }.count, titles: seenIn.count,
                     duplicates: twice.count, examples: Array(twice.prefix(3)))
    }

    /// Whether a pass may write the line. A feed source draws a list, not
    /// rows, so there is nothing to count; a page with shelves speaks only
    /// once they answered, a pass cut short says nothing.
    static func speaks(feedBased: Bool, hasShelves: Bool, shelvesLoaded: Bool) -> Bool {
        !feedBased && (shelvesLoaded || !hasShelves)
    }

    /// The overview's rows with each title once, in the first row of the
    /// page that shows it. In page order every row keeps, from its own
    /// stock, only titles no earlier row shows, and is cut to `limit`
    /// after that, so a row whose stock holds more than it shows fills
    /// from deeper in it, and one that holds no more gets shorter. A row
    /// that keeps nothing comes back empty, and the page leaves it out.
    /// The full page of a row stays its whole stock.
    static func firstRowOnly<Item: Identifiable>(_ rows: [[Item]], limit: Int) -> [[Item]] where Item.ID == String {
        var shown: Set<String> = []
        return rows.map { row in
            var kept: [Item] = []
            var inRow: Set<String> = []
            for item in row where kept.count < limit && !shown.contains(item.id) && inRow.insert(item.id).inserted {
                kept.append(item)
            }
            shown.formUnion(inRow)
            return kept
        }
    }

    /// How many rows had titles of their own and keep none once every
    /// title stands only in its first row.
    static func emptied<Item>(_ rows: [[Item]], to kept: [[Item]]) -> Int {
        zip(rows, kept).filter { !$0.isEmpty && $1.isEmpty }.count
    }
}
