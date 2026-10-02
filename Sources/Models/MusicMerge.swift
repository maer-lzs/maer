// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How the lists of two music servers become one, as pure rules. Nothing
/// is merged by name here but genres: every item keeps its own entry and its
/// source. With ONE list every rule hands it back unchanged.
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

    // MARK: Genres, the one thing merged by name

    /// A genre is a category, not an entry: two rows "Jazz" would ask the
    /// same question twice and each page behind them would show half. So
    /// the names of all servers meet under one key.
    static func genreKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// How each server spells each genre, from the last genre lists. A
    /// genre page asks every server in its own words, and does not ask a
    /// server whose list lacked the genre.
    struct GenreSpellings: Sendable, Equatable {
        /// Genre key to (source to that source's own name).
        var names: [String: [Int: String]] = [:]
        /// The sources whose genre list arrived; a source that failed is
        /// not known to lack anything.
        var listed: Set<Int> = []

        /// The name to ask `source` for `genre` with; nil when that
        /// source's list did not carry it. A genre no list carried (reached
        /// from elsewhere) is asked as given, everywhere.
        func name(for genre: String, source: Int) -> String? {
            guard listed.contains(source), let known = names[MusicMerge.genreKey(genre)] else { return genre }
            return known[source]
        }
    }

    /// The genre lists of several sources as one (ENTSCHEID 23.09.): a
    /// genre several servers know appears once, under the first spelling
    /// met, trimmed. A count is the sum where every server that has the
    /// genre counts it, else unknown, so a genre is never shown smaller
    /// than it is. Order: first appearance. `lists` carries each answering
    /// source's index; one list comes back unchanged.
    static func genres(_ lists: [(source: Int, genres: [MusicGenre])])
        -> (genres: [MusicGenre], spellings: GenreSpellings) {
        var spellings = GenreSpellings(listed: Set(lists.map(\.source)))
        guard lists.count > 1 else {
            for genre in lists.first?.genres ?? [] {
                spellings.names[genreKey(genre.name), default: [:]][lists[0].source] = genre.name
            }
            return (lists.first?.genres ?? [], spellings)
        }
        var order: [String] = []
        var merged: [String: MusicGenre] = [:]
        for (source, genres) in lists {
            for genre in genres {
                let key = genreKey(genre.name)
                guard !key.isEmpty else { continue }
                if spellings.names[key]?[source] == nil {
                    spellings.names[key, default: [:]][source] = genre.name
                }
                guard let held = merged[key] else {
                    order.append(key)
                    merged[key] = MusicGenre(name: genre.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                             songCount: genre.songCount, albumCount: genre.albumCount)
                    continue
                }
                merged[key] = MusicGenre(name: held.name,
                                         songCount: sum(held.songCount, genre.songCount),
                                         albumCount: sum(held.albumCount, genre.albumCount))
            }
        }
        return (order.compactMap { merged[$0] }, spellings)
    }

    /// Both known: the sum; one unknown: unknown.
    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard let a, let b else { return nil }
        return a + b
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
