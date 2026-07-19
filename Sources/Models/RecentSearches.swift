import Foundation

/// Y30: the last search terms, remembered locally (UserDefaults) — shown on
/// top of the empty-field browse deck; tapping one re-runs the search.
nonisolated enum RecentSearches {
    static let storageKey = "recentSearches"
    static let cap = 8

    static func list(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    /// Most-recent-first, case-insensitive dedupe, capped.
    static func record(_ term: String, defaults: UserDefaults = .standard) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        var terms = list(defaults: defaults)
        terms.removeAll { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
        terms.insert(trimmed, at: 0)
        defaults.set(Array(terms.prefix(cap)), forKey: storageKey)
    }

    static func remove(_ term: String, defaults: UserDefaults = .standard) {
        var terms = list(defaults: defaults)
        terms.removeAll { $0 == term }
        defaults.set(terms, forKey: storageKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}
