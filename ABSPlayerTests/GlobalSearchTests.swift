// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// F6: pure ranking matrix, local podcast filter, per-provider timeout, and the
/// aggregator's debounce/cancel/partial/failure behaviour with mock providers.
struct SearchRankingTests {
    @Test("context ranking: the active tab's sections lead, catalog is always last")
    func contextMatrix() {
        #expect(SearchRanking.sectionOrder(activeTab: .audiobooks).first == .book)
        #expect(SearchRanking.sectionOrder(activeTab: .music).prefix(3) == [.album, .artist, .song])
        #expect(SearchRanking.sectionOrder(activeTab: .podcasts).prefix(2) == [.show, .episode])
        for tab in [MediaType.home, .audiobooks, .podcasts, .music] {
            let order = SearchRanking.sectionOrder(activeTab: tab)
            #expect(order.last == .catalogShow)
            #expect(Set(order) == Set(SearchRanking.baseOrder))   // nothing lost, nothing doubled
        }
        // Home has no leading kinds → plain base order.
        #expect(SearchRanking.sectionOrder(activeTab: .home) == SearchRanking.baseOrder)
    }

    @Test("sections drop empty kinds and keep the order")
    func sectionsBuild() {
        let results = [
            SearchResult(id: "s1", kind: .song, title: "Song"),
            SearchResult(id: "b1", kind: .book, title: "Book"),
            SearchResult(id: "c1", kind: .catalogShow, title: "Catalog"),
        ]
        let sections = SearchRanking.sections(results: results, activeTab: .music)
        #expect(sections.map(\.kind) == [.song, .book, .catalogShow])
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
        #expect(SearchScope.audiobooks.kinds == [.book, .author, .series])
        #expect(SearchScope.music.kinds == [.album, .artist, .song])
        #expect(!SearchScope.audiobooks.includesCatalog && !SearchScope.music.includesCatalog)
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
        let model = GlobalSearchModel(providers: { providers }, catalog: { _ in catalog })
        model.debounceOverride = .zero
        return model
    }

    private func waitUntil(_ deadline: Duration = .seconds(3),
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
        // exactly ONE section with ONE hit — a late publish from the cancelled
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
            catalog: { _ in throw NSError(domain: "mock", code: 2) })
        failing.debounceOverride = .zero
        failing.query = "xx"
        failing.queryChanged(activeTab: .home)
        await waitUntil { failing.allSourcesFailed }
        #expect(failing.allSourcesFailed)
    }
}
#endif
