// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What changed between two states of the library cache, as rows: the items
/// that are new, changed, moved or gone, and the progress entries likewise.
/// The sibling of `PodcastRowDiff` for a flat list. Pure, so the rule is
/// witnessed without a database.
nonisolated struct LibraryRowDiff: Equatable, Sendable {
    struct ItemRow: Equatable, Sendable {
        var position: Int
        var item: LibraryItem
    }

    struct ProgressRow: Equatable, Sendable {
        var itemId: String
        var progress: BookProgress
    }

    var itemsUpserted: [ItemRow] = []
    var itemsRemoved: [String] = []
    var progressUpserted: [ProgressRow] = []
    var progressRemoved: [String] = []

    var isEmpty: Bool {
        itemsUpserted.isEmpty && itemsRemoved.isEmpty && progressUpserted.isEmpty && progressRemoved.isEmpty
    }

    /// Every row of `current`, as if nothing were stored yet.
    static func all(_ current: LibraryDiskCache) -> LibraryRowDiff {
        compute(previous: nil, current: current)
    }

    static func compute(previous: LibraryDiskCache?, current: LibraryDiskCache) -> LibraryRowDiff {
        var diff = LibraryRowDiff()
        var before: [String: (position: Int, item: LibraryItem)] = [:]
        for (position, item) in (previous?.items ?? []).enumerated() { before[item.id] = (position, item) }
        var seen = Set<String>()
        for (position, item) in current.items.enumerated() {
            seen.insert(item.id)
            let old = before[item.id]
            if old == nil || old!.position != position || old!.item != item {
                diff.itemsUpserted.append(ItemRow(position: position, item: item))
            }
        }
        diff.itemsRemoved = before.keys.filter { !seen.contains($0) }.sorted()

        let previousProgress = previous?.progress ?? [:]
        for (itemId, progress) in current.progress.sorted(by: { $0.key < $1.key })
        where previousProgress[itemId] != progress {
            diff.progressUpserted.append(ProgressRow(itemId: itemId, progress: progress))
        }
        diff.progressRemoved = previousProgress.keys.filter { current.progress[$0] == nil }.sorted()
        return diff
    }
}
