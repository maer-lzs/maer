// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Auftrag K + L: the MIXED catalog tile rows — the podcast tab's "Freie
/// Hörbücher & Hörspiele" row (radio-play feeds + catalog titles) and Start's
/// "Entdecken" rows share ONE mixer (Regel 2, "keine zwei Mischer").
///
/// Mix form as decided for the archive rows: INTERLEAVED, not two blocks —
/// each source keeps its own order and the sources alternate (fair merge via
/// `HomeSections.interleave`, the one merge implementation). Pure and tested:
/// a silent mixing mistake would starve a whole source from the row.
nonisolated enum CatalogMix {
    /// One tile of a mixed row. Feed entries open the show preview
    /// (subscribe lives there), catalog items open the detail sheet — the
    /// tap convention (NACHSCHLAGEN) is the same, only the destination
    /// differs by kind.
    enum Tile: Identifiable {
        case feed(HoerspielCuration.Entry)
        case item(LibraryItem)

        var id: String {
            switch self {
            case .feed(let entry): "feed:\(entry.feedURL)"
            case .item(let item): "item:\(item.id)"
            }
        }
    }

    /// The mixed row: sources interleave fairly, capped at `limit`.
    /// `feedGroups` and `itemGroups` are each already-ordered lanes (one per
    /// source) so no single catalog can dominate the row.
    /// 1092867: the row used to be fully DETERMINISTIC — ordered lanes into a
    /// fair interleave means the first tile of every lane is always the same,
    /// which is why the owner saw the identical trio for days. The pot is not
    /// the problem (measured: 38 curated feeds + four catalog lanes for 12
    /// seats) — the static pick is.
    static func row(feedGroups: [[HoerspielCuration.Entry]],
                    itemGroups: [[LibraryItem]], limit: Int,
                    seed: UInt64, previous: Set<String>) -> [Tile] {
        var lanes: [[Tile]] = []
        lanes.append(contentsOf: feedGroups.map { $0.map(Tile.feed) })
        lanes.append(contentsOf: itemGroups.map { $0.map(Tile.item) })
        let mixed = lanes.filter { !$0.isEmpty }.enumerated().map { index, lane in
            shuffle(lane, seed: seed &+ UInt64(index) &* 0x9E37_79B9, previous: previous)
        }
        return HomeSections.interleave(mixed, limit: limit)
    }

    /// One lane, mixed by the 1092867 rules: seeded shuffle (stable for the
    /// whole session — a row that re-sorts under the fingers is a layout jump
    /// in slow motion), and the PREVIOUS round's tiles carry a malus — they
    /// sort behind everything fresh, so "shuffle" cannot deal the same trio
    /// again. A plain exclusion-to-the-back, deliberately no science.
    static func shuffle(_ lane: [Tile], seed: UInt64, previous: Set<String>) -> [Tile] {
        var generator = RediscoverSections.SplitMix64(seed: seed)
        var fresh: [Tile] = []
        var seenLastRound: [Tile] = []
        for tile in lane {
            if previous.contains(tile.id) { seenLastRound.append(tile) }
            else { fresh.append(tile) }
        }
        func seededShuffle(_ tiles: [Tile]) -> [Tile] {
            var array = tiles
            guard array.count > 1 else { return array }
            for index in stride(from: array.count - 1, through: 1, by: -1) {
                let swap = Int(generator.next() % UInt64(index + 1))
                array.swapAt(index, swap)
            }
            return array
        }
        return seededShuffle(fresh) + seededShuffle(seenLastRound)
    }

    /// The session's one seed — drawn once per app start, so every surface
    /// that renders this row (Podcasts tab AND Home) shows the SAME mix and
    /// nothing re-sorts within a session. Fresh start = fresh mix.
    static let sessionSeed = UInt64.random(in: UInt64.min...UInt64.max)
}
