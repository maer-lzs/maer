// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The library is whole by its distinct ids, never by the number of
/// entries, and a server without a total is paged until a short page.
struct LibraryCompletenessTests {
    @Test("the list is full with as many distinct ids as total; without total it ends at a short page")
    func wholeByDistinctIds() {
        typealias Rule = LibraryCompleteness
        func step(_ before: Int, _ after: Int, page: Int, total: Int) -> Rule.Step {
            Rule.afterPage(distinctBefore: before, distinctAfter: after, pageCount: page, pageSize: 50, total: total)
        }
        #expect(step(150, 200, page: 50, total: 200) == .reachedTotal)
        #expect(step(150, 199, page: 50, total: 200) == .askMore, "a book sent twice made the list whole")
        // With a total, a short page in the middle does not end the list.
        #expect(step(0, 40, page: 40, total: 200) == .askMore, "a short page ended a list with a total")
        // A page that brings nothing new stops, with or without a total.
        #expect(step(59, 59, page: 60, total: 60) == .stalled)
        #expect(step(40, 40, page: 0, total: 200) == .stalled)
        #expect(step(50, 50, page: 50, total: Rule.unknownTotal) == .stalled)
        // No total: the first page is not all of it, a short page ends it.
        #expect(step(0, 50, page: 50, total: Rule.unknownTotal) == .askMore)
        #expect(step(50, 73, page: 23, total: Rule.unknownTotal) == .endedShort)
        // An empty first page without a total is no empty library; an empty
        // page after a whole number of full pages ends the list.
        #expect(step(0, 0, page: 0, total: Rule.unknownTotal) == .stalled,
                "an empty first page counted as a whole library, and the cleanup took the books' rows")
        #expect(step(50, 50, page: 0, total: Rule.unknownTotal) == .endedShort)
        #expect(step(50, 50, page: 10, total: Rule.unknownTotal) == .stalled, "a short page of books held already ended the list")
        #expect(Rule.isWhole(.reachedTotal) && Rule.isWhole(.endedShort))
        #expect(!Rule.isWhole(.stalled) && !Rule.isWhole(.askMore), "a stopped or cut list counted as whole")
    }

    /// A source on the default paging (every page is the whole list) whose
    /// list holds one book twice, longer than a page.
    @MainActor
    final class SamePageTwice: AudioProvider {
        let books: [Maer.LibraryItem]
        var asks = 0
        init() {
            let ids = (0..<59).map { "same-page-\($0)" } + ["same-page-0"]
            books = BookCleanupTests.Libraries(["lib-same": ids]).books["lib-same"] ?? []
        }
        var providerId: String { "same-page-twice" }
        var keepsMarksOnDevice: Bool { false }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [ABSLibrary(id: "lib-same", name: "lib-same", mediaType: "book")] }
        func fetchLibraryItems(libraryId: String) async throws -> [Maer.LibraryItem] {
            asks += 1
            return books
        }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw NSError(domain: "same-page-twice", code: 404) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("the loop against the paging default with a duplicate id: it ends after the second page, and the list is not full",
          .timeLimit(.minutes(1)))
    @MainActor
    func theDefaultPagingEnds() async throws {
        let keys = [AppStorageKeys.selectedLibraryId]
        let saved = keys.map { ($0, AppStorageKeys.object($0)) }
        defer { for (key, value) in saved { AppStorageKeys.set(value, for: key) } }
        AppStorageKeys.set("lib-same", for: AppStorageKeys.selectedLibraryId)
        let provider = SamePageTwice()
        let model = LibraryViewModel(provider: provider)
        await model.loadLibrary()
        await model.keySweep?.value
        #expect(provider.asks == 2, "the load asked the same page \(provider.asks) times")
        #expect(model.keySweep == nil, "a list that never reached its total handed its ids to the cleanup")
    }

    @Test("the library asks the rule and reports an abort while loading more", .needsTheSources)
    func theLibraryAsksTheRule() throws {
        let library = try FetchAnswerTests.squeezedSource("Sources/ViewModels/LibraryViewModel.swift")
        #expect(library.contains("guard LibraryCompleteness.isWhole(step) else {"))
        #expect(library.contains("while step == .askMore {"), "the load asks past the rule")
        #expect(library.contains(#"Logger.library.error("LIBRARY page \(page) brought no new book, loading stops"#))
        #expect(!library.contains("guard accumulated.count >= total else { return nil }"), "the count of entries decides again")
        #expect(library.contains(#"Logger.library.error("LIBRARY page \(page) failed, the list stays partial:"#), "the abort is silent")
        let client = try FetchAnswerTests.squeezedSource("Sources/Networking/APIClient.swift")
        #expect(client.contains("return (response.results, response.total ?? LibraryCompleteness.unknownTotal)"))
    }
}
#endif
