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
    /// which is why the user saw the identical trio for days. The pot is not
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

    /// R52: WHICH surface is asking. The lanes belong to the surface, not to
    /// the mixer — a shared `hoerspieleTiles` that assembled the same thing
    /// for all three was the construction fault: two tabs promised two offers
    /// and delivered one.
    enum Surface: String, CaseIterable, Sendable {
        /// Radio plays to subscribe to: the curated FEEDS, no catalog tile.
        case podcasts
        /// The catalogues, Old Time Radio among them: no feed.
        case books
        /// Start may show both worlds — that is its job there.
        case home
        /// The SECOND instance of the same class: Start's „Entdecken · Musik"
        /// and the music tab's free-music row draw from the same pot. They
        /// keep their own order for the same reason the book rows do.
        case musicHome
        case musicTab

        var usesFeeds: Bool {
            switch self {
            case .podcasts, .home: true
            case .books, .musicHome, .musicTab: false
            }
        }
        var usesCatalogs: Bool {
            switch self {
            case .books, .home: true
            case .podcasts, .musicHome, .musicTab: false
            }
        }
    }

    /// R52, zweite Instanz: dieselbe Menge, je Flaeche eigene Ordnung. Rein
    /// und getestet — die Reihen sind LibraryItems, nicht Tiles, aber die
    /// Frage ist dieselbe: zwei Flaechen duerfen nicht kachelgleich sein,
    /// und innerhalb einer Sitzung darf sich nichts umsortieren.
    static func ordered(_ items: [LibraryItem], for surface: Surface,
                        session: UInt64 = sessionSeed) -> [LibraryItem] {
        guard items.count > 1 else { return items }
        var generator = RediscoverSections.SplitMix64(seed: seed(for: surface, session: session))
        var array = items
        for index in stride(from: array.count - 1, through: 1, by: -1) {
            let swap = Int(generator.next() % UInt64(index + 1))
            array.swapAt(index, swap)
        }
        return array
    }

    /// The session's one seed — drawn once per app start, so nothing re-sorts
    /// within a session. Fresh start = fresh mix.
    ///
    /// R52: every surface derives ITS OWN seed from it. The stability was
    /// always the point; that two surfaces became twins was not. Deriving
    /// keeps the first and removes the second — Start can no longer deal the
    /// same tiles in the same order as a tab row even where the pots overlap.
    static let sessionSeed = UInt64.random(in: UInt64.min...UInt64.max)

    static func seed(for surface: Surface, session: UInt64 = sessionSeed) -> UInt64 {
        // A fixed, source-visible constant per surface — no `hashValue`,
        // which is salted per process and would make this untestable.
        let salt: UInt64
        switch surface {
        case .podcasts: salt = 0x5BF0_3635_C2E9_1B7D
        case .books:    salt = 0xD1B5_4A32_D192_ED03
        case .home:     salt = 0x9E37_79B9_7F4A_7C15
        case .musicHome: salt = 0x2545_F491_4F6C_DD1D
        case .musicTab:  salt = 0x8EBC_6AF0_9C88_C6E3
        }
        return session ^ salt
    }
}
