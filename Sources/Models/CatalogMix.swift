// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
    static func row(feedGroups: [[HoerspielCuration.Entry]],
                    itemGroups: [[LibraryItem]], limit: Int) -> [Tile] {
        var lanes: [[Tile]] = []
        lanes.append(contentsOf: feedGroups.map { $0.map(Tile.feed) })
        lanes.append(contentsOf: itemGroups.map { $0.map(Tile.item) })
        return HomeSections.interleave(lanes.filter { !$0.isEmpty }, limit: limit)
    }
}
