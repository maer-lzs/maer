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
/// Each list is read from the defaults once and then held in memory. An
/// import leaves tens of thousands of marks, the playback tick asks about
/// the playing episode every few seconds, and on a defaults domain that
/// holds a key per position, any read right after a write cost about
/// 23 ms in the simulator. So after the first read a question reads
/// nothing at all. What keeps the held copy honest is a stamp key beside
/// each list, written with every write and watched by key-value
/// observation: a change from outside this type, or a removed domain,
/// marks the copy stale and the next question reads again. The stamp key
/// carries no dots, because key-value observation reads a dot as a path;
/// the list keys keep theirs, so a list written by an earlier build is
/// read as it lies.
nonisolated enum ForeignMarks {
    static let importedKey = "foreignMarks.imported"
    static let archivedKey = "foreignMarks.archived"

    static func stampKey(_ key: String) -> String {
        key == importedKey ? "foreignMarksImportedStamp" : "foreignMarksArchivedStamp"
    }

    static func markImported(_ itemId: String, in defaults: UserDefaults = .standard) {
        insert([itemId], key: importedKey, in: defaults)
    }

    /// Many at once, as an import applies them: one write.
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
    /// neither reads nor writes.
    static func clearImported(_ itemId: String, in defaults: UserDefaults = .standard) {
        remove(itemId, key: importedKey, in: defaults)
    }

    /// The tombstone: nothing foreign is known about the episode any more.
    static func clear(_ itemId: String, in defaults: UserDefaults = .standard) {
        remove(itemId, key: importedKey, in: defaults)
        remove(itemId, key: archivedKey, in: defaults)
    }

    /// Runs `body` with every clear inside it collected and written once
    /// per list at the end: a sync that brings many tombstones, or marking
    /// a whole show, would otherwise write the whole list per episode.
    /// Questions inside `body` still see the marks cleared in it.
    static func clearingTogether<T>(_ body: () throws -> T) rethrows -> T {
        if pending != nil { return try body() }
        let batch = Pending()
        defer { apply(batch) }
        return try $pending.withValue(batch) { try body() }
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

    /// Hears a stamp change. Its own writes are announced first and not
    /// taken for a change from outside.
    private nonisolated final class StampWatch: NSObject, Sendable {
        let stale = Mutex(false)
        let writing = Mutex(false)

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            if !writing.withLock({ $0 }) { stale.withLock { $0 = true } }
        }
    }

    private nonisolated struct Held: Sendable {
        let watch: StampWatch
        var ids: Set<String>
    }

    /// Clears collected by `clearingTogether`, per list.
    private nonisolated final class Pending: Sendable {
        let removals = Mutex<[String: (owner: ObjectIdentifier, key: String, ids: Set<String>)]>([:])
    }

    @TaskLocal private static var pending: Pending?

    private static let held = Mutex<[String: Held]>([:])
    private static let counts = Mutex<(reads: Int, writes: Int)>((0, 0))

    /// Every defaults object a list is held for, kept alive: its identity
    /// is never reused by another object, and its observation never
    /// outlives it. `UserDefaults` is not `Sendable` and cannot live in the
    /// mutex's state.
    // unsafe because it is read and written only inside `held.withLock`,
    // which serializes it.
    nonisolated(unsafe) private static var anchors: [ObjectIdentifier: UserDefaults] = [:]

    private static func slot(_ key: String, _ defaults: UserDefaults) -> String {
        "\(ObjectIdentifier(defaults).hashValue)|\(key)"
    }

    private static func current(_ key: String, in defaults: UserDefaults,
                                _ slots: inout [String: Held]) -> Set<String> {
        let slot = slot(key, defaults)
        if let copy = slots[slot], !copy.watch.stale.withLock({ $0 }) { return copy.ids }
        let ids = Set(defaults.stringArray(forKey: key) ?? [])
        counts.withLock { $0.reads += 1 }
        let watch: StampWatch
        if let existing = slots[slot]?.watch {
            watch = existing
        } else {
            watch = StampWatch()
            anchors[ObjectIdentifier(defaults)] = defaults
            defaults.addObserver(watch, forKeyPath: stampKey(key), options: [], context: nil)
        }
        watch.stale.withLock { $0 = false }
        slots[slot] = Held(watch: watch, ids: ids)
        return ids
    }

    private static func store(_ ids: Set<String>, key: String, in defaults: UserDefaults,
                              watch: StampWatch, _ slots: inout [String: Held]) {
        defaults.set(Array(ids), forKey: key)
        watch.writing.withLock { $0 = true }
        defaults.set(UUID().uuidString, forKey: stampKey(key))
        watch.writing.withLock { $0 = false }
        counts.withLock { $0.writes += 1 }
        slots[slot(key, defaults)] = Held(watch: watch, ids: ids)
    }

    /// Changes one list: the held copy lets go first, so the change does
    /// not copy the whole set.
    private static func change(key: String, in defaults: UserDefaults,
                               _ edit: (inout Set<String>) -> Bool) {
        held.withLock { slots in
            var ids = current(key, in: defaults, &slots)
            let slot = slot(key, defaults)
            guard let watch = slots[slot]?.watch else { return }
            slots[slot] = nil
            let changed = edit(&ids)
            if changed {
                store(ids, key: key, in: defaults, watch: watch, &slots)
            } else {
                slots[slot] = Held(watch: watch, ids: ids)
            }
        }
    }

    private static func insert(_ itemIds: Set<String>, key: String, in defaults: UserDefaults) {
        guard !itemIds.isEmpty else { return }
        change(key: key, in: defaults) { ids in
            guard !itemIds.isSubset(of: ids) else { return false }
            ids.formUnion(itemIds)
            return true
        }
    }

    private static func remove(_ itemId: String, key: String, in defaults: UserDefaults) {
        if let batch = pending {
            // Held now, so the owner is anchored when the batch is applied.
            _ = held.withLock { current(key, in: defaults, &$0) }
            let owner = ObjectIdentifier(defaults)
            let slot = slot(key, defaults)
            batch.removals.withLock { all in
                var entry = all[slot] ?? (owner: owner, key: key, ids: [])
                entry.ids.insert(itemId)
                all[slot] = entry
            }
            return
        }
        guard held.withLock({ current(key, in: defaults, &$0).contains(itemId) }) else { return }
        change(key: key, in: defaults) { ids in ids.remove(itemId) != nil }
    }

    private static func apply(_ batch: Pending) {
        let all = batch.removals.withLock { $0 }
        for entry in all.values {
            guard let defaults = held.withLock({ _ in anchors[entry.owner] }) else { continue }
            change(key: entry.key, in: defaults) { ids in
                let before = ids.count
                ids.subtract(entry.ids)
                return ids.count != before
            }
        }
    }
}
