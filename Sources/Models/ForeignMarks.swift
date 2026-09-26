// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Synchronization

/// Two marks an import leaves on an episode, beside its position entry.
///
/// `imported`: the position came from another app, not from listening
/// here. The statistics leave such episodes out of the listening time;
/// the first real listen on this device clears the mark.
/// `archived`: the other app had put the episode away. Kept so an
/// export carries it back out as archived; marking the episode unplayed
/// (the tombstone) clears it.
///
/// Local to this device, not synced: the marks describe how THIS device
/// came to know a position, and a synced position on another device is
/// its own knowledge there.
///
/// Each list is held in memory once read. An import leaves tens of
/// thousands of marks, and the playback tick asks about the playing
/// episode every few seconds: reading, sorting and writing the whole
/// list per episode held the main actor for minutes on an import of
/// that size. A small stamp beside each list changes with every write,
/// so a held copy is used only while it is the one the defaults carry;
/// a list written before the stamp existed is read as it lies, and only
/// the stamp is added.
nonisolated enum ForeignMarks {
    static let importedKey = "foreignMarks.imported"
    static let archivedKey = "foreignMarks.archived"

    static func stampKey(_ key: String) -> String { key + ".stamp" }

    static func markImported(_ itemId: String, in defaults: UserDefaults = .standard) {
        insert([itemId], key: importedKey, in: defaults)
    }

    /// Many at once, as an import applies them: one read and one write.
    static func markImported(_ itemIds: some Sequence<String>, in defaults: UserDefaults = .standard) {
        insert(Set(itemIds), key: importedKey, in: defaults)
    }

    static func markArchived(_ itemId: String, in defaults: UserDefaults = .standard) {
        insert([itemId], key: archivedKey, in: defaults)
    }

    static func markArchived(_ itemIds: some Sequence<String>, in defaults: UserDefaults = .standard) {
        insert(Set(itemIds), key: archivedKey, in: defaults)
    }

    /// A real listen: the position is this device's own from now on.
    /// Called on every playback tick, so an episode without the mark
    /// neither reads the list nor writes.
    static func clearImported(_ itemId: String, in defaults: UserDefaults = .standard) {
        remove(itemId, key: importedKey, in: defaults)
    }

    /// The tombstone: nothing foreign is known about the episode any more.
    static func clear(_ itemId: String, in defaults: UserDefaults = .standard) {
        remove(itemId, key: importedKey, in: defaults)
        remove(itemId, key: archivedKey, in: defaults)
    }

    static func isArchived(_ itemId: String, in defaults: UserDefaults = .standard) -> Bool {
        held.withLock { current(archivedKey, in: defaults, &$0).contains(itemId) }
    }

    static func importedIDs(in defaults: UserDefaults = .standard) -> Set<String> {
        held.withLock { current(importedKey, in: defaults, &$0) }
    }

    static func archivedIDs(in defaults: UserDefaults = .standard) -> Set<String> {
        held.withLock { current(archivedKey, in: defaults, &$0) }
    }

    /// How often a whole list was read from or written to the defaults,
    /// in this process. The measure the witnesses count against.
    static var listReads: Int { counts.withLock { $0.reads } }
    static var listWrites: Int { counts.withLock { $0.writes } }

    // MARK: - The held lists

    private nonisolated struct Held: Sendable {
        var stamp: String
        var ids: Set<String>
    }

    /// One slot per defaults object and list. The stamp decides whether
    /// a slot is still the list the defaults carry: a new object that
    /// reuses an old identity, or a removed domain, carries another stamp
    /// or none.
    private static let held = Mutex<[String: Held]>([:])
    private static let counts = Mutex<(reads: Int, writes: Int)>((0, 0))

    private static func slot(_ key: String, _ defaults: UserDefaults) -> String {
        "\(ObjectIdentifier(defaults).hashValue)|\(key)"
    }

    private static func current(_ key: String, in defaults: UserDefaults,
                                _ slots: inout [String: Held]) -> Set<String> {
        let slot = slot(key, defaults)
        let stamp = defaults.string(forKey: stampKey(key))
        if let stamp, let copy = slots[slot], copy.stamp == stamp { return copy.ids }
        let ids = Set(defaults.stringArray(forKey: key) ?? [])
        counts.withLock { $0.reads += 1 }
        // A list without a stamp (written before it existed, or never)
        // gets one now; the list itself is left as it lies.
        let current = stamp ?? UUID().uuidString
        if stamp == nil { defaults.set(current, forKey: stampKey(key)) }
        slots[slot] = Held(stamp: current, ids: ids)
        return ids
    }

    private static func store(_ ids: Set<String>, key: String, in defaults: UserDefaults,
                              _ slots: inout [String: Held]) {
        let stamp = UUID().uuidString
        // Unsorted: the list is read back as a set, and sorting tens of
        // thousands of ids on every write bought nothing.
        defaults.set(Array(ids), forKey: key)
        defaults.set(stamp, forKey: stampKey(key))
        counts.withLock { $0.writes += 1 }
        slots[slot(key, defaults)] = Held(stamp: stamp, ids: ids)
    }

    private static func insert(_ itemIds: Set<String>, key: String, in defaults: UserDefaults) {
        guard !itemIds.isEmpty else { return }
        held.withLock { slots in
            var ids = current(key, in: defaults, &slots)
            guard !itemIds.isSubset(of: ids) else { return }
            // The held copy lets go first, so the change does not copy
            // the whole set.
            slots[slot(key, defaults)] = nil
            ids.formUnion(itemIds)
            store(ids, key: key, in: defaults, &slots)
        }
    }

    private static func remove(_ itemId: String, key: String, in defaults: UserDefaults) {
        held.withLock { slots in
            var ids = current(key, in: defaults, &slots)
            guard ids.contains(itemId) else { return }
            slots[slot(key, defaults)] = nil
            ids.remove(itemId)
            store(ids, key: key, in: defaults, &slots)
        }
    }
}
