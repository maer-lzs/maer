// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How the lists of two music servers become one, as pure rules. Nothing
/// is merged by name here: every item keeps its own entry and its source.
/// With ONE list every rule hands it back unchanged.
nonisolated enum MusicMerge {

    // MARK: Paging, a zipper with an offset per source

    /// One source of a paged list: what it has handed out and not yet
    /// been merged, where its next page starts, and whether it is done.
    struct Stream<Item> {
        var buffer: [Item] = []
        var offset = 0
        var exhausted = false
    }

    /// Up to `size` items in order from the heads of the streams. It stops
    /// early when a stream that is not done has nothing buffered: that
    /// stream's next item may belong before everything else, so emitting
    /// past it would put the list out of order. Equal items keep stream
    /// order. `needs` names the streams to refill before taking again.
    static func take<Item>(_ size: Int, from streams: inout [Stream<Item>],
                           inOrder: (Item, Item) -> Bool) -> (items: [Item], needs: [Int]) {
        var out: [Item] = []
        while out.count < size {
            let waiting = streams.indices.filter { streams[$0].buffer.isEmpty && !streams[$0].exhausted }
            if !waiting.isEmpty { return (out, waiting) }
            var best: Int?
            for index in streams.indices where !streams[index].buffer.isEmpty {
                guard let current = best else { best = index; continue }
                if inOrder(streams[index].buffer[0], streams[current].buffer[0]) { best = index }
            }
            guard let pick = best else { break }
            out.append(streams[pick].buffer.removeFirst())
        }
        return (out, [])
    }

    /// The next page of a list paged on every server separately. `fetch`
    /// asks one source for its page at its own offset; a short page marks
    /// the source done. A failing source counts as done for this list and
    /// is reported, so the other still pages on.
    static func page<Item>(_ size: Int, streams: inout [Stream<Item>],
                           inOrder: (Item, Item) -> Bool,
                           fetch: (_ source: Int, _ offset: Int, _ size: Int) async throws -> [Item])
        async -> (items: [Item], failed: [Int]) {
        var items: [Item] = []
        var failed: [Int] = []
        while items.count < size {
            let step = take(size - items.count, from: &streams, inOrder: inOrder)
            items += step.items
            if step.needs.isEmpty { break }
            for source in step.needs {
                do {
                    let next = try await fetch(source, streams[source].offset, size)
                    streams[source].buffer += next
                    streams[source].offset += next.count
                    if next.count < size { streams[source].exhausted = true }
                } catch {
                    streams[source].exhausted = true
                    failed.append(source)
                }
            }
        }
        return (items, failed)
    }

    /// Name order for albums and songs, the way the app sorts names;
    /// an item without a name goes last.
    static func nameOrder(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case let (a?, b?): return a.localizedStandardCompare(b) == .orderedAscending
        case (_?, nil): return true
        default: return false
        }
    }

    // MARK: Recency and counts, decided per list on the data

    enum Order: Equatable {
        /// Every item carries its moment: one clock for both servers.
        case clock
        /// At least one item has none: first of each, then second of each.
        case rankByRank
    }

    /// Which order one merged list takes, decided on the data it holds,
    /// never on an assumption about a server.
    static func order<Item>(_ lists: [[Item]], stamp: (Item) -> Double?) -> Order {
        lists.allSatisfy { $0.allSatisfy { stamp($0) != nil } } ? .clock : .rankByRank
    }

    /// Newest first when every item has a moment, else rank by rank. Equal
    /// moments keep source order. One list comes back unchanged.
    static func byRecency<Item>(_ lists: [[Item]], stamp: (Item) -> Double?) -> [Item] {
        guard lists.count > 1 else { return lists.first ?? [] }
        switch order(lists, stamp: stamp) {
        case .clock:
            let tagged = lists.enumerated().flatMap { source, list in
                list.enumerated().map { (source: source, rank: $0.offset, item: $0.element) }
            }
            return tagged.sorted { a, b in
                let (sa, sb) = (stamp(a.item) ?? 0, stamp(b.item) ?? 0)
                if sa != sb { return sa > sb }
                return (a.rank, a.source) < (b.rank, b.source)
            }.map(\.item)
        case .rankByRank:
            return rankByRank(lists)
        }
    }

    /// Most played first when every item carries its count, else rank by
    /// rank: the same rule as recency, on a count instead of a moment.
    static func byPlayCount<Item>(_ lists: [[Item]], count: (Item) -> Int?) -> [Item] {
        byRecency(lists, stamp: { count($0).map(Double.init) })
    }

    /// First of each list, then second of each, and so on; the longer
    /// list's rest follows in its own order.
    static func rankByRank<Item>(_ lists: [[Item]]) -> [Item] {
        var out: [Item] = []
        let longest = lists.map(\.count).max() ?? 0
        for rank in 0..<longest {
            for list in lists where rank < list.count { out.append(list[rank]) }
        }
        return out
    }

    // MARK: Shuffle with fill-up

    /// A shuffle pool of `limit` from several sources: an even share each,
    /// and what one source cannot fill, the others fill. Each list is what
    /// its source handed out (asked for up to `limit`), already random.
    static func sharedPool<Item, R: RandomNumberGenerator>(_ lists: [[Item]], limit: Int,
                                                           using generator: inout R) -> [Item] {
        guard lists.count > 1 else { return Array((lists.first ?? []).prefix(limit)) }
        var taken = Array(repeating: 0, count: lists.count)
        var remaining = limit
        // Even shares first, then hand the leftover to whoever still has some.
        var open = lists.indices.filter { !lists[$0].isEmpty }
        while remaining > 0, !open.isEmpty {
            let share = max(1, remaining / open.count)
            for index in open where remaining > 0 {
                let give = min(share, lists[index].count - taken[index], remaining)
                taken[index] += give
                remaining -= give
            }
            open = open.filter { taken[$0] < lists[$0].count }
        }
        var pool = lists.indices.flatMap { lists[$0].prefix(taken[$0]) }
        pool.shuffle(using: &generator)
        return pool
    }
}
