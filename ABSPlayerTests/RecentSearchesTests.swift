// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Recent searches. Most-recent-first, case-insensitive dedupe, capped,
/// removable one by one and clearable as a whole.
struct RecentSearchesTests {
    private func makeDefaults() -> UserDefaults {
        let name = "recent-searches-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("record puts the newest term first and dedupes case-insensitively")
    func recordOrderAndDedupe() {
        let defaults = makeDefaults()
        RecentSearches.record("Adorno", defaults: defaults)
        RecentSearches.record("1Q84", defaults: defaults)
        #expect(RecentSearches.list(defaults: defaults) == ["1Q84", "Adorno"])
        // Re-running an old term (different case) moves it to the front once.
        RecentSearches.record("adorno", defaults: defaults)
        #expect(RecentSearches.list(defaults: defaults) == ["adorno", "1Q84"])
    }

    @Test("record trims and ignores terms below the server minimum")
    func recordGuards() {
        let defaults = makeDefaults()
        RecentSearches.record("  x ", defaults: defaults)
        RecentSearches.record("   ", defaults: defaults)
        #expect(RecentSearches.list(defaults: defaults).isEmpty)
        RecentSearches.record("  ab ", defaults: defaults)
        #expect(RecentSearches.list(defaults: defaults) == ["ab"])
    }

    @Test("the list stays capped at the newest entries")
    func capHolds() {
        let defaults = makeDefaults()
        for i in 0..<(RecentSearches.cap + 3) {
            RecentSearches.record("term-\(i)", defaults: defaults)
        }
        let list = RecentSearches.list(defaults: defaults)
        #expect(list.count == RecentSearches.cap)
        #expect(list.first == "term-\(RecentSearches.cap + 2)")
        #expect(!list.contains("term-0"))
    }

    @Test("remove deletes one term, clear empties the list")
    func removeAndClear() {
        let defaults = makeDefaults()
        RecentSearches.record("keep", defaults: defaults)
        RecentSearches.record("drop", defaults: defaults)
        RecentSearches.remove("drop", defaults: defaults)
        #expect(RecentSearches.list(defaults: defaults) == ["keep"])
        RecentSearches.clear(defaults: defaults)
        #expect(RecentSearches.list(defaults: defaults).isEmpty)
    }
}
#endif
