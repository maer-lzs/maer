// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Pure ranking matrix, local podcast filter, per-provider timeout, and the
/// aggregator's debounce/cancel/partial/failure behaviour with mock providers.
struct SearchRankingTests {
    @Test("context ranking: with equal text the active tab's sections lead and catalog sinks")
    func contextMatrix() {
        // Same title, same match, different kinds: only the context
        // reasons can separate them.
        func order(_ tab: MediaType) -> [SearchResult.Kind] {
            let results = SearchRanking.baseOrder.enumerated().map {
                SearchResult(id: "id\($0.offset)", kind: $0.element, title: "Kafka")
            }
            return SearchRanking.sections(results: results, query: "Kafka", activeTab: tab).map(\.kind)
        }
        #expect(order(.audiobooks).prefix(3) == [.book, .author, .series])
        #expect(order(.music).prefix(4) == [.album, .artist, .song, .playlist])
        #expect(order(.podcasts).prefix(2) == [.show, .episode])
        for tab in [MediaType.home, .audiobooks, .podcasts, .music] {
            let sections = order(tab)
            #expect(sections.suffix(2) == [.catalogBook, .catalogShow])  // a catalog find is not own
            #expect(Set(sections) == Set(SearchRanking.baseOrder))       // nothing lost, nothing doubled
        }
        // Home leads no kind, so only "own before catalog" remains and
        // the base order breaks the tie among the own kinds.
        #expect(order(.home) == SearchRanking.baseOrder)
    }

    @Test("sections drop empty kinds; the section order follows its best hit")
    func sectionsBuild() {
        let results = [
            SearchResult(id: "s1", kind: .song, title: "A Song"),
            SearchResult(id: "b1", kind: .book, title: "Song of Ice"),
            SearchResult(id: "c1", kind: .catalogShow, title: "Song Catalog"),
        ]
        // The book opens with the query, the song only carries it inside,
        // so the book section leads although music is the active tab.
        let sections = SearchRanking.sections(results: results, query: "Song", activeTab: .music)
        #expect(sections.map(\.kind) == [.book, .song, .catalogShow])
        // Kinds nobody hit do not appear at all.
        #expect(!sections.map(\.kind).contains(.episode))
    }

    @Test("the title beats the middle, the whole word beats the part")
    func titlePlaces() {
        func points(_ title: String, _ query: String) -> Int {
            SearchRanking.ranked(results: [SearchResult(id: "x", kind: .book, title: title)],
                                 query: query, activeTab: .home).first!.score.points
        }
        // Opening the title beats opening a word inside it, which beats
        // sitting inside a word.
        #expect(points("Kafka am Strand", "Kafka") > points("Der Kafka Prozess", "Kafka"))
        #expect(points("Der Kafka Prozess", "Kafka") > points("Unkafkaesk", "Kafka"))
        // Same place, but one is the whole word and the other is not.
        #expect(points("Kafka am Strand", "Kafka") > points("Kafkaesk am Strand", "Kafka"))
    }

    @Test("a hit in the title beats the same word in the author line")
    func titleBeatsSubtitle() {
        let results = [
            SearchResult(id: "sub", kind: .book, title: "Der Prozess", subtitle: "Franz Kafka"),
            SearchResult(id: "title", kind: .book, title: "Kafka am Strand", subtitle: "Haruki Murakami"),
        ]
        let ranked = SearchRanking.ranked(results: results, query: "Kafka", activeTab: .home)
        #expect(ranked.map(\.result.id) == ["title", "sub"])
        #expect(ranked.last!.reasons.contains(.subtitle))
    }

    @Test("what the person has or listens to beats a catalog find")
    func ownBeatsCatalog() {
        let results = [
            SearchResult(id: "cat", kind: .catalogBook, title: "Der Prozess"),
            SearchResult(id: "own", kind: .book, title: "Der Prozess"),
        ]
        #expect(SearchRanking.ranked(results: results, query: "Prozess", activeTab: .home)
            .map(\.result.id) == ["own", "cat"])
        // And a started one beats an untouched one of the same kind.
        let two = [
            SearchResult(id: "cold", kind: .book, title: "Der Prozess"),
            SearchResult(id: "warm", kind: .book, title: "Der Prozess"),
        ]
        #expect(SearchRanking.ranked(results: two, query: "Prozess", activeTab: .home,
                                     startedIds: ["warm"]).map(\.result.id) == ["warm", "cold"])
    }

    @Test("a tie keeps the source order, so a second look does not reshuffle")
    func tieKeepsSourceOrder() {
        let results = (0..<5).map { SearchResult(id: "id\($0)", kind: .book, title: "Der Prozess") }
        let ranked = SearchRanking.ranked(results: results, query: "Prozess", activeTab: .home)
        #expect(ranked.map(\.result.id) == ["id0", "id1", "id2", "id3", "id4"])
        // Reversed input reverses the output: the order comes from the
        // source, not from the ids.
        #expect(SearchRanking.ranked(results: results.reversed(), query: "Prozess", activeTab: .home)
            .map(\.result.id) == ["id4", "id3", "id2", "id1", "id0"])
    }

    @Test("one letter is forgiven, but never over an exact hit")
    func toleranceOnlyWithoutExact() {
        // One letter too many, and two swapped.
        #expect(SearchRanking.tolerantVariants(of: "kafkla").contains("kafka"))
        #expect(SearchRanking.tolerantVariants(of: "kakfa").contains("kafka"))
        // Under four characters nothing is forgiven.
        #expect(SearchRanking.tolerantVariants(of: "kaf").isEmpty)

        let results = [
            SearchResult(id: "typo", kind: .book, title: "Kafka am Strand"),
            SearchResult(id: "exact", kind: .catalogBook, title: "Kafkla Notizen"),
        ]
        let ranked = SearchRanking.ranked(results: results, query: "Kafkla", activeTab: .home)
        // The catalog find matches literally and still wins over the own,
        // tolerated one: the tier decides before any bonus.
        #expect(ranked.map(\.result.id) == ["exact", "typo"])
        #expect(ranked.first!.score.tier == SearchRanking.Score.exactTier)
        #expect(ranked.last!.reasons.contains(.tolerated))
        // With an exact match of its own the hit never asks for tolerance.
        let clean = SearchRanking.ranked(results: [results[0]], query: "Kafka", activeTab: .home)
        #expect(!clean.first!.reasons.contains(.tolerated))
    }

    @Test("a hit whose text does not carry the query is placed, never dropped")
    func untextedHitStays() {
        // A server may match on things we cannot see (a description, a
        // tag). Ranking it last is honest; dropping it would hide a hit
        // the source stands behind.
        let results = [
            SearchResult(id: "hidden", kind: .book, title: "Nichts davon"),
            SearchResult(id: "plain", kind: .book, title: "Kafka"),
        ]
        let ranked = SearchRanking.ranked(results: results, query: "Kafka", activeTab: .home)
        #expect(ranked.map(\.result.id) == ["plain", "hidden"])
        #expect(ranked.last!.score.tier == SearchRanking.Score.untextedTier)
    }

    @Test("folding: accents and case do not decide")
    func foldingHolds() {
        let results = [SearchResult(id: "b", kind: .artist, title: "Björk")]
        #expect(SearchRanking.ranked(results: results, query: "bjork", activeTab: .home)
            .first!.score.tier == SearchRanking.Score.exactTier)
    }

    @Test("local podcast filter matches show and episode titles, case/diacritic-insensitive")
    func localPodcastFilter() {
        let shows: [(feedURL: String, title: String, coverURL: URL?, episodes: [(id: String, title: String)])] = [
            ("https://a/feed", "Kurios", nil, [("rss:e1", "Über Käuze"), ("rss:e2", "Anderes")]),
        ]
        let hits = PodcastLocalSearch.results(shows: shows, query: "kauze")
        #expect(hits.map(\.id) == ["rss:e1"])
        let showHit = PodcastLocalSearch.results(shows: shows, query: "kurios")
        #expect(showHit.first?.kind == .show)
    }

    @Test("Y20 scopes: kinds matrix, catalog rule, initial scope per tab")
    func scopeMatrix() {
        #expect(SearchScope.library.kinds
                == Set(SearchResult.Kind.allCases).subtracting([.catalogShow]))
        #expect(!SearchScope.library.includesCatalog)
        #expect(SearchScope.podcasts.kinds == [.show, .episode])
        #expect(SearchScope.podcasts.includesCatalog)
        // Dieser Fall stand vorher als `[.book, .author, .series]` +
        // `!includesCatalog` und schrieb damit die kaputte Verdrahtung fest.
        // Ein
        // Unit-Test über eine Filtermenge ist KEIN Zaun gegen "erreicht nie
        // den Schirm". Das kann nur die Journey
        // (`testBookScopeShowsCatalogResults`).
        #expect(SearchScope.audiobooks.kinds == [.book, .author, .series, .catalogBook])
        #expect(SearchScope.audiobooks.includesCatalog)
        #expect(SearchScope.music.kinds == [.album, .artist, .song, .playlist])
        #expect(!SearchScope.music.includesCatalog)
        // The search opens in the scope of the tab it was started from.
        #expect(SearchScope.initial(for: .audiobooks) == .audiobooks)
        #expect(SearchScope.initial(for: .podcasts) == .podcasts)
        #expect(SearchScope.initial(for: .music) == .music)
        #expect(SearchScope.initial(for: .home) == .library)
    }

    @Test("the search timeout returns the fast result and nil for the slow one")
    func timeout() async {
        let fast = await withSearchTimeout(.milliseconds(500)) { 42 }
        #expect(fast == 42)
        let slow: Int? = await withSearchTimeout(.milliseconds(50)) {
            try await Task.sleep(for: .seconds(2))
            return 1
        }
        #expect(slow == nil)
    }
}

/// Aggregator behaviour with mock providers (injected; debounce shrunk).
@MainActor
struct GlobalSearchModelTests {
    private struct MockProvider: SearchableProvider {
        let results: [SearchResult]
        var delay: Duration = .zero
        var fails = false
        func search(query: String) async throws -> [SearchResult] {
            if delay > .zero { try await Task.sleep(for: delay) }
            if fails { throw NSError(domain: "mock", code: 1) }
            return results
        }
    }

    private func makeModel(providers: [any SearchableProvider],
                           catalog: [SearchResult] = []) -> GlobalSearchModel {
        let model = GlobalSearchModel(providers: { providers }, catalog: { _, _ in catalog })
        model.debounceOverride = .zero
        return model
    }

    /// Die Suite muss ZWEIMAL hintereinander gruen sein: eine Frist von 3 s
    /// macht das Gruen lastabhaengig. Im zweiten Lauf auf
    /// demselben Simulator brauchten die Faelle 4,2 s und fielen rot, ohne
    /// dass etwas kaputt war. Die Schleife bricht ab, sobald die Bedingung
    /// wahr ist; eine grosszuegige Frist kostet nur im Fehlerfall Zeit und
    /// sagt dort dasselbe aus.
    private func waitUntil(_ deadline: Duration = .seconds(20),
                           _ condition: @MainActor () -> Bool) async {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("results aggregate across providers + catalog, ranked by the active tab")
    func aggregates() async {
        let model = makeModel(
            providers: [MockProvider(results: [SearchResult(id: "b", kind: .book, title: "B")]),
                        MockProvider(results: [SearchResult(id: "a", kind: .album, title: "A")])],
            catalog: [SearchResult(id: "c", kind: .catalogShow, title: "C")])
        model.query = "xx"
        model.queryChanged(activeTab: .music)
        await waitUntil { !model.isSearching && model.sections.count == 3 }
        #expect(model.sections.map(\.kind) == [.album, .book, .catalogShow])
        #expect(!model.allSourcesFailed)
    }

    @Test("below the server minimum nothing runs; results clear")
    func minChars() async {
        let model = makeModel(providers: [MockProvider(results: [SearchResult(id: "b", kind: .book, title: "B")])])
        model.query = "xx"
        model.queryChanged(activeTab: .home)
        await waitUntil { !model.sections.isEmpty }
        model.query = "x"
        model.queryChanged(activeTab: .home)
        #expect(model.sections.isEmpty)
        #expect(!model.isSearching)
    }

    @Test("new input cancels the previous run — only the latest results land")
    func cancelOnNewInput() async {
        let slow = MockProvider(results: [SearchResult(id: "hit", kind: .book, title: "Hit")],
                                delay: .milliseconds(250))
        let model = makeModel(providers: [slow])
        model.query = "first"
        model.queryChanged(activeTab: .home)
        // Supersede before the slow provider answers: the first run's task is
        // cancelled and must never publish late.
        model.query = "second"
        model.queryChanged(activeTab: .home)
        await waitUntil { !model.isSearching && !model.sections.isEmpty }
        // Let any (wrongly surviving) first run land too, then check stability:
        // exactly ONE section with ONE hit. A late publish from the cancelled
        // run would double the results or flip isSearching back.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.sections.count == 1)
        #expect(model.sections.first?.results.map(\.id) == ["hit"])
        #expect(!model.isSearching)
    }

    @Test("every source failing is a visible state, never a silent empty list")
    func totalFailure() async {
        let model = makeModel(providers: [MockProvider(results: [], fails: true)],
                              catalog: [])
        // Catalog succeeds (empty) → NOT a total failure.
        model.query = "xx"
        model.queryChanged(activeTab: .home)
        await waitUntil { !model.isSearching }
        #expect(!model.allSourcesFailed)

        // Now the catalog fails too → total failure.
        let failing = GlobalSearchModel(
            providers: { [MockProvider(results: [], fails: true)] },
            catalog: { _, _ in throw NSError(domain: "mock", code: 2) })
        failing.debounceOverride = .zero
        failing.query = "xx"
        failing.queryChanged(activeTab: .home)
        await waitUntil { failing.allSourcesFailed }
        #expect(failing.allSourcesFailed)
    }
}
#endif
