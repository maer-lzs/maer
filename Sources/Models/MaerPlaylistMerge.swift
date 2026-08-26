// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Bringing Mär playlists together across a person's own devices. The whole
/// decision logic, pure and testable, without a store or a network in sight.
///
/// **Per LIST, never per entry.** An entry-level union sounds better and is
/// wrong: it cannot tell a DELETION from a missing entry, so every title
/// someone removed would rise again on the next device. The same class of
/// mistake the subscriptions defuse with their two-round confirmation.
///
/// **The losing version is not thrown away.** If both sides changed a list and
/// their contents differ, the older one is handed back as a rescue copy. The
/// user sees that something happened instead of quietly losing an evening's
/// work. A rescue copy stays on the device that made it (`isRescue`): pushing
/// it would multiply it across devices.
///
/// **Deletions need a mark.** Without one, a list deleted here comes back from
/// iCloud on the next reconcile. A tombstone carries the moment of deletion and
/// wins against any older version of that list. And loses against a newer one,
/// so re-creating a list on another device still works.
nonisolated enum MaerPlaylistMerge {
    struct Entry: Equatable, Sendable {
        var name: String
        var updatedAt: Double
        var itemIds: [String]
        /// Title snapshots per entry id. What a row shows when the DEVICE
        /// cannot resolve the id (a catalogue track after a cold start, a
        /// server title without its server). Taken at the moment of adding,
        /// when the item is at hand; they travel with the list, because the
        /// device that needs them is precisely the one that never saw the item.
        var titles: [String: String] = [:]

        init(name: String, updatedAt: Double, itemIds: [String], titles: [String: String] = [:]) {
            self.name = name
            self.updatedAt = updatedAt
            self.itemIds = itemIds
            self.titles = titles
        }
    }

    struct Snapshot: Equatable, Sendable {
        /// list id → version
        var lists: [String: Entry] = [:]
        /// list id → moment of deletion
        var tombstones: [String: Double] = [:]

        init(lists: [String: Entry] = [:], tombstones: [String: Double] = [:]) {
            self.lists = lists
            self.tombstones = tombstones
        }
    }

    struct Outcome: Equatable, Sendable {
        /// The state BOTH sides converge to.
        var lists: [String: Entry] = [:]
        /// Deletion marks both sides carry from now on.
        var tombstones: [String: Double] = [:]
        /// Versions that lost but differed. To be kept as local copies.
        var rescued: [Entry] = []
    }

    static func merge(local: Snapshot, cloud: Snapshot) -> Outcome {
        var outcome = Outcome()
        // A deletion is the newest word about that list on either side.
        for id in Set(local.tombstones.keys).union(cloud.tombstones.keys) {
            outcome.tombstones[id] = max(local.tombstones[id] ?? 0, cloud.tombstones[id] ?? 0)
        }

        for id in Set(local.lists.keys).union(cloud.lists.keys) {
            let mine = local.lists[id]
            let theirs = cloud.lists[id]
            let winner: Entry?
            let loser: Entry?
            switch (mine, theirs) {
            case let (m?, t?):
                if t.updatedAt > m.updatedAt { winner = t; loser = m } else { winner = m; loser = t }
            case let (m?, nil): winner = m; loser = nil
            case let (nil, t?): winner = t; loser = nil
            case (nil, nil): winner = nil; loser = nil
            }
            guard let winner else { continue }
            // A list stays deleted unless it was touched AFTER the deletion.
            if let deletedAt = outcome.tombstones[id], deletedAt >= winner.updatedAt { continue }
            var adopted = winner
            // Knowledge only one side has must not die because the other side
            // wins: a title the loser knew supplements the winner's list.
            // For ids the winner still carries. The winner's own titles stay.
            if let loser {
                adopted.titles = winner.titles.merging(loser.titles) { mine, _ in mine }
                    .filter { winner.itemIds.contains($0.key) }
            }
            outcome.lists[id] = adopted
            if let loser, loser.itemIds != winner.itemIds {
                outcome.rescued.append(loser)
            }
        }
        return outcome
    }

    /// Whether a rescue copy is worth keeping. The same content must not pile
    /// up once per reconcile. Compared by CONTENT, not by name: the name
    /// carries a date and would differ on every run.
    static func needsRescue(_ candidate: Entry, existing: [[String]]) -> Bool {
        !candidate.itemIds.isEmpty && !existing.contains(candidate.itemIds)
    }
}
