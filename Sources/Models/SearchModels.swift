import Foundation

/// F6: one typed result for the global search — every provider maps its hits
/// into this shape (namespaced ids as everywhere). Foundation-only (MaerCore).
nonisolated struct SearchResult: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case book, author, series, show, episode, album, song, artist
        /// Catalog source "New Shows" — NOT a provider capability; results are
        /// unsubscribed shows whose id is the feed URL.
        case catalogShow
    }

    /// Namespaced item id (`rss:`/`abspod:`/`sub:`/ABS raw), a synthetic
    /// `author:<name>` / `series:<name>`, or the feed URL for shows.
    let id: String
    let kind: Kind
    let title: String
    var subtitle: String? = nil
    var coverURL: URL? = nil
    /// False when the item cannot start right now (offline & not downloaded) —
    /// the row follows the overlay-glyph rule (dimmed + wifi.slash).
    var isPlayableNow: Bool = true
}

/// F6: pure section building + the context-ranking matrix.
nonisolated enum SearchRanking {
    /// The FIXED base order of the typed sections; the catalog section is
    /// always last (clearly a catalog, not the user's own content).
    static let baseOrder: [SearchResult.Kind] = [
        .book, .author, .series, .show, .episode, .album, .artist, .song, .catalogShow
    ]

    /// Kinds that belong to a tab — its sections lead while that tab is active.
    static func kinds(for tab: MediaType) -> [SearchResult.Kind] {
        switch tab {
        case .audiobooks: return [.book, .author, .series]
        case .podcasts: return [.show, .episode]
        case .music: return [.album, .artist, .song]
        default: return []
        }
    }

    /// Context ranking: the active tab's sections first (their base order
    /// kept), then the remaining base order; `.catalogShow` always last.
    static func sectionOrder(activeTab: MediaType) -> [SearchResult.Kind] {
        let leading = kinds(for: activeTab)
        let rest = baseOrder.filter { !leading.contains($0) && $0 != .catalogShow }
        return leading + rest + [.catalogShow]
    }

    /// Group results into ordered, non-empty sections.
    static func sections(results: [SearchResult], activeTab: MediaType)
        -> [(kind: SearchResult.Kind, results: [SearchResult])] {
        let grouped = Dictionary(grouping: results, by: \.kind)
        return sectionOrder(activeTab: activeTab).compactMap { kind in
            guard let hits = grouped[kind], !hits.isEmpty else { return nil }
            return (kind, hits)
        }
    }
}

/// F6: pure local podcast search over the subscription data (shared by the RSS
/// and ABS-podcast providers — one filter, tested once).
nonisolated enum PodcastLocalSearch {
    /// Case/diacritic-insensitive match over show titles + episode titles.
    /// Episode ids are the provider's namespaced episode ids.
    static func results(
        shows: [(feedURL: String, title: String, coverURL: URL?,
                 episodes: [(id: String, title: String)])],
        query: String
    ) -> [SearchResult] {
        var out: [SearchResult] = []
        for show in shows {
            if matches(show.title, query) {
                out.append(SearchResult(id: show.feedURL, kind: .show,
                                        title: show.title, coverURL: show.coverURL))
            }
            for episode in show.episodes where matches(episode.title, query) {
                out.append(SearchResult(id: episode.id, kind: .episode,
                                        title: episode.title, subtitle: show.title,
                                        coverURL: show.coverURL))
            }
        }
        return out
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// F6: per-provider timeout — one slow server must not block the others.
/// Returns nil when `operation` does not finish within `timeout`.
nonisolated func withSearchTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Y15: the filter-chip row above the results (Apple-Podcasts pattern). Chips
/// are on/off toggles, there is NO "All": "Library" scopes to OWN content
/// (all types, no catalog); a type chip narrows to its sections, where the
/// podcasts chip includes the catalog — unless "Library" is also active.
/// The set never goes empty: dropping the last chip falls back to the start
/// state (library only).
nonisolated enum SearchChip: String, CaseIterable, Identifiable {
    case library, audiobooks, podcasts, music
    var id: String { rawValue }
}

nonisolated enum SearchChipFilter {
    static let start: Set<SearchChip> = [.library]

    static func toggled(_ chips: Set<SearchChip>, tapping chip: SearchChip) -> Set<SearchChip> {
        var out = chips
        if out.contains(chip) { out.remove(chip) } else { out.insert(chip) }
        if out.isEmpty { out = start }
        return out
    }

    static func kinds(for chip: SearchChip) -> Set<SearchResult.Kind> {
        switch chip {
        case .library: return Set(SearchResult.Kind.allCases).subtracting([.catalogShow])
        case .audiobooks: return [.book, .author, .series]
        case .podcasts: return [.show, .episode]
        case .music: return [.album, .artist, .song]
        }
    }

    /// Visible OWN kinds + whether the catalog section belongs into the list.
    static func visible(chips: Set<SearchChip>)
        -> (kinds: Set<SearchResult.Kind>, includesCatalog: Bool) {
        let typeChips = chips.subtracting([.library])
        let visibleKinds: Set<SearchResult.Kind> = typeChips.isEmpty
            ? Self.kinds(for: .library)
            : typeChips.reduce(into: []) { $0.formUnion(Self.kinds(for: $1)) }
        let includesCatalog = chips.contains(.podcasts) && !chips.contains(.library)
        return (visibleKinds, includesCatalog)
    }
}
