#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// P1 regression: the memoized `sortedFilteredEntries` / `seriesGroupedEntries`
/// must be IDENTICAL to a fresh computation after every mutation — a wrong or
/// missing cache invalidation (stale list) must turn these red.
@MainActor
struct LibraryDerivedListsTests {

    // MARK: - Fixtures

    private func entry(
        id: String, title: String, author: String? = nil, series: String? = nil,
        addedAt: Double? = nil, finished: Bool = false, lastUpdate: Double = 0
    ) -> LibraryEntry {
        let item = LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: title, authorName: author, narratorName: nil,
                    seriesName: series, genres: nil, publishedYear: nil, description: nil
                ),
                duration: 100, chapters: nil, tracks: nil
            ),
            addedAt: addedAt
        )
        let progress = lastUpdate > 0 || finished
            ? BookProgress(fraction: finished ? 1 : 0.4, isFinished: finished, lastUpdate: lastUpdate)
            : nil
        return LibraryEntry(item: item, progress: progress)
    }

    private var fixtureEntries: [LibraryEntry] {
        [
            entry(id: "b1", title: "Zeta", author: "Adams", series: "Saga #2", addedAt: 100, lastUpdate: 50),
            entry(id: "b2", title: "alpha", author: "Brown", series: "Saga #1", addedAt: 300, finished: true, lastUpdate: 200),
            entry(id: "b3", title: "Mitte", author: "adams", addedAt: 200, lastUpdate: 300),
            entry(id: "b4", title: "Ärger", author: "Clark", series: "Solo #1", addedAt: 50),
            entry(id: "b5", title: "beta", author: "brown", series: "saga #3", addedAt: 400, lastUpdate: 100),
        ]
    }

    /// LibraryViewModel persists sort/filter to UserDefaults.standard in didSet —
    /// snapshot and restore those keys so tests don't pollute the app state.
    private func withCleanSortDefaults(_ body: (LibraryViewModel) -> Void) {
        let defaults = UserDefaults.standard
        let keys = [AppStorageKeys.librarySortOption,
                    AppStorageKeys.libraryFilterOption,
                    AppStorageKeys.librarySortAscending]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let vm = LibraryViewModel(provider: LocalProvider.shared)
        body(vm)
    }

    /// Stable comparison signature for grid entries.
    private func signature(_ entries: [LibraryViewModel.GridEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .single(let e): return "single:\(e.id)"
            case .series(let name, let books): return "series:\(name):\(books.map(\.id).joined(separator: ","))"
            }
        }
    }

    /// The memoized accessors must equal a fresh computation right now.
    private func expectFresh(_ vm: LibraryViewModel,
                             _ comment: Comment? = nil) {
        #expect(vm.sortedFilteredEntries.map(\.id) == vm.computeSortedFilteredEntries().map(\.id), comment)
        #expect(signature(vm.seriesGroupedEntries) == signature(vm.computeSeriesGroupedEntries()), comment)
    }

    // MARK: - X16b: a restart clears the local finished flag

    @Test("markUnfinishedLocally clears the finished flag across the library lists")
    func markUnfinishedLocallyClears() {
        withCleanSortDefaults { vm in
            let done = entry(id: "b2", title: "Done", finished: true, lastUpdate: 200)
            vm.entries = [done]
            vm.continueListening = [done]
            vm.recentlyAdded = [done]
            #expect(vm.entries[0].progress?.isFinished == true)

            vm.markUnfinishedLocally(itemId: "b2")
            #expect(vm.entries[0].progress?.isFinished == false)
            #expect(vm.entries[0].progress?.fraction == 0)
            #expect(vm.continueListening[0].progress?.isFinished == false)
            #expect(vm.recentlyAdded[0].progress?.isFinished == false)

            // An unknown / not-finished item is a safe no-op.
            vm.markUnfinishedLocally(itemId: "nope")
        }
    }

    // MARK: - T1b: memoization stays fresh across every mutation

    @Test func memoMatchesFreshComputationAcrossMutations() {
        withCleanSortDefaults { vm in
            vm.sortOption = .titel
            vm.filterOption = .alle
            vm.entries = fixtureEntries
            expectFresh(vm, "initial fill")

            // Repeated reads (cache hits) stay correct.
            expectFresh(vm, "repeated read")

            // Adding an entry must invalidate.
            let before = vm.sortedFilteredEntries.map(\.id)
            vm.entries.append(entry(id: "b6", title: "AAA erstes", addedAt: 999))
            expectFresh(vm, "after append")
            #expect(vm.sortedFilteredEntries.map(\.id) != before, "append must change the title sort")

            // Removing an entry must invalidate.
            vm.entries.removeAll { $0.id == "b6" }
            expectFresh(vm, "after remove")
            #expect(vm.sortedFilteredEntries.map(\.id) == before)

            // Every sort option + direction flip.
            for option in SortOption.allCases {
                vm.sortOption = option
                expectFresh(vm, "sort \(option.rawValue)")
                vm.sortAscending.toggle()
                expectFresh(vm, "direction \(option.rawValue)")
            }

            // Every filter (incl. .heruntergeladen, which depends on downloads).
            for filter in FilterOption.allCases {
                vm.filterOption = filter
                expectFresh(vm, "filter \(filter.rawValue)")
            }
        }
    }

    @Test func sortingBehavesAsExpected() {
        withCleanSortDefaults { vm in
            vm.entries = fixtureEntries
            vm.filterOption = .alle

            vm.sortOption = .titel   // didSet resets direction to ascending
            // Locale-aware, case-insensitive: alpha < Ärger < beta < Mitte < Zeta.
            #expect(vm.sortedFilteredEntries.map(\.id) == ["b2", "b4", "b5", "b3", "b1"])

            vm.sortAscending = false
            #expect(vm.sortedFilteredEntries.map(\.id) == ["b1", "b3", "b5", "b4", "b2"])

            vm.sortOption = .zuletztHinzugefuegt   // default: newest first
            #expect(vm.sortedFilteredEntries.map(\.id) == ["b5", "b2", "b3", "b1", "b4"])

            vm.sortOption = .zuletztGehoert   // by progress lastUpdate, newest first
            #expect(vm.sortedFilteredEntries.first?.id == "b3")

            vm.sortOption = .titel
            vm.filterOption = .fertig
            #expect(vm.sortedFilteredEntries.map(\.id) == ["b2"])
            vm.filterOption = .unfertig
            #expect(!vm.sortedFilteredEntries.map(\.id).contains("b2"))
        }
    }

    // MARK: - Series grouping semantics

    @Test func seriesGroupingBuildsStacksAndSingles() {
        withCleanSortDefaults { vm in
            vm.sortOption = .serie
            vm.filterOption = .alle
            vm.entries = fixtureEntries

            let sig = signature(vm.seriesGroupedEntries)
            // "Saga" has 3 books (#1/#2/#3, case-insensitive "saga" included) → stack
            // ordered by volume; "Solo" has one book → renders as a single.
            #expect(sig.contains("series:Saga:b2,b1,b5"))
            #expect(sig.contains("single:b4"))
            #expect(sig.contains("single:b3"))
            #expect(!sig.contains { $0.hasPrefix("series:Solo") })
        }
    }

    @Test("Filter keeps a stack when ANY book matches, drops it when none do")
    func seriesGroupingRespectsFilter() {
        withCleanSortDefaults { vm in
            vm.sortOption = .serie
            vm.entries = fixtureEntries

            // b2 (Saga #1) is finished; the Saga stack must survive the
            // "finished" filter even though its other books don't match.
            vm.filterOption = .fertig
            let finished = signature(vm.seriesGroupedEntries)
            #expect(finished.contains("series:Saga:b2,b1,b5"))
            #expect(!finished.contains("single:b4"))

            // Under "unfinished" the stack also survives (b1/b5 match).
            vm.filterOption = .unfertig
            let unfinished = signature(vm.seriesGroupedEntries)
            #expect(unfinished.contains("series:Saga:b2,b1,b5"))
            #expect(unfinished.contains("single:b4"))
        }
    }

    @Test("Multi-series names group under the FIRST series")
    func multiSeriesNameGroupsUnderFirst() {
        withCleanSortDefaults { vm in
            vm.sortOption = .serie
            vm.filterOption = .alle
            vm.entries = [
                entry(id: "m1", title: "One", series: "Alpha #1"),
                entry(id: "m2", title: "Two", series: "Alpha #2, Beta #7"),
            ]
            let sig = signature(vm.seriesGroupedEntries)
            #expect(sig.contains("series:Alpha:m1,m2"))
        }
    }
}
#endif
