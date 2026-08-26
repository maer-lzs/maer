// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The derived stores in ONE place, with the boundary IN THE CODE instead of
/// in a label.
///
/// Derived means: produced by a query and fetchable again at any time.
/// Nothing here belongs to the user. No position, no playlist, no favourite,
/// no download. The boundary between fetching again and losing data
/// therefore stands as a LIST: whoever adds a key has to write it down here,
/// and the fence holds against user property slipping in.
///
/// The lever does NOT replace the rule fingerprint. It makes the cold state
/// reachable by hand, so a state one otherwise catches once in 24 hours can
/// be checked at all.
nonisolated enum DerivedStores {
    /// What gets cleared: display name and key. The name travels along,
    /// because the lever has to say WHAT it emptied.
    struct Entry: Sendable {
        let label: String
        let key: String
    }

    static let all: [Entry] = [
        Entry(label: "Gutenberg shelves (daily)", key: "catalogGutenbergShelfStock"),
        Entry(label: "Archive runtimes", key: "archiveRuntimeSeconds"),
        Entry(label: "Withdrawn catalog items", key: DeadCatalogItems.storeKey),
    ]

    /// Keys that belong to the USER. They stand here so the fence can hold
    /// them against `all`. A list nobody maintains would be worthless; one
    /// that is checked against is not.
    static let userOwnedPrefixes = ["localPosition.", "playbackClaim", "userChoices",
                                    "maerPlaylists", "radioFavorites", "listeningStats"]

    /// Clears and says what was cleared. Returns the names that actually
    /// held something. Nothing to clear is an answer, not an empty
    /// message.
    @discardableResult
    static func clear(defaults: UserDefaults = .standard) -> [String] {
        var geleert: [String] = []
        for entry in all where defaults.object(forKey: entry.key) != nil {
            defaults.removeObject(forKey: entry.key)
            geleert.append(entry.label)
        }
        return geleert
    }
}
