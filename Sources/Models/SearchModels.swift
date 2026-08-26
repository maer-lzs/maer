// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One typed result for the global search. Every provider maps its hits
/// into this shape (namespaced ids as everywhere). Foundation-only (MaerCore).
nonisolated struct SearchResult: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case book, author, series, show, episode, album, song, artist
        /// A music playlist hit (search3 ships none. The providers
        /// filter the playlist list LOCALLY; honestly reported).
        case playlist
        /// Catalog source "New Shows". NOT a provider capability; results are
        /// unsubscribed shows whose id is the feed URL.
        case catalogShow
        /// A free-catalog BOOK hit (audiobook scope; id = catalog item
        /// id lva:/gut:). Book form, NACHSCHLAGEN tap, never a subscribe plus.
        case catalogBook
        /// A radio station (catalog or own list).
        case radioStation
    }

    /// Namespaced item id (`rss:`/`abspod:`/`sub:`/ABS raw), a synthetic
    /// `author:<name>` / `series:<name>`, or the feed URL for shows.
    let id: String
    let kind: Kind
    let title: String
    var subtitle: String? = nil
    var coverURL: URL? = nil
    /// False when the item cannot start right now (offline & not downloaded).
    /// The row follows the overlay-glyph rule (dimmed + wifi.slash).
    var isPlayableNow: Bool = true
    /// The catalog SENDER line of a catalogBook hit (LibriVox/Gutenberg/
    /// Internet Archive). Sources sign their hits.
    var sourceLabel: String? = nil
}

/// Pure section building + the context-ranking matrix.
nonisolated enum SearchRanking {
    /// The FIXED base order of the typed sections; the catalog section is
    /// always last (clearly a catalog, not the user's own content).
    static let baseOrder: [SearchResult.Kind] = [
        .book, .author, .series, .show, .episode, .album, .artist, .song, .playlist, .radioStation, .catalogBook, .catalogShow
    ]

    /// Kinds that belong to a tab. Its sections lead while that tab is active.
    static func kinds(for tab: MediaType) -> [SearchResult.Kind] {
        switch tab {
        case .audiobooks: return [.book, .author, .series]
        case .podcasts: return [.show, .episode]
        case .music: return [.album, .artist, .song, .playlist]
        case .radio: return [.radioStation]
        default: return []
        }
    }

    /// Context ranking: the active tab's sections first (their base order
    /// kept), then the remaining base order; `.catalogShow` always last.
    static func sectionOrder(activeTab: MediaType) -> [SearchResult.Kind] {
        let leading = kinds(for: activeTab)
        let rest = baseOrder.filter {
            !leading.contains($0) && $0 != .catalogShow && $0 != .catalogBook
        }
        return leading + rest + [.catalogBook, .catalogShow]
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

/// Pure local podcast search over the subscription data (shared by the RSS
/// and ABS-podcast providers. One filter, tested once).
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

/// Per-provider timeout. One slow server must not block the others.
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

/// The STANDING scope bar above the results (single select, gliding
/// pill. The MediaTabBar pattern). Replaces the Y15 multi-toggle chips:
/// "Library" = own content of every type (catalog behind the explicit row),
/// a type scope narrows to its sections, where podcasts includes the catalog.
nonisolated enum SearchScope: String, CaseIterable, Identifiable {
    case library, audiobooks, podcasts, music, radio
    var id: String { rawValue }

    /// The scope a search opened from a given tab starts in.
    static func initial(for tab: MediaType) -> SearchScope {
        switch tab {
        case .audiobooks: return .audiobooks
        case .podcasts: return .podcasts
        case .music: return .music
        case .radio: return .radio
        default: return .library
        }
    }

    /// The OWN kinds this scope shows.
    var kinds: Set<SearchResult.Kind> {
        switch self {
        case .library: return Set(SearchResult.Kind.allCases).subtracting([.catalogShow])
        // `.catalogBook` belongs HERE. Otherwise complete results are built
        // and filtered away one line later. Careful when changing it: the
        // same case line exists a second time in `SearchRanking.kinds(for:)`.
        // That one is the ORDER of the sections, not the scope filter, and
        // `.catalogBook` does NOT belong there, because the order appends it
        // itself and the section would otherwise appear twice.
        case .audiobooks: return [.book, .author, .series, .catalogBook]
        case .podcasts: return [.show, .episode]
        case .music: return [.album, .artist, .song, .playlist]
        case .radio: return [.radioStation]
        }
    }

    /// Whether the catalog section renders inline for this scope.
    /// The BOOK scope asks the free catalogs and therefore
    /// needs the card too. Otherwise the old "New Shows" row renders there
    /// and stays empty forever, because nothing fills it any more.
    var includesCatalog: Bool { self == .podcasts || self == .audiobooks }
}
