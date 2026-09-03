// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

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
nonisolated enum ForeignMarks {
    static let importedKey = "foreignMarks.imported"
    static let archivedKey = "foreignMarks.archived"

    static func markImported(_ itemId: String, in defaults: UserDefaults = .standard) {
        insert(itemId, key: importedKey, in: defaults)
    }

    static func markArchived(_ itemId: String, in defaults: UserDefaults = .standard) {
        insert(itemId, key: archivedKey, in: defaults)
    }

    /// A real listen: the position is this device's own from now on.
    static func clearImported(_ itemId: String, in defaults: UserDefaults = .standard) {
        remove(itemId, key: importedKey, in: defaults)
    }

    /// The tombstone: nothing foreign is known about the episode any more.
    static func clear(_ itemId: String, in defaults: UserDefaults = .standard) {
        remove(itemId, key: importedKey, in: defaults)
        remove(itemId, key: archivedKey, in: defaults)
    }

    static func isArchived(_ itemId: String, in defaults: UserDefaults = .standard) -> Bool {
        set(archivedKey, in: defaults).contains(itemId)
    }

    static func importedIDs(in defaults: UserDefaults = .standard) -> Set<String> {
        set(importedKey, in: defaults)
    }

    static func archivedIDs(in defaults: UserDefaults = .standard) -> Set<String> {
        set(archivedKey, in: defaults)
    }

    private static func set(_ key: String, in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private static func insert(_ itemId: String, key: String, in defaults: UserDefaults) {
        var ids = set(key, in: defaults)
        guard ids.insert(itemId).inserted else { return }
        defaults.set(Array(ids).sorted(), forKey: key)
    }

    private static func remove(_ itemId: String, key: String, in defaults: UserDefaults) {
        var ids = set(key, in: defaults)
        guard ids.remove(itemId) != nil else { return }
        defaults.set(Array(ids).sorted(), forKey: key)
    }
}
