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

/// Y20: the STANDING scope bar above the results (single select, gliding
/// pill — the MediaTabBar pattern). Replaces the Y15 multi-toggle chips:
/// "Library" = own content of every type (catalog behind the explicit row),
/// a type scope narrows to its sections, where podcasts includes the catalog.
nonisolated enum SearchScope: String, CaseIterable, Identifiable {
    case library, audiobooks, podcasts, music
    var id: String { rawValue }

    /// The scope a search opened from a given tab starts in.
    static func initial(for tab: MediaType) -> SearchScope {
        switch tab {
        case .audiobooks: return .audiobooks
        case .podcasts: return .podcasts
        case .music: return .music
        default: return .library
        }
    }

    /// The OWN kinds this scope shows.
    var kinds: Set<SearchResult.Kind> {
        switch self {
        case .library: return Set(SearchResult.Kind.allCases).subtracting([.catalogShow])
        case .audiobooks: return [.book, .author, .series]
        case .podcasts: return [.show, .episode]
        case .music: return [.album, .artist, .song]
        }
    }

    /// Whether the catalog section renders inline for this scope.
    var includesCatalog: Bool { self == .podcasts }
}
