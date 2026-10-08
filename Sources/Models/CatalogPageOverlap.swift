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
}
