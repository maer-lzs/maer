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

/// Which "no matches" line the results show, if any. While the search still
/// runs there is none: an empty list is not an answer yet, and every source
/// that has not replied could still bring a hit.
nonisolated enum SearchEmptyLine: Equatable, Sendable {
    /// Nothing in the whole library; the catalog steps in below the line.
    case library
    /// Nothing on the one music server the results are narrowed to.
    case server

    static func of(libraryEmpty: Bool, shownEmpty: Bool, narrowed: Bool,
                   searching: Bool, allSourcesFailed: Bool) -> SearchEmptyLine? {
        guard !searching, !allSourcesFailed else { return nil }
        if libraryEmpty { return .library }
        if shownEmpty && narrowed { return .server }
        return nil
    }
}

/// Pure section building + the ONE scoring of the hits.
/// There is no second calculator: everything that decides where a hit
/// stands is a named reason here, and the view only renders the order.
nonisolated enum SearchRanking {
    /// Why a hit scores what it scores. The score is the sum of its
    /// reasons' weights, so a hit can SAY where it stands instead of
    /// only standing there (the DEBUG line prints them).
    enum Reason: String, CaseIterable, Sendable {
        /// The query opens the title.
        case titleStart
        /// The query opens a word inside the title.
        case titleWordStart
        /// The query sits inside a word of the title.
        case titleInside
        /// The match ends on a word boundary too, so it is a whole word.
        case wholeWord
        /// The match is in the second line (author, show, album).
        case subtitle
        /// The match is in the catalog sender line only.
        case sourceLine
        /// Not a catalog find, so the person already has it.
        case own
        /// The person has a position in it, so they are listening to it.
        case started
        /// Its kind belongs to the tab the search was opened from.
        case activeTab
        /// Matched only after one letter was forgiven. It carries NO
        /// points: the tier alone decides, so no pile of bonuses can
        /// lift a tolerated hit over an exact one.
        case tolerated
    }

    static func weight(_ reason: Reason) -> Int {
        switch reason {
        case .titleStart: return 100
        case .titleWordStart: return 60
        case .titleInside: return 30
        case .wholeWord: return 20
        case .subtitle: return 12
        case .sourceLine: return 4
        case .own: return 25
        case .started: return 40
        // Deliberately SMALL. The order says the sections follow their
        // best hit, not a fixed list, so the tab may break a tie between
        // equally good matches; it must never push a weaker match past a
        // better one. Measured on the first run at 50, where a word in
        // the middle of a music title beat a book that OPENED with the
        // query, which is exactly the fixed list in disguise.
        case .activeTab: return 15
        case .tolerated: return 0
        }
    }

    /// A hit's place. `tier` decides FIRST, which is what keeps rule 3
    /// of the order: an exact hit can never fall behind a tolerated one,
    /// however many bonuses the tolerated one collects. `order` is the
    /// position in the source list and breaks every remaining tie, so a
    /// second look at the same results never reshuffles them.
    struct Score: Equatable, Sendable {
        var tier: Int
        var points: Int
        var order: Int

        /// Matched literally.
        static let exactTier = 2
        /// Matched only with one letter forgiven.
        static let toleratedTier = 1
        /// The source sent it, but the query is not in its text at all
        /// (a server may match on things we cannot see, and we never
        /// drop a hit a source stands behind).
        static let untextedTier = 0
    }

    /// True when `a` belongs above `b`.
    static func ranksBefore(_ a: Score, _ b: Score) -> Bool {
        if a.tier != b.tier { return a.tier > b.tier }
        if a.points != b.points { return a.points > b.points }
        return a.order < b.order
    }

    /// One hit with its place and its reasons.
    struct Ranked: Sendable {
        let result: SearchResult
        let score: Score
        let reasons: [Reason]
    }

    /// The tie-break order of the sections. It is no longer the order on
    /// screen (that follows the best hit in each section); it only
    /// decides between sections whose best hit scores the SAME. Source
    /// order would flicker there, because the sources land in whatever
    /// order the network gives them.
    static let baseOrder: [SearchResult.Kind] = [
        .book, .author, .series, .show, .episode, .album, .artist, .song, .playlist, .radioStation, .catalogBook, .catalogShow
    ]

    /// Kinds that belong to a tab. A hit of such a kind scores a bonus
    /// while that tab is active.
    static func kinds(for tab: MediaType) -> [SearchResult.Kind] {
        switch tab {
        case .audiobooks: return [.book, .author, .series]
        case .podcasts: return [.show, .episode]
        case .music: return [.album, .artist, .song, .playlist]
        case .radio: return [.radioStation]
        default: return []
        }
    }

    /// The two kinds that are a catalog find, not the person's own item.
    static let catalogKinds: Set<SearchResult.Kind> = [.catalogBook, .catalogShow]

    /// Case- and diacritic-folded, so "Bjork" finds "Björk" and the
    /// comparison below can work on plain substrings.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// The BEST place `needle` takes in `haystack` (both folded). The
    /// first occurrence is not automatically the best one: "The Kafka
    /// Papers" would otherwise be judged by a match no reader cares
    /// about, so every occurrence is looked at.
    static func place(of needle: String, in haystack: String) -> (reason: Reason, wholeWord: Bool)? {
        guard !needle.isEmpty else { return nil }
        var best: (reason: Reason, wholeWord: Bool)?
        var from = haystack.startIndex
        while let range = haystack.range(of: needle, range: from..<haystack.endIndex) {
            let opensText = range.lowerBound == haystack.startIndex
            let opensWord = opensText
                || !isWordCharacter(haystack[haystack.index(before: range.lowerBound)])
            let closesWord = range.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[range.upperBound])
            let reason: Reason = opensText ? .titleStart : (opensWord ? .titleWordStart : .titleInside)
            let candidate = (reason, opensWord && closesWord)
            if best == nil || weight(candidate.0) > weight(best!.reason)
                || (weight(candidate.0) == weight(best!.reason) && candidate.1 && !best!.wholeWord) {
                best = candidate
            }
            if reason == .titleStart && candidate.1 { return candidate }  // nothing can beat it
            from = haystack.index(after: range.lowerBound)
        }
        return best
    }

    /// One letter too many, or two letters swapped: the two mistakes a
    /// person actually makes while typing. From FOUR characters on,
    /// because below that nearly every short word is a neighbour of
    /// every other and the tolerance would only add noise.
    static func tolerantVariants(of query: String) -> [String] {
        let characters = Array(query)
        guard characters.count >= 4 else { return [] }
        var out: [String] = []
        for index in characters.indices {
            var copy = characters
            copy.remove(at: index)
            out.append(String(copy))
        }
        for index in 0..<(characters.count - 1) where characters[index] != characters[index + 1] {
            var copy = characters
            copy.swapAt(index, index + 1)
            out.append(String(copy))
        }
        return out
    }

    /// The reasons one hit collects, and whether it needed the tolerance.
    /// The tolerance is asked ONLY when the hit carries no literal match
    /// at all, which is rule 3 of the order read per hit: a source's hit
    /// is never dropped, it is placed.
    static func reasons(for result: SearchResult, query: String,
                        activeTab: MediaType, startedIds: Set<String>) -> (tier: Int, reasons: [Reason]) {
        var reasons: [Reason] = []
        if !catalogKinds.contains(result.kind) { reasons.append(.own) }
        if startedIds.contains(result.id) { reasons.append(.started) }
        if kinds(for: activeTab).contains(result.kind) { reasons.append(.activeTab) }

        let title = folded(result.title)
        let subtitle = result.subtitle.map(folded)
        let sourceLine = result.sourceLabel.map(folded)

        func textReasons(for needle: String) -> [Reason]? {
            if let hit = place(of: needle, in: title) {
                return hit.wholeWord ? [hit.reason, .wholeWord] : [hit.reason]
            }
            if let subtitle, place(of: needle, in: subtitle) != nil { return [.subtitle] }
            if let sourceLine, place(of: needle, in: sourceLine) != nil { return [.sourceLine] }
            return nil
        }

        let needle = folded(query)
        if let found = textReasons(for: needle) {
            return (Score.exactTier, reasons + found)
        }
        for variant in tolerantVariants(of: needle) {
            if let found = textReasons(for: variant) {
                return (Score.toleratedTier, reasons + found + [.tolerated])
            }
        }
        return (Score.untextedTier, reasons)
    }

    /// Every hit with its place, best first.
    static func ranked(results: [SearchResult], query: String, activeTab: MediaType,
                       startedIds: Set<String> = []) -> [Ranked] {
        let scored = results.enumerated().map { index, result -> Ranked in
            let found = reasons(for: result, query: query,
                                activeTab: activeTab, startedIds: startedIds)
            let points = found.reasons.reduce(0) { $0 + weight($1) }
            return Ranked(result: result,
                          score: Score(tier: found.tier, points: points, order: index),
                          reasons: found.reasons)
        }
        return scored.sorted { ranksBefore($0.score, $1.score) }
    }

    /// Group results into non-empty sections. The sections keep their
    /// meaning (they are the orientation), but their ORDER follows the
    /// best hit inside instead of a fixed list; inside a section the
    /// hits stand by their score.
    static func sections(results: [SearchResult], query: String, activeTab: MediaType,
                         startedIds: Set<String> = [])
        -> [(kind: SearchResult.Kind, results: [SearchResult])] {
        let ranked = ranked(results: results, query: query,
                            activeTab: activeTab, startedIds: startedIds)
        var best: [SearchResult.Kind: Score] = [:]
        var grouped: [SearchResult.Kind: [SearchResult]] = [:]
        for hit in ranked {
            if best[hit.result.kind] == nil { best[hit.result.kind] = hit.score }
            grouped[hit.result.kind, default: []].append(hit.result)
        }
        let rank = Dictionary(uniqueKeysWithValues: baseOrder.enumerated().map { ($1, $0) })
        return grouped.keys.sorted { left, right in
            let a = best[left]!, b = best[right]!
            if a.tier != b.tier { return a.tier > b.tier }
            if a.points != b.points { return a.points > b.points }
            return (rank[left] ?? baseOrder.count) < (rank[right] ?? baseOrder.count)
        }.map { ($0, grouped[$0]!) }
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
/// pill. The MediaTabBar pattern), not multi-toggle chips:
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

    /// The tab whose glyph the scope wears in the side column: the library
    /// scope the house, every other its own tab.
    var tab: MediaType {
        switch self {
        case .library: return .home
        case .audiobooks: return .audiobooks
        case .podcasts: return .podcasts
        case .music: return .music
        case .radio: return .radio
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
