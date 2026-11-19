// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// How a chapter entry ends: at the book's end, by a surface that shows a
/// book, and in the player by any way at all.
struct ChapterEntryShownAsBookTests {
    static let chapters = [ABSChapter(id: 0, start: 0, end: 600, title: "One"),
                           ABSChapter(id: 1, start: 600, end: 1200, title: "Two")]

    @Test("a surface that shows a book offers its chapters whatever the source, music never offers them, a catalogue album without its form neither")
    func aBookShownAsABookOffersChapters() {
        #expect(ChapterEntryRules.offersChapters(itemId: "sub:album:a1", chapters: Self.chapters, shownAsBook: true),
                "an audiobook of a music server offered no chapters on its book's page")
        #expect(!ChapterEntryRules.offersChapters(itemId: "sub:album:a1", chapters: Self.chapters, shownAsBook: false))
        #expect(!ChapterEntryRules.offersChapters(itemId: "lva:some-release", chapters: Self.chapters, shownAsBook: false),
                "a catalogue album without its form offered its tracks as chapters")
        #expect(ChapterEntryRules.offersChapters(itemId: "li_book-1", chapters: Self.chapters, shownAsBook: false))
        #expect(!ChapterEntryRules.offersChapters(itemId: "rss:feed:ep-1", chapters: Self.chapters, shownAsBook: true),
                "an episode offered its chapters because a surface called it a book")
    }
}

@MainActor
struct ChapterEntryEndTests {
    @Test("the end of the book in its last chapter as an entry advances once, finishes nothing and tells the server nothing is finished", .needsAudio)
    func theLastChapterAtTheBooksEnd() async throws {
        let file = try TickWorkTests().tone(seconds: 20)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "chapterbookend-\(UUID().uuidString)"
        let server = ChapterEntryQueueTests.ChapteredServer(file: file.path, duration: 20, position: 12)
        let model = PlayerViewModel(provider: server, localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: try await server.fetchItemDetail(itemId: id))
        await model.reconcileWithServer()
        try #require(model.chapters.count == 2, "the precondition: the book has its two chapters")
        let last = model.chapters[1]
        var advanced = 0
        var finished: [String] = []
        model.onBookFinished = { finished.append($0) }
        await model.startChapterEntry(last)
        // The end of the range starts what follows; the next title takes the
        // player over, which ends the entry in the old one.
        model.watchChapterRange(last) {
            advanced += 1
            model.endChapterEntry()
        }
        await model.finishBook()
        #expect(advanced == 1, "the range ended \(advanced) times")
        #expect(finished.isEmpty, "the book's end advanced a second time: \(finished)")
        #expect(!model.isFinished, "the book counts as finished on the device")
        #expect(server.finishedWrites == 0, "the server heard the book is finished")
        model.stop()
    }

    @Test("every end of a chapter entry in the player calls its end once: a stop, a jump out")
    func everyEndIsHeard() async throws {
        let chapter = ABSChapter(id: 1, start: 600, end: 1200, title: "Two")
        let model = PlayerViewModel(provider: MockProvider())
        var ends = 0
        model.onChapterEntryEnd = { ends += 1 }
        model.currentTime = 700
        model.watchChapterRange(chapter) {}
        model.stop()
        #expect(ends == 1, "a stop ended the entry \(ends) times")
        model.currentTime = 700
        model.watchChapterRange(chapter) {}
        model.currentTime = 2000
        #expect(ends == 2, "a jump out ended the entry \(ends - 1) times")
    }
}

/// The one who starts a chapter entry learns every end of it.
struct ChapterEntryOwnerFenceTests {
    private static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("the watch of an entry hands the player the end that clears the running entry", .needsTheSources)
    func theWatchOwnsTheEnd() throws {
        let coordinator = try Self.code("Sources/ViewModels/PlayerCoordinator.swift")
        let watch = try #require(ABSPodcastRefreshTests.body(of: "private func watchEntry(", in: coordinator))
        #expect(watch.contains("model.onChapterEntryEnd ="), "the running entry outlives the player's end of it")
        let pages = [("Sources/Views/BookDetailScreen.swift", "shownAsBook: true"),
                     ("Sources/Views/ChapterListView.swift", "shownAsBook: !isMusic")]
        for (path, asked) in pages {
            #expect(try Self.code(path).contains(asked), "\(path) does not say what it shows")
        }
    }
}
#endif
