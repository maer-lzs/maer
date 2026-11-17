// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One chapter of a book as an entry of Up Next: its id, which chapter it
/// names, where it starts, when its range is over, and what the queue, the
/// advance and the sync make of it.
struct ChapterEntryRuleTests {
    static let chapters = [
        ABSChapter(id: 0, start: 0, end: 600, title: "Opening"),
        ABSChapter(id: 1, start: 600, end: 1200.5, title: "The Middle"),
        ABSChapter(id: 2, start: 1200.5, end: 1800, title: "Closing"),
    ]

    @Test("the id carries the start in ms and the book; only that form reads back, every source question goes to the book")
    func theIdReadsBack() {
        let id = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)
        #expect(id == "chapter:600000:li_book-1")
        #expect(ItemNamespace.chapterEntry(id)?.bookId == "li_book-1")
        #expect(ItemNamespace.chapterEntry(id)?.startMs == 600_000)
        let local = ItemNamespace.chapterEntryId(bookId: "local:folder:file", startMs: 0)
        #expect(ItemNamespace.chapterEntry(local)?.bookId == "local:folder:file")
        for other in ["li_book-1", "chapter:", "chapter:x:li_book-1", "chapter:600000:", "chapter:-5:li_book-1",
                      "chapter:0:chapter:0:li_book-1", "rss:feed:ep-1"] {
            #expect(ItemNamespace.chapterEntry(other) == nil, "\(other) read as a chapter entry")
        }
        #expect(ItemNamespace.bookOrSelf(id) == "li_book-1")
        #expect(ItemNamespace.bookOrSelf("li_book-1") == "li_book-1")
    }

    @Test("the entry names the chapter that begins at its start; a chapter inserted before it does not move it")
    func theEntryNamesItsChapterByItsStart() {
        let id = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: ChapterEntryRules.ms(1200.5))
        let startMs = ItemNamespace.chapterEntry(id)?.startMs ?? -1
        #expect(ChapterEntryRules.chapter(startMs: startMs, in: Self.chapters)?.title == "Closing")
        // The server splits the opening: every chapter after it moves one place on.
        let inserted = [ABSChapter(id: 0, start: 0, end: 300, title: "Prologue"),
                        ABSChapter(id: 1, start: 300, end: 600, title: "Opening")] + Self.chapters.dropFirst().map {
            ABSChapter(id: $0.id + 1, start: $0.start, end: $0.end, title: $0.title)
        }
        #expect(ChapterEntryRules.chapter(startMs: startMs, in: inserted)?.title == "Closing")
    }

    @Test("a chapter whose start no longer occurs is unknown, never the chapter that now holds that moment")
    func aVanishedStartIsUnknown() {
        // The server moved the middle chapter's start from 600 to 640 s.
        let moved = [ABSChapter(id: 0, start: 0, end: 640, title: "Opening"),
                     ABSChapter(id: 1, start: 640, end: 1200.5, title: "The Middle")]
        #expect(ChapterEntryRules.chapter(startMs: 600_000, in: Self.chapters)?.title == "The Middle")
        #expect(ChapterEntryRules.chapter(startMs: 600_000, in: moved) == nil, "the entry slid onto another chapter")
        #expect(ChapterEntryRules.chapter(startMs: 0, in: []) == nil)
        let id = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)
        #expect(ChapterEntryRules.resolves(id, bookChapters: Self.chapters))
        #expect(!ChapterEntryRules.resolves(id, bookChapters: moved), "an unknown chapter would play")
        #expect(!ChapterEntryRules.resolves(id, bookChapters: nil), "a chapter of a book whose chapters are unknown would play")
        #expect(ChapterEntryRules.resolves("li_book-1", bookChapters: nil), "a plain book asks no chapter")
    }

    @Test("a chapter starts at the book's position when that lies inside it, else at its beginning")
    func theStartPoint() {
        let middle = Self.chapters[1]
        #expect(ChapterEntryRules.startPoint(of: middle, bookPosition: 900) == 900)
        #expect(ChapterEntryRules.startPoint(of: middle, bookPosition: 100) == 600)
        #expect(ChapterEntryRules.startPoint(of: middle, bookPosition: 1200.5) == 600, "the end belongs to the next chapter")
        #expect(ChapterEntryRules.startPoint(of: middle, bookPosition: 0) == 600)
    }

    @Test("the range runs inside the chapter, ends at its end, and is left when the person moves out")
    func theRange() {
        let middle = Self.chapters[1]
        #expect(ChapterEntryRules.state(at: 600, of: middle) == .running)
        #expect(ChapterEntryRules.state(at: 1200, of: middle) == .running)
        #expect(ChapterEntryRules.state(at: 1200.5, of: middle) == .ended)
        #expect(ChapterEntryRules.state(at: 1202, of: middle) == .ended, "one tick late is still the end")
        #expect(ChapterEntryRules.state(at: 1300, of: middle) == .left)
        #expect(ChapterEntryRules.state(at: 100, of: middle) == .left)
    }

    @Test("the end of the last chapter as an entry does not tell the server the book is finished; the book's own end does")
    func aChapterEndFinishesNoBook() {
        #expect(!ChapterEntryRules.reportsFinished(currentTime: 1800, duration: 1800, inChapterEntry: true))
        #expect(ChapterEntryRules.reportsFinished(currentTime: 1800, duration: 1800, inChapterEntry: false))
        #expect(!ChapterEntryRules.reportsFinished(currentTime: 1200.5, duration: 1800, inChapterEntry: false))
    }

    @Test("the plan of the sync after a chapter entry before the server's stand writes nothing and raises the conflict")
    func thePlanMeetsTheGuard() {
        let state = SyncState(startSourceResolved: true, currentTime: 0, lastSyncedTime: 500,
                              suspiciousDropThreshold: 60, suppressConflict: false, conflictPending: false,
                              progressSync: true, podcastEpisode: false, potCarries: false)
        #expect(SyncRules.plan(origin: .seek, state: state).gate == .conflict(raise: true))
        var shown = state
        shown.conflictPending = true
        #expect(SyncRules.plan(origin: .seek, state: shown).gate == .conflict(raise: false))
    }

    @Test("after a chapter entry no next book of the series follows; after a book it may")
    func noSeriesAfterAChapter() {
        let entry = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0)
        #expect(!ChapterEntryRules.seriesMayFollow(entry, enabled: true))
        #expect(ChapterEntryRules.seriesMayFollow("li_book-1", enabled: true))
        #expect(!ChapterEntryRules.seriesMayFollow("li_book-1", enabled: false))
    }

    @Test("only a book offers its chapters for Up Next; an episode with chapters does not, from either podcast source")
    func onlyBooksOfferChapters() {
        #expect(ChapterEntryRules.offersChapters(itemId: "li_book-1", chapters: Self.chapters))
        #expect(ChapterEntryRules.offersChapters(itemId: "local:folder:book.m4b", chapters: Self.chapters))
        #expect(!ChapterEntryRules.offersChapters(itemId: "rss:feed:ep-1", chapters: Self.chapters), "an RSS episode offered its chapters")
        #expect(!ChapterEntryRules.offersChapters(itemId: "abspod:sv:ep-1", chapters: Self.chapters),
                "an episode of an Audiobookshelf podcast offered its chapters")
        #expect(!ChapterEntryRules.offersChapters(itemId: "li_book-1", chapters: []), "a book without chapters offered them")
        #expect(!ChapterEntryRules.offersChapters(itemId: "radio:rb:x", chapters: Self.chapters))
    }

    @Test("the row of an entry shows the chapter under the book's title; an unknown chapter says so and never shows the book alone")
    func theRow() {
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(title: "The Book", authorName: "An Author", narratorName: nil, seriesName: nil,
                                          genres: nil, publishedYear: nil, description: nil),
            duration: 1800, chapters: Self.chapters, tracks: nil)
        let book = LibraryItem(id: "li_book-1", media: media, addedAt: 5)
        let id = ItemNamespace.chapterEntryId(bookId: book.id, startMs: 600_000)
        let row = ChapterEntryRules.carrier(entryId: id, book: book)
        #expect(row.id == id)
        #expect(row.title == "The Middle")
        #expect(row.media?.metadata?.authorName == "The Book")
        #expect(row.media?.duration == 600.5)
        let gone = ChapterEntryRules.carrier(entryId: ItemNamespace.chapterEntryId(bookId: book.id, startMs: 650_000), book: book)
        #expect(gone.id != book.id, "the row of an unknown chapter stood for the book")
        #expect(gone.title == ChapterEntryRules.unknownChapterTitle)
        #expect(gone.media?.metadata?.authorName == "The Book")
        #expect(!ChapterEntryRules.unknownChapterTitle.isEmpty)
    }

    @Test("two chapters and an episode take turns: after the first chapter the episode, after it the second chapter, then nothing")
    func chaptersAndAnEpisodeTakeTurns() {
        let first = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0)
        let second = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)
        let episode = "rss:feed:ep-1"
        var queue = [episode, second]
        func next(after finished: String) -> String? {
            PlaybackAdvance.resolveNext(after: finished, queueIds: queue, contextIds: [],
                                        isPlayable: { _ in true },
                                        resolves: { ChapterEntryRules.resolves($0, bookChapters: Self.chapters) },
                                        isPodcast: ItemNamespace.isPodcastEpisode, bingeNext: { _ in nil },
                                        seriesEnabled: ChapterEntryRules.seriesMayFollow(finished, enabled: true),
                                        seriesNext: { _ in "li_book-2" })?.id
        }
        #expect(next(after: first) == episode)
        queue.removeFirst()
        #expect(next(after: episode) == second)
        queue.removeFirst()
        #expect(next(after: second) == nil, "a chapter's end started the next book of the series")
    }

    @Test("the advance passes over an entry whose chapter is unknown and starts what follows; it never plays the book in its place")
    func theAdvancePassesAnUnknownChapter() {
        let gone = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 650_000)
        let episode = "rss:feed:ep-1"
        let hit = PlaybackAdvance.resolveNext(after: "rss:feed:ep-0", queueIds: [gone, episode], contextIds: [],
                                              isPlayable: { _ in true },
                                              resolves: { ChapterEntryRules.resolves($0, bookChapters: Self.chapters) },
                                              isPodcast: ItemNamespace.isPodcastEpisode, bingeNext: { _ in nil },
                                              seriesEnabled: false, seriesNext: { _ in nil })
        #expect(hit?.id == episode)
    }
}

@MainActor
struct ChapterEntryQueueTests {
    @Test("a chapter entry enters the queue as its book can; a book heard to its end takes its chapters along, a start does not")
    func theQueueKnowsChapters() {
        let queue = PlayQueue(isPlayable: { $0 == "li_book-1" || $0 == "li_book-2" })
        let first = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0)
        let second = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)
        let other = ItemNamespace.chapterEntryId(bookId: "li_book-2", startMs: 0)
        let unplayable = ItemNamespace.chapterEntryId(bookId: "rss:text-only", startMs: 0)
        for id in [first, second, other, unplayable] { queue.playLast(id) }
        #expect(queue.ids == [first, second, other], "a chapter of a title that cannot play entered the queue")
        // Starting the book (or one of its chapters) leaves its other chapters.
        queue.remove("li_book-1")
        queue.remove(first)
        #expect(queue.ids == [second, other])
        // The book heard to its end elsewhere: none of its chapters waits.
        queue.markedPlayed("li_book-1")
        #expect(queue.ids == [other])
        queue.markedPlayed(["li_book-2"])
        #expect(queue.ids.isEmpty)
    }

    @Test("an entry whose book cannot be resolved stays in the queue, and its id never reaches the library server")
    func anUnresolvedEntryStays() {
        var playable = true
        let queue = PlayQueue(isPlayable: { _ in playable })
        let entry = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)
        queue.playLast(entry)
        playable = false
        queue.playLast("rss:feed:ep-1")
        #expect(queue.ids == [entry], "the entry of a book that cannot be resolved now left the queue")
        #expect(PlayQueue.canHold(entry))
        #expect(!ItemNamespace.mayReachLibraryServer(entry), "the entry's id would go to the server as a book id")
    }

    @Test("the range ends once at the chapter's end, and moving out of the chapter ends it without the end")
    func theWatchEndsOnce() async throws {
        let chapter = ABSChapter(id: 1, start: 600, end: 1200, title: "The Middle")
        let model = PlayerViewModel(provider: MockProvider())
        model.currentTime = 1100
        var ended = 0
        model.watchChapterRange(chapter) { ended += 1 }
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(ended == 0, "the range ended inside the chapter")
        model.currentTime = 1200
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(ended == 1)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(ended == 1, "the range ended twice")
        // The person jumps out of the chapter: the book plays on as a book.
        model.currentTime = 700
        model.watchChapterRange(chapter) { ended += 1 }
        #expect(model.playsChapterEntry)
        model.currentTime = 2000
        try await Task.sleep(nanoseconds: 2_300_000_000)
        #expect(ended == 1, "a jump out of the chapter ended the entry")
        model.stop()
    }

    @Test("a chapter entry before the server's stand moves the book there only through the backward guard, never silently")
    func aChapterBeforeTheStandMeetsTheGuard() async throws {
        let id = "chapterguard-\(UUID().uuidString)"
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 600, contentUrl: "t.mp3", metadata: nil)
        let chapters = [ABSChapter(id: 0, start: 0, end: 300, title: "One"),
                        ABSChapter(id: 1, start: 300, end: 600, title: "Two")]
        let detail = LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(metadata: nil, duration: 600, chapters: chapters, tracks: [track]),
            userMediaProgress: MediaProgress(currentTime: 500, duration: 600, progress: nil, isFinished: false, lastUpdate: nil))
        let player = PlayerViewModel(provider: FailedLoadTests.DeadAddressProvider())
        await player.load(item: detail)
        #expect(player.lastSyncedTime == 500, "the precondition: the server's stand is known")
        await player.startChapterEntry(chapters[0])
        #expect(player.currentTime == 0, "the entry did not start at its chapter")
        #expect(player.pendingServerConflict != nil, "the server's stand went back without the guard")
        #expect(player.lastSyncedTime == 500, "the stand behind the chapter was overwritten")
        player.stop()
    }
}

/// Where the chapter form may be spelled and who resolves it.
struct ChapterEntryFenceTests {
    private static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("the chapter form is spelled only in the namespace, and only a book's page builds an entry", .needsTheSources)
    func theFormLivesInTheNamespace() throws {
        var spelling: [String] = []
        var building: [String] = []
        for url in SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources")) where url.pathExtension == "swift" {
            let path = SourceTree.relativePath(of: url)
            let text = try Self.code(path)
            if text.contains("\"chapter:"), path != "Sources/Models/ItemNamespace.swift" { spelling.append(path) }
            if text.contains("chapterEntryId("),
               !["Sources/Models/ItemNamespace.swift", "Sources/Models/ChapterEntryRules.swift"].contains(path) {
                building.append(path)
            }
        }
        #expect(spelling.isEmpty, "the chapter form is spelled outside the namespace: \(spelling)")
        #expect(building == ["Sources/Views/BookDetailScreen.swift"], "entries are built here: \(building)")
        let page = try Self.code("Sources/Views/BookDetailScreen.swift")
        #expect(page.contains("ChapterEntryRules.offersChapters("), "the book's page offers chapters without the rule")
    }

    @Test("the inputs of every advance resolve a chapter entry to its book and ask its chapter", .needsTheSources)
    func theAdvanceResolvesChapters() throws {
        let coordinator = try Self.code("Sources/ViewModels/PlayerCoordinator.swift")
        let inputs = try #require(ABSPodcastRefreshTests.body(of: "private func advanceInputs()", in: coordinator))
        #expect(inputs.contains("ChapterEntryRules.resolves("), "the advance starts an entry without asking its chapter")
        #expect(inputs.contains("ItemNamespace.bookOrSelf("), "the advance asks the source for the entry's id instead of its book")
    }
}
#endif
