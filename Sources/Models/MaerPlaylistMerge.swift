// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Bringing Mär playlists together across a person's own devices. The whole
/// decision logic, pure and testable, without a store or a network in sight.
///
/// **Per ENTRY.** Two additions to the same list on two devices are two
/// additions, not a conflict: the merged list is the union, in the order of
/// the side that changed last, the other side's new entries appended. A
/// removal travels as a tombstone per entry with its moment, so a title
/// someone removed does not rise again from the other device. An entry
/// present on a side that changed AFTER the removal was added again and
/// stays (the same rule the list tombstones follow).
///
/// **The name merges by its own clock** (`nameUpdatedAt`), because the list
/// clock moves on every content change and cannot say whose name is newer.
///
/// **Rescue copies remain the net for the unknown.** The union has no losing
/// side, so nothing is rescued today; the machinery stays so a future case
/// that cannot be united still hands the older version back instead of
/// dropping it, and it never rescues a version whose entries all stand in
/// the winner (nothing was lost).
///
/// **Deletions of a whole list need a mark.** Without one, a list deleted
/// here comes back from iCloud on the next reconcile. A tombstone carries the
/// moment of deletion and wins against any older version of that list. And
/// loses against a newer one, so re-creating a list on another device works.
///
/// **No version compares with `==`.** `Entry`, `Snapshot` and `Outcome` are
/// not `Equatable`: the one question a caller has is whether two versions
/// differ in what they carry, and `differs` answers it without the device
/// name. A plain `==` counted the name and made devices rewrite each other's
/// lists, so the compiler refuses it.
nonisolated enum MaerPlaylistMerge {
    struct Entry: Sendable {
        var name: String
        var updatedAt: Double
        /// When the NAME was last changed, as its own clock. `updatedAt`
        /// bumps on every content change, so it cannot say whose name is
        /// newer. Optional: entries and blobs from before this field carry
        /// none, and a missing side simply loses the name tie.
        var nameUpdatedAt: Double?
        var itemIds: [String]
        /// Title snapshots per entry id. What a row shows when the DEVICE
        /// cannot resolve the id (a catalogue track after a cold start, a
        /// server title without its server). Taken at the moment of adding,
        /// when the item is at hand; they travel with the list, because the
        /// device that needs them is precisely the one that never saw the item.
        var titles: [String: String] = [:]
        /// The second generation of what an entry carries (title, subtitle,
        /// duration, public cover, source). Supplemented across sides like
        /// the titles. Blobs from before carry none.
        var snapshots: [String: CarriedItem] = [:]
        /// Entries removed from this list, with the moment of removal (the
        /// list clock's unit). Travels with the list; blobs from before carry
        /// none and then merge as a plain union.
        var removed: [String: Double] = [:]
        /// The moment each entry was added, so a removal can be told from a
        /// later re-add: an entry outlives a removal mark only when it was
        /// added after the mark. Entries from before this field carry no
        /// moment and count as older than any mark.
        var added: [String: Double] = [:]
        /// The device that wrote this version, by name, for a rescue copy
        /// that has to say where it came from. Optional on the wire.
        var device: String?

        init(name: String, updatedAt: Double, itemIds: [String],
             titles: [String: String] = [:], nameUpdatedAt: Double? = nil,
             snapshots: [String: CarriedItem] = [:], removed: [String: Double] = [:],
             added: [String: Double] = [:], device: String? = nil) {
            self.name = name
            self.updatedAt = updatedAt
            self.itemIds = itemIds
            self.titles = titles
            self.nameUpdatedAt = nameUpdatedAt
            self.snapshots = snapshots
            self.removed = removed
            self.added = added
            self.device = device
        }
    }

    struct Snapshot: Sendable {
        /// list id → version
        var lists: [String: Entry] = [:]
        /// list id → moment of deletion
        var tombstones: [String: Double] = [:]

        init(lists: [String: Entry] = [:], tombstones: [String: Double] = [:]) {
            self.lists = lists
            self.tombstones = tombstones
        }
    }

    struct Outcome: Sendable {
        /// The state BOTH sides converge to.
        var lists: [String: Entry] = [:]
        /// Deletion marks both sides carry from now on.
        var tombstones: [String: Double] = [:]
        /// Versions that lost and could not be united. Empty by construction
        /// today; kept as the net for the unknown.
        var rescued: [Entry] = []

        /// The state both sides converge to, as a snapshot.
        var snapshot: Snapshot { Snapshot(lists: lists, tombstones: tombstones) }
    }

    /// How long a removal mark travels. A removal older than this has
    /// reached every device that will ever merge it (the pot holds no blob
    /// that old), so the mark falls and the blob stops growing with every
    /// title ever removed. Ninety days, in seconds.
    static let removalMarkMaxAge: Double = 90 * 86_400

    static func merge(local: Snapshot, cloud: Snapshot,
                      now: Double = Date().timeIntervalSince1970) -> Outcome {
        var outcome = Outcome()
        let oldest = now - removalMarkMaxAge
        // A deletion is the newest word about that list on either side.
        for id in Set(local.tombstones.keys).union(cloud.tombstones.keys) {
            outcome.tombstones[id] = max(local.tombstones[id] ?? 0, cloud.tombstones[id] ?? 0)
        }

        for id in Set(local.lists.keys).union(cloud.lists.keys) {
            let mine = local.lists[id]
            let theirs = cloud.lists[id]
            switch (mine, theirs) {
            case let (m?, t?):
                var united = unite(m, t)
                // A list stays deleted unless it was touched AFTER the deletion.
                if let deletedAt = outcome.tombstones[id], deletedAt >= united.updatedAt { continue }
                united.removed = united.removed.filter { $0.value >= oldest }
                outcome.lists[id] = united
            case let (one?, nil), let (nil, one?):
                if let deletedAt = outcome.tombstones[id], deletedAt >= one.updatedAt { continue }
                var aged = one
                aged.removed = aged.removed.filter { $0.value >= oldest }
                outcome.lists[id] = aged
            case (nil, nil):
                continue
            }
        }
        return outcome
    }

    /// Two versions of ONE list become one: the union of both sides in the
    /// newer side's order, the older side's own entries appended; an entry
    /// with a removal mark is out unless it was added again AFTER the mark;
    /// the name by its own clock; titles and snapshots supplemented.
    static func unite(_ a: Entry, _ b: Entry) -> Entry {
        let (newer, older) = b.updatedAt > a.updatedAt ? (b, a) : (a, b)
        let added = newer.added.merging(older.added, uniquingKeysWith: max)
        // A removal mark from either side, newest moment wins. A mark is
        // spent once the entry was added again after it (the add moment is
        // the witness; an entry without one is older than any mark), and a
        // spent mark must not travel on.
        var marks: [String: Double] = [:]
        for (item, at) in newer.removed.merging(older.removed, uniquingKeysWith: max)
        where (added[item] ?? 0) <= at {
            marks[item] = at
        }
        var ids: [String] = []
        for item in newer.itemIds + older.itemIds
        where !ids.contains(item) && marks[item] == nil {
            ids.append(item)
        }
        var united = newer
        united.itemIds = ids
        united.updatedAt = max(newer.updatedAt, older.updatedAt)
        united.removed = marks
        united.added = added.filter { ids.contains($0.key) }
        // Knowledge only one side has must not die: a title the other side
        // knew supplements this one, for ids the list still carries.
        united.titles = newer.titles.merging(older.titles) { mine, _ in mine }
            .filter { ids.contains($0.key) }
        united.snapshots = newer.snapshots.merging(older.snapshots) { mine, _ in mine }
            .filter { ids.contains($0.key) }
        // The NAME merges by its own clock. A side without the clock counts
        // as zero and loses the tie, which keeps every pre-clock blob
        // behaving as before.
        if (older.nameUpdatedAt ?? 0) > (newer.nameUpdatedAt ?? 0) {
            united.name = older.name
            united.nameUpdatedAt = older.nameUpdatedAt
        }
        return united
    }

    /// Whether a rescue copy is worth keeping. Never for a version whose
    /// entries all stand in one of the existing lists (nothing was lost,
    /// order aside), never for an empty one, and never twice for the same
    /// content. Compared by CONTENT, not by name: the name carries a date
    /// and would differ on every run.
    static func needsRescue(_ candidate: Entry, existing: [[String]]) -> Bool {
        guard !candidate.itemIds.isEmpty else { return false }
        let mine = Set(candidate.itemIds)
        return !existing.contains { mine.isSubset(of: Set($0)) }
    }

    /// Whether two versions of one list differ in anything but the device
    /// name. The name only labels a rescue copy; each device stamps its own
    /// on every reconcile, so comparing it would make every device rewrite a
    /// list the other one just stored with the same content. The ONE answer
    /// to "is this a difference?" for the runner and for every carrier that
    /// writes per list.
    static func differs(_ a: Entry, _ b: Entry) -> Bool {
        a.name != b.name
            || a.updatedAt != b.updatedAt
            || a.nameUpdatedAt != b.nameUpdatedAt
            || a.itemIds != b.itemIds
            || a.titles != b.titles
            || a.snapshots != b.snapshots
            || a.removed != b.removed
            || a.added != b.added
    }

    /// The fields `differs` compares, every stored field of `Entry` but
    /// `device`. A witness holds this list against the stored fields, so a
    /// new field cannot be left out of the comparison unnoticed.
    static let comparedFields: Set<String> =
        ["name", "updatedAt", "nameUpdatedAt", "itemIds", "titles", "snapshots", "removed", "added"]

    /// Whether `a` and `b` are the same version, device name included. Only
    /// for finding where a version came from (the id of a rescued loser),
    /// never for deciding whether something changed.
    static func isSameVersion(_ a: Entry, _ b: Entry) -> Bool {
        !differs(a, b) && a.device == b.device
    }

    /// The list id a rescued loser stood under, looked up on the local side
    /// first, then on the cloud side; nil when neither holds that version.
    static func sourceId(of loser: Entry, local: Snapshot, cloud: Snapshot) -> String? {
        local.lists.first { isSameVersion($0.value, loser) }?.key
            ?? cloud.lists.first { isSameVersion($0.value, loser) }?.key
    }

    /// The same answer over two sets of lists.
    static func differs(_ a: [String: Entry], _ b: [String: Entry]) -> Bool {
        guard Set(a.keys) == Set(b.keys) else { return true }
        return a.contains { id, entry in b[id].map { differs(entry, $0) } ?? true }
    }

    /// The same answer over two snapshots: the ONE answer to "is this
    /// snapshot a difference?" for the store and for the carrier.
    static func differs(_ a: Snapshot, _ b: Snapshot) -> Bool {
        differs(a.lists, b.lists) || a.tombstones != b.tombstones
    }

    /// The fields `differs` compares for a snapshot, every stored field of
    /// `Snapshot`. A witness holds this list against the stored fields.
    static let comparedSnapshotFields: Set<String> = ["lists", "tombstones"]
}
