// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The book route finds an entry for a book the grid does not hold, and the
/// route says so when nobody knows the id, instead of drawing nothing.
struct BookRouteEntryTests {
    private func item(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: "T", authorName: "A", narratorName: nil, seriesName: nil,
                                          genres: [], publishedYear: nil, description: nil),
            duration: 100, chapters: [], tracks: []), addedAt: nil)
    }

    @Test("a shelved entry wins and keeps its progress")
    func shelvedEntryWins() {
        let progress = BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 0, currentTime: 50)
        let shelved = LibraryEntry(item: item("b1"), progress: progress)
        let hit = BookRouteEntry.resolve("b1", shelved: shelved, known: item("b1"), playing: item("b1"))
        #expect(hit?.progress?.fraction == 0.5)
    }

    @Test("the playing book outside the grid still gets its page")
    func playingBookOutsideTheGrid() {
        #expect(BookRouteEntry.resolve("np", shelved: nil, known: nil, playing: item("np"))?.id == "np")
        #expect(BookRouteEntry.resolve("k", shelved: nil, known: item("k"), playing: item("np"))?.id == "k")
    }

    @Test("an id nobody knows, or another title playing, yields no entry")
    func unknownIdYieldsNothing() {
        #expect(BookRouteEntry.resolve("x", shelved: nil, known: nil, playing: item("np")) == nil)
        #expect(BookRouteEntry.resolve("x", shelved: nil, known: nil, playing: nil) == nil)
    }

    @Test("a title only on a shelf brings its progress, for the route and the page alike", .needsTheSources)
    @MainActor
    func shelfOnlyTitleBringsItsProgress() throws {
        let library = LibraryViewModel(provider: MockProvider())
        let progress = BookProgress(fraction: 0.25, isFinished: false, lastUpdate: 0, currentTime: 25)
        library.continueListening = [LibraryEntry(item: item("shelf"), progress: progress)]
        #expect(library.entry(id: "shelf") == nil)
        #expect(library.shelvedEntry(id: "shelf")?.progress?.fraction == 0.25)
        let page = try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8)
        #expect(page.contains("libraryViewModel?.shelvedEntry(id: entry.id)?.progress"),
                "the page reads its progress from another source than the route")
    }

    /// A catalog title the player restored by its id alone: no metadata.
    private func bare(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: nil, addedAt: nil)
    }

    @Test("a candidate with a title beats one without, the state of the shelf stays")
    func aTitledCandidateWins() {
        let id = "lva:secret_garden"
        #expect(BookRouteEntry.resolve(id, shelved: nil, known: nil, playing: bare(id))?.item.title
                == bare(id).title, "a bare item still gets its page")
        #expect(BookRouteEntry.resolve(id, shelved: nil, known: bare(id), playing: item(id))?.item.title == "T")
        let progress = BookProgress(fraction: 0.3, isFinished: false, lastUpdate: 0, currentTime: 30)
        let hit = BookRouteEntry.resolve(id, shelved: LibraryEntry(item: bare(id), progress: progress),
                                         known: nil, playing: item(id))
        #expect(hit?.item.title == "T" && hit?.progress?.fraction == 0.3)
    }

    @Test("the page names the title of the loaded details when the entry carries none", .needsTheSources)
    func thePageNamesTheDetailsTitle() throws {
        let id = "lva:secret_garden"
        let detail = LibraryItemDetail(id: id, media: try #require(item(id).media), userMediaProgress: nil)
        #expect(BookPageItem.shown(entry: bare(id), detail: detail).title == "T")
        #expect(BookPageItem.shown(entry: bare(id), detail: nil).id == id)
        // A titled entry keeps its own words.
        let other = LibraryItemDetail(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: "Other", authorName: nil, narratorName: nil, seriesName: nil,
                                          genres: [], publishedYear: nil, description: nil),
            duration: 1, chapters: [], tracks: []), userMediaProgress: nil)
        #expect(BookPageItem.shown(entry: item(id), detail: other).title == "T")
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/BookDetailScreen.swift"), encoding: .utf8))
        #expect(!page.contains("entry.item.title") && !page.contains("entry.item.author"),
                "the page names the entry past the rule")
    }

    @Test("the route asks the rule and draws an empty state, never nothing", .needsTheSources)
    func routeNeverDrawsNothing() throws {
        let source = try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8)
        #expect(source.contains("BookRouteEntry.resolve(itemId"))
        #expect(!source.contains("viewModel.entries.first(where: { $0.id == itemId })"))
    }
}
#endif
