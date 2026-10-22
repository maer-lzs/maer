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

    /// The overview's rows with each title once, spread evenly. A title
    /// only one row holds stays there. A title several rows hold goes to the
    /// one that shows the fewest so far (a row at `limit` counts as full),
    /// the earlier one in page order on a tie; the titles are handed out in
    /// page order, then stock order, never in the order of a set, so the
    /// same stocks give the same page. Each row keeps its stock order and is
    /// cut to `limit`. The `buffer` row (Popular, which fetches more than it
    /// shows) goes last: it keeps from its stock what no other row shows and
    /// fills from deeper in it. A row that keeps nothing comes back empty
    /// and the page leaves it out; that happens only when its whole stock
    /// stands elsewhere. The full page of a row stays its whole stock.
    static func balanced<Item: Identifiable>(_ rows: [[Item]], buffer: Int?, limit: Int) -> [[Item]] where Item.ID == String {
        let stocks = rows.map(Self.firstOfEach)
        var holders: [String: [Int]] = [:]
        for (index, stock) in stocks.enumerated() where index != buffer {
            for item in stock { holders[item.id, default: []].append(index) }
        }
        var owner: [String: Int] = [:]
        var count = Array(repeating: 0, count: stocks.count)
        for (id, held) in holders where held.count == 1 {
            owner[id] = held[0]
            count[held[0]] += 1
        }
        for (index, stock) in stocks.enumerated() where index != buffer {
            for item in stock where owner[item.id] == nil {
                let held = holders[item.id] ?? [index]
                let chosen = held.min { min(count[$0], limit) < min(count[$1], limit) } ?? index
                owner[item.id] = chosen
                count[chosen] += 1
            }
        }
        var kept = stocks.enumerated().map { index, stock in
            index == buffer ? [] : Array(stock.filter { owner[$0.id] == index }.prefix(limit))
        }
        if let buffer, stocks.indices.contains(buffer) {
            let shown = Set(kept.joined().map(\.id))
            kept[buffer] = Array(stocks[buffer].filter { !shown.contains($0.id) }.prefix(limit))
        }
        return kept
    }

    /// A row's stock with each title once, at its first place.
    private static func firstOfEach<Item: Identifiable>(_ row: [Item]) -> [Item] where Item.ID == String {
        var seen: Set<String> = []
        return row.filter { seen.insert($0.id).inserted }
    }

    /// Rows that show fewer than `limit` although their stock held as many:
    /// what the split cost them.
    static func shorter<Item>(_ rows: [[Item]], to kept: [[Item]], limit: Int) -> Int {
        zip(rows, kept).filter { $0.count >= limit && $1.count < limit }.count
    }

    /// How many rows had titles of their own and keep none once every
    /// title stands only once on the page.
    static func emptied<Item>(_ rows: [[Item]], to kept: [[Item]]) -> Int {
        zip(rows, kept).filter { !$0.isEmpty && $1.isEmpty }.count
    }

    /// How many of the buffer's first `limit` titles went to another row,
    /// so the buffer showed titles from deeper in its stock instead.
    static func refilled<Item: Identifiable>(_ stock: [Item], to kept: [Item], limit: Int) -> Int where Item.ID == String {
        let shown = Set(kept.map(\.id))
        return firstOfEach(stock).prefix(limit).filter { !shown.contains($0.id) }.count
    }
}
