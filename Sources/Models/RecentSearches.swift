// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The last search terms, remembered locally (UserDefaults) — shown on
/// top of the empty-field browse deck; tapping one re-runs the search.
nonisolated enum RecentSearches {
    static let storageKey = "recentSearches"
    static let cap = 8

    static func list(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    /// Most-recent-first, case-insensitive dedupe, capped. MainActor: an
    /// executed search is a user statement — it notes into the choice family.
    /// Cap eviction deliberately does NOT note a removal (only explicit
    /// remove/clear are tombstones; eviction is re-derived on read).
    @MainActor
    static func record(_ term: String, defaults: UserDefaults = .standard) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        var terms = list(defaults: defaults)
        terms.removeAll { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        terms.insert(trimmed, at: 0)
        defaults.set(Array(terms.prefix(cap)), forKey: storageKey)
        UserChoiceCloudSync.shared.noteSearch(trimmed, removed: false)
    }

    @MainActor
    static func remove(_ term: String, defaults: UserDefaults = .standard) {
        var terms = list(defaults: defaults)
        terms.removeAll { $0 == term }
        defaults.set(terms, forKey: storageKey)
        UserChoiceCloudSync.shared.noteSearch(term, removed: true)
    }

    @MainActor
    static func clear(defaults: UserDefaults = .standard) {
        let terms = list(defaults: defaults)
        defaults.removeObject(forKey: storageKey)
        UserChoiceCloudSync.shared.noteSearchesCleared(terms)
    }
}
