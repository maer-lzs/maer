// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A book heard chapter by chapter in Up Next: each chapter entry, at its
/// end, puts the next chapter at the end of the queue.
struct ChapterEntryChainRuleTests {
    static let chapters = [
        ABSChapter(id: 0, start: 0, end: 600, title: "One"),
        ABSChapter(id: 1, start: 600, end: 1200, title: "Two"),
        ABSChapter(id: 2, start: 1200, end: 1800, title: "Three"),
        ABSChapter(id: 3, start: 1800, end: 2400, title: "Four"),
        ABSChapter(id: 4, start: 2400, end: 3000, title: "Five"),
    ]
    static func chain(_ startMs: Int, _ book: String = "li_book-1") -> String {
        ItemNamespace.chapterEntryId(bookId: book, startMs: startMs, continues: true)
    }

    @Test("an entry heard chapter by chapter has its own form and reads back as a chapter entry that continues")
    func theChainFormReadsBack() {
        let id = Self.chain(600_000)
        #expect(id == "chapters:600000:li_book-1")
        #expect(ItemNamespace.chapterEntry(id)?.bookId == "li_book-1")
        #expect(ItemNamespace.chapterEntry(id)?.startMs == 600_000)
        #expect(ItemNamespace.chapterEntry(id)?.continues == true)
        #expect(ItemNamespace.chapterEntry(ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000))?.continues == false)
        #expect(ItemNamespace.bookOrSelf(id) == "li_book-1")
        for other in ["chapters:", "chapters:x:li_book-1", "chapters:600000:", "chapters:0:chapters:0:li_book-1"] {
            #expect(ItemNamespace.chapterEntry(other) == nil, "\(other) read as a chapter entry")
        }
    }

    @Test("the follower of a chapter is the next chapter in the same form, none after the last, none for a single chapter")
    func theFollower() {
        #expect(ChapterEntryRules.follower(of: Self.chain(0), chapters: Self.chapters) == Self.chain(600_000))
        #expect(ChapterEntryRules.follower(of: Self.chain(1_800_000), chapters: Self.chapters) == Self.chain(2_400_000))
        #expect(ChapterEntryRules.follower(of: Self.chain(2_400_000), chapters: Self.chapters) == nil, "a follower after the last chapter")
        #expect(ChapterEntryRules.follower(of: ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0),
                                           chapters: Self.chapters) == nil, "a single chapter got a follower")
        #expect(ChapterEntryRules.follower(of: "li_book-1", chapters: Self.chapters) == nil)
        // The server moved the second chapter's start: the follower is the
        // chapter that begins after the ending one's start.
        let moved = [Self.chapters[0], ABSChapter(id: 1, start: 640, end: 1200, title: "Two")] + Self.chapters.dropFirst(2)
        #expect(ChapterEntryRules.follower(of: Self.chain(0), chapters: moved) == Self.chain(640_000))
    }

    @Test("a chain starts at the chapter that holds the book's position, else at the next one")
    func theChainStart() {
        #expect(ChapterEntryRules.chainStart(chapters: Self.chapters, bookPosition: 0)?.title == "One")
        #expect(ChapterEntryRules.chainStart(chapters: Self.chapters, bookPosition: 700)?.title == "Two")
        let gap = [ABSChapter(id: 0, start: 0, end: 500, title: "One"), ABSChapter(id: 1, start: 600, end: 1200, title: "Two")]
        #expect(ChapterEntryRules.chainStart(chapters: gap, bookPosition: 550)?.title == "Two")
        #expect(ChapterEntryRules.chainStart(chapters: Self.chapters, bookPosition: 3000) == nil, "a chain after the book's end")
        #expect(ChapterEntryRules.chainStart(chapters: [], bookPosition: 0) == nil)
    }

    @Test("a chain plays the chapter the book's position holds now; a single entry plays its own chapter")
    func aChainFollowsTheBook() {
        // The chain waits at the third chapter; meanwhile the book was heard
        // as a book into the fifth.
        let played = ChapterEntryRules.playChapter(entryId: Self.chain(1_200_000), chapters: Self.chapters, bookPosition: 2500)
        #expect(played?.title == "Five", "the chain played \(played?.title ?? "nothing") again")
        let single = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 1_200_000)
        #expect(ChapterEntryRules.playChapter(entryId: single, chapters: Self.chapters, bookPosition: 2500)?.title == "Three")
        #expect(ChapterEntryRules.playChapter(entryId: Self.chain(1_200_000), chapters: Self.chapters, bookPosition: 1300)?.title == "Three")
    }

    @Test("a book's card offers the chain for a book not heard to its end, never for music, an episode or a station")
    func theCardOffersTheChain() {
        #expect(ChapterEntryRules.offersChain(itemId: "li_book-1", finished: false))
        #expect(ChapterEntryRules.offersChain(itemId: "local:folder:book.m4b", finished: false))
        #expect(!ChapterEntryRules.offersChain(itemId: "li_book-1", finished: true), "a book heard to its end offered the chain")
        for id in ["rss:feed:ep-1", "abspod:sv:ep-1", "sub:album:a1", "jam:123", "radio:rb:x", Self.chain(0)] {
            #expect(!ChapterEntryRules.offersChain(itemId: id, finished: false), "\(id) offered the chain")
        }
    }

    @Test("the end of the last chapter of a chain does not tell the server the book is finished, until the question is decided")
    func theLastChapterOfAChainFinishesNothingYet() {
        #expect(!ChapterEntryRules.reportsFinished(currentTime: 3000, duration: 3000, inChapterEntry: true))
    }
}

@MainActor
struct ChapterEntryChainQueueTests {
    @Test("a book and two episodes take turns: chapter one, episode A, episode B, chapter two")
    func theBookAndTheEpisodesTakeTurns() {
        let queue = PlayQueue(isPlayable: { _ in true })
        #expect(queue.enqueueChain(bookId: "li_book-1", chapters: ChapterEntryChainRuleTests.chapters, bookPosition: 0))
        queue.playLast("rss:feed:a")
        queue.playLast("rss:feed:b")
        let first = ChapterEntryChainRuleTests.chain(0)
        #expect(queue.ids == [first, "rss:feed:a", "rss:feed:b"])
        queue.chapterEnded(first, chapters: ChapterEntryChainRuleTests.chapters)
        #expect(queue.ids == ["rss:feed:a", "rss:feed:b", ChapterEntryChainRuleTests.chain(600_000)],
                "the next chapter did not join the end: \(queue.ids)")
    }

    @Test("the chain goes in once per book, at the end, at the chapter of the position, and not with fewer than two chapters")
    func theChainGoesInOnce() {
        let queue = PlayQueue(isPlayable: { _ in true })
        queue.playLast("rss:feed:a")
        #expect(queue.enqueueChain(bookId: "li_book-1", chapters: ChapterEntryChainRuleTests.chapters, bookPosition: 700))
        #expect(queue.ids == ["rss:feed:a", ChapterEntryChainRuleTests.chain(600_000)])
        #expect(!queue.enqueueChain(bookId: "li_book-1", chapters: ChapterEntryChainRuleTests.chapters, bookPosition: 0),
                "a second chain of the same book went in")
        #expect(!queue.enqueueChain(bookId: "li_book-2", chapters: [ChapterEntryChainRuleTests.chapters[0]], bookPosition: 0))
        #expect(queue.ids.count == 2)
    }

    @Test("a single chapter and the last chapter of a chain leave at their end and put nothing behind")
    func noFollowerWhereNoneBelongs() {
        let queue = PlayQueue(isPlayable: { _ in true })
        let single = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0)
        let last = ChapterEntryChainRuleTests.chain(2_400_000)
        queue.playLast(single)
        queue.playLast(last)
        queue.chapterEnded(single, chapters: ChapterEntryChainRuleTests.chapters)
        queue.chapterEnded(last, chapters: ChapterEntryChainRuleTests.chapters)
        #expect(queue.ids.isEmpty, "something followed: \(queue.ids)")
    }
}

/// Where a follower is made and who asks for it.
struct ChapterEntryChainFenceTests {
    private static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("only the end of a range puts a follower in; a jump out of the chapter does not, and the open plays the chapter the rule names", .needsTheSources)
    func theFollowerComesOnlyAtTheEnd() throws {
        let coordinator = try Self.code("Sources/ViewModels/PlayerCoordinator.swift")
        let ended = try #require(ABSPodcastRefreshTests.body(of: "private func chapterRangeEnded(", in: coordinator))
        #expect(ended.contains("orders.chapterEnded("), "the end of a chapter does not ask for its follower")
        let watch = try #require(ABSPodcastRefreshTests.body(of: "private func watchEntry(", in: coordinator))
        let leave = try #require(watch.range(of: "onLeave:")).upperBound
        let end = try #require(watch.range(of: "onEnd:")).lowerBound
        #expect(!watch[leave..<end].contains("chapterEnded("), "a jump out of the chapter put a follower in")
        let open = try #require(ABSPodcastRefreshTests.body(of: "private func openChapter(", in: coordinator))
        #expect(open.contains("ChapterEntryRules.playChapter("), "the open plays the stored chapter, not the one the rule names")
        var asking: [String] = []
        for url in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources")) where url.pathExtension == "swift" {
            let path = SourceTree.relativePath(of: url)
            if try Self.code(path).contains("ChapterEntryRules.follower("), path != "Sources/Models/ChapterEntryRules.swift" {
                asking.append(path)
            }
        }
        #expect(asking == ["Sources/Providers/PlayQueue.swift"], "a follower is made here: \(asking)")
    }

    @Test("the book's card offers the chain under the decided words, in English and German", .needsTheSources)
    func theMenuSaysTheDecidedWords() throws {
        let card = try Self.code("Sources/Views/BookGridComponents.swift")
        #expect(card.contains("ChapterEntryRules.offersChain("), "the card offers the chain without the rule")
        #expect(card.contains("\"Chapter by Chapter in Up Next\""), "the card does not say the decided words")
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let parsed = try JSONSerialization.jsonObject(with: Data(catalog.utf8))
        let json = try #require(parsed as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let entry = try #require(strings["Chapter by Chapter in Up Next"] as? [String: Any], "the words are not in the catalogue")
        let german = ((entry["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String == "Kapitelweise in Als Nächstes")
    }
}
#endif
