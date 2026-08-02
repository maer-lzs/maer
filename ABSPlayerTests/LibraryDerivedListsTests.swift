// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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

    @Test("TF4/E2: indexById maps ids to entries, first entry wins on a duplicate id")
    func e2IndexById() {
        let entries = [
            entry(id: "b1", title: "One"),
            entry(id: "b2", title: "Two"),
            entry(id: "b1", title: "Dup"),   // duplicate id
        ]
        let index = LibraryViewModel.indexById(entries)
        #expect(index.count == 2)
        #expect(index["b1"]?.item.title == "One")   // first wins (mirrors first(where:))
        #expect(index["b2"]?.item.title == "Two")
        #expect(index["missing"] == nil)
    }

    @Test("TF1: multi-file frozen server fraction → makeEntry recomputes from currentTime / local duration")
    func tf1MultiFileProgress() {
        let item = entry(id: "mf", title: "Multi").item   // media.duration = 100
        func frac(_ p: BookProgress) -> Double {
            LibraryViewModel.makeEntry(item: item, progress: ["mf": p], queued: [:]).progress?.fraction ?? -1
        }
        // Stale server fraction 0.10 but currentTime at 50/100 → authoritative ~0.50.
        #expect(abs(frac(BookProgress(fraction: 0.10, isFinished: false, lastUpdate: 5, currentTime: 50)) - 0.50) < 0.001)
        // Single-file (server fraction == currentTime/duration) unchanged.
        #expect(abs(frac(BookProgress(fraction: 0.30, isFinished: false, lastUpdate: 5, currentTime: 30)) - 0.30) < 0.001)
        // Finished stays finished and full (no recompute, no un-finish).
        let done = LibraryViewModel.makeEntry(
            item: item, progress: ["mf": BookProgress(fraction: 1.0, isFinished: true, lastUpdate: 5, currentTime: 90)], queued: [:])
        #expect(done.progress?.isFinished == true)
        #expect((done.progress?.fraction ?? 0) == 1.0)
        // No local duration → keep the server fraction (not 0).
        let noDur = LibraryItem(
            id: "nd",
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "ND", authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
            addedAt: nil)
        let kept = LibraryViewModel.makeEntry(
            item: noDur, progress: ["nd": BookProgress(fraction: 0.12, isFinished: false, lastUpdate: 5, currentTime: 999)], queued: [:])
        #expect(abs((kept.progress?.fraction ?? 0) - 0.12) < 0.001)
    }

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

    @Test("66f974c: time line ALWAYS filled — remaining when started, total runtime otherwise")
    func timeLine() {
        // Locale-robust (the suite runs on the de sim): assert the NUMBERS
        // and non-emptiness, not localized words.
        let started = BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 0, currentTime: 15_660)
        let remaining = bookTimeLine(progress: started, duration: 31_320)
        #expect(remaining.contains("4") && remaining.contains("21"))
        // Unstarted (the ~95 % case): TOTAL runtime instead of an empty line.
        let total = bookTimeLine(progress: nil, duration: 31_260)
        #expect(total.contains("8") && total.contains("41"))
        #expect(total != remaining)
        #expect(bookTimeLine(progress: nil, duration: 2_460).contains("41"))
        let done = BookProgress(fraction: 1, isFinished: true, lastUpdate: 0, currentTime: 100)
        #expect(!bookTimeLine(progress: done, duration: 100).trimmingCharacters(in: .whitespaces).isEmpty)
        // No duration known at all → space keeps the reserve.
        #expect(bookTimeLine(progress: nil, duration: nil) == " ")
    }
}
#endif
