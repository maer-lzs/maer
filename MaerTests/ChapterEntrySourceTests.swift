// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// How long the answer "this stand is a chapter entry's" lives: only while
/// the position stands at the entry's end, never over a finish marked by hand.
struct ChapterEntryStandTests {
    @Test("the stand belongs to the entry while it plays and while the position stands at its end; a finish by hand and a move off the end end it")
    func theStandLivesAtTheEnd() {
        #expect(ChapterEntryRules.entryHoldsStand(playsEntry: true, endedAsEntry: false, currentTime: 700,
                                                  duration: 1200, isFinished: false))
        #expect(ChapterEntryRules.entryHoldsStand(playsEntry: false, endedAsEntry: true, currentTime: 1200,
                                                  duration: 1200, isFinished: false))
        #expect(!ChapterEntryRules.entryHoldsStand(playsEntry: false, endedAsEntry: true, currentTime: 1200,
                                                   duration: 1200, isFinished: true),
                "a finish marked by hand was taken back")
        #expect(!ChapterEntryRules.entryHoldsStand(playsEntry: true, endedAsEntry: true, currentTime: 1200,
                                                   duration: 1200, isFinished: true),
                "a finish marked by hand in a playing entry was taken back")
        #expect(!ChapterEntryRules.entryHoldsStand(playsEntry: false, endedAsEntry: true, currentTime: 1199.5,
                                                   duration: 1200, isFinished: false),
                "a jump off the end still counted as the entry's end")
        #expect(!ChapterEntryRules.entryHoldsStand(playsEntry: false, endedAsEntry: false, currentTime: 1200,
                                                   duration: 1200, isFinished: false))
    }
}

@MainActor
struct ChapterEntryStandModelTests {
    /// A book of two chapters whose last chapter played as an entry to the
    /// book's end.
    private func endedAsEntry(_ name: String) async throws
        -> (model: PlayerViewModel, server: ChapterEntryQueueTests.ChapteredServer, id: String, file: URL) {
        let file = try TickWorkTests().tone(seconds: 20)
        let id = "\(name)-\(UUID().uuidString)"
        let server = ChapterEntryQueueTests.ChapteredServer(file: file.path, duration: 20, position: 12)
        let model = PlayerViewModel(provider: server, localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: try await server.fetchItemDetail(itemId: id))
        await model.reconcileWithServer()
        try #require(model.chapters.count == 2, "the precondition: the book has its two chapters")
        let last = model.chapters[1]
        await model.startChapterEntry(last)
        model.watchChapterRange(last) {}
        await model.finishBook()
        try #require(server.lastFinished == false, "the precondition: the end as an entry finished nothing")
        return (model, server, id, file)
    }

    @Test("after the end as an entry a finish marked by hand stays finished, also through the stop with a pause record waiting", .needsAudio)
    func aFinishByHandStays() async throws {
        let (model, server, id, file) = try await endedAsEntry("chaptermark")
        defer { try? FileManager.default.removeItem(at: file) }
        // The mark writes its own finished stand, then the player finishes
        // and stops the title.
        try await server.updateProgress(itemId: id, currentTime: 20, duration: 20, isFinished: true)
        model.finalizeAsFinished()
        model.pauseRecordPending = true
        let before = server.writes
        model.stop()
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 100_000_000) }
        try #require(server.writes > before, "the precondition: the stop wrote the waiting stand")
        #expect(server.lastFinished == true, "a later write of the same stand took the finish by hand back")
    }

    @Test("after the end as an entry a jump into the book's last second tells the server the book is finished", .needsAudio)
    func aJumpToTheEndFinishes() async throws {
        let (model, server, _, file) = try await endedAsEntry("chapterjump")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = server.writes
        await model.seek(to: 19.5)
        try #require(server.writes > before, "the precondition: the jump wrote its stand")
        #expect(server.lastFinished == true, "the end of an entry earlier still held the stand after a jump")
        model.stop()
    }
}

/// A chain's row, its resolution and its start name the same chapter, from
/// the same list of chapters.
struct ChapterEntryChainChapterTests {
    static let chapters = ChapterEntryChainRuleTests.chapters

    static func book(chapters: [ABSChapter]?) -> LibraryItem {
        LibraryItem(id: "li_book-1",
                    media: LibraryItemMedia(metadata: LibraryItemMetadata(title: "The Book", authorName: nil, narratorName: nil,
                                                                          seriesName: nil, genres: nil, publishedYear: nil,
                                                                          description: nil),
                                            duration: 3000, chapters: chapters, tracks: nil),
                    addedAt: 1)
    }

    @Test("the row of a chain names the chapter the book's position holds now, the one it plays")
    func theRowNamesWhatPlays() {
        let chain = ChapterEntryChainRuleTests.chain(0)
        let row = ChapterEntryRules.carrier(entryId: chain, book: Self.book(chapters: nil), chapters: Self.chapters,
                                            bookPosition: 1300)
        #expect(row.title == "Three", "the row named \(row.title), the chapter the chain was queued at")
        let single = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0)
        #expect(ChapterEntryRules.carrier(entryId: single, book: Self.book(chapters: nil), chapters: Self.chapters,
                                          bookPosition: 1300).title == "One", "a single entry left its own chapter")
    }

    @Test("a chain whose first chapter is gone resolves while a chapter holds the book's position")
    func aChainResolvesByThePosition() {
        let chain = ChapterEntryChainRuleTests.chain(0)
        let withoutFirst = Array(Self.chapters.dropFirst())
        #expect(ChapterEntryRules.resolves(chain, bookChapters: withoutFirst, bookPosition: 1300),
                "the chain was dropped although it plays chapter three")
        let single = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0)
        #expect(!ChapterEntryRules.resolves(single, bookChapters: withoutFirst, bookPosition: 1300))
    }

    @Test("the chapters come from the player that holds the book, else from its detail, else from its list item; an empty list is none")
    func theFirstSourceThatKnows() {
        let player = [ABSChapter(id: 9, start: 0, end: 10, title: "Player")]
        let learned = [ABSChapter(id: 8, start: 0, end: 10, title: "Detail")]
        let listed = [ABSChapter(id: 7, start: 0, end: 10, title: "List")]
        #expect(ChapterEntryRules.knownChapters(playing: player, learned: learned, listed: listed) == player)
        #expect(ChapterEntryRules.knownChapters(playing: nil, learned: learned, listed: listed) == learned)
        #expect(ChapterEntryRules.knownChapters(playing: [], learned: nil, listed: listed) == listed)
        #expect(ChapterEntryRules.knownChapters(playing: nil, learned: nil, listed: []) == nil)
        #expect(ChapterEntryRules.knownChapters(playing: nil, learned: nil, listed: nil) == nil)
    }
}

/// The source of a book's chapters, driven with a list item as a server
/// sends it: without chapters.
@MainActor
struct BookChapterSourceTests {
    private final class Counter { var fetches = 0; var changes = 0 }

    private func source(counter: Counter, position: Double,
                        playing: (bookId: String, chapters: [ABSChapter], position: Double)? = nil) -> BookChapterSource {
        BookChapterSource(
            playing: { playing },
            listed: { $0 == "li_book-1" ? ChapterEntryChainChapterTests.book(chapters: nil) : nil },
            listedPosition: { _ in position },
            fetch: { id in
                counter.fetches += 1
                return LibraryItemDetail(id: id,
                                         media: LibraryItemMedia(metadata: nil, duration: 3000,
                                                                 chapters: ChapterEntryChainChapterTests.chapters,
                                                                 tracks: [ABSAudioTrack(index: 0, startOffset: 0, duration: 3000,
                                                                                        contentUrl: "/a", metadata: nil)]),
                                         userMediaProgress: nil)
            },
            changed: { counter.changes += 1 })
    }

    @Test("a row of a book whose list item carries no chapters asks the detail once and then names its chapter")
    func aListItemWithoutChapters() async {
        let counter = Counter()
        let source = source(counter: counter, position: 700)
        let single = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)
        #expect(source.entryItem(single)?.title == ChapterEntryRules.unknownChapterTitle,
                "the precondition: nothing knows the chapters yet")
        await source.learn("li_book-1")
        #expect(source.entryItem(single)?.title == "Two", "the row stayed unknown after the detail was read")
        #expect(source.entryItem(ChapterEntryChainRuleTests.chain(0))?.title == "Two",
                "the chain's row did not name the chapter of the book's stand")
        await source.learn("li_book-1")
        #expect(counter.fetches == 1, "the detail was asked \(counter.fetches) times")
        #expect(counter.changes == 1, "the surfaces heard the change \(counter.changes) times")
    }

    @Test("while the player holds the book the row reads its chapters and its position, and asks no detail")
    func thePlayerHoldsTheBook() async {
        let counter = Counter()
        let source = source(counter: counter, position: 0,
                            playing: ("li_book-1", ChapterEntryChainChapterTests.chapters, 1900))
        #expect(source.entryItem(ChapterEntryChainRuleTests.chain(0))?.title == "Four")
        await source.learn("li_book-1")
        #expect(counter.fetches == 0, "a detail was asked while the player knows the chapters")
    }
}

/// The end of a chain is the book's end.
@MainActor
struct ChapterEntryChainFinishTests {
    @Test("the end of a chain's last chapter tells the server the book is finished, marks it here and advances once", .needsAudio)
    func theChainsEndFinishesTheBook() async throws {
        let file = try TickWorkTests().tone(seconds: 20)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "chainend-\(UUID().uuidString)"
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
        model.watchChapterRange(last, finishesBook: true) {
            advanced += 1
            model.endChapterEntry()
        }
        await model.finishBook()
        #expect(server.lastFinished == true, "the server did not hear the book is finished")
        #expect(model.isFinished, "the book does not count as finished here")
        #expect(advanced == 1, "the range ended \(advanced) times")
        #expect(finished.isEmpty, "the book's end advanced a second time: \(finished)")
        model.stop()
    }

    @Test("the end of a chain takes the book's other chapters out of Up Next, as a heard book does; the end of a single chapter does not")
    func theChainsEndTakesTheBookOut() {
        let chapters = ChapterEntryChainRuleTests.chapters
        let single = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)
        let queue = PlayQueue(isPlayable: { _ in true })
        queue.playLast(ChapterEntryChainRuleTests.chain(2_400_000))
        queue.playLast(single)
        queue.playLast("rss:feed:a")
        queue.chapterEnded(ChapterEntryChainRuleTests.chain(2_400_000), chapters: chapters, played: chapters[4])
        #expect(queue.ids == ["rss:feed:a"], "the book's chapters stayed after its end: \(queue.ids)")
        let lastSingle = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 2_400_000)
        queue.playLast(lastSingle)
        queue.playLast(single)
        queue.chapterEnded(lastSingle, chapters: chapters, played: chapters[4])
        #expect(queue.ids == ["rss:feed:a", single], "a single chapter's end took the book out")
    }
}

/// The chain reads a book's chapters the way the open reads its detail.
struct ChapterDetailWayTests {
    private struct Offline: Error {}
    static let saved = LibraryItemDetail(id: "li_book-1", media: LibraryItemMedia(metadata: nil, duration: 3000,
                                                                                  chapters: ChapterEntryChainRuleTests.chapters,
                                                                                  tracks: nil),
                                         userMediaProgress: nil)

    @Test("a downloaded book gives its saved detail without asking the source, also offline; the source's miss falls back to it")
    func theDownloadComesFirst() async throws {
        var asked = 0
        let offline = try await BookChapterSource.detail(isDownloaded: true, cached: { Self.saved },
                                                         fetch: { asked += 1; throw Offline() })
        #expect(offline.id == "li_book-1")
        #expect(asked == 0, "the source was asked for a downloaded book")
        let fallback = try await BookChapterSource.detail(isDownloaded: false, cached: { Self.saved },
                                                          fetch: { throw Offline() })
        #expect(fallback.id == "li_book-1", "the saved detail did not stand in for the source")
        await #expect(throws: Offline.self) {
            try await BookChapterSource.detail(isDownloaded: false, cached: { nil }, fetch: { throw Offline() })
        }
    }

    @Test("the chain and the rows of its entries read the detail on the open's way", .needsTheSources)
    func oneWay() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let chain = try #require(ABSPodcastRefreshTests.body(of: "func addChapter(",
                                                             in: try code("Sources/ViewModels/PlayerCoordinator.swift")))
        #expect(chain.contains("session.chapterDetail("), "adding a chapter asks the source past a download")
        #expect(!chain.contains("fetchItemDetail("), "adding a chapter fetches its detail on its own way")
        #expect(try code("Sources/AppSession.swift").contains("try await chapterDetail($0)"),
                "the rows of chapter entries fetch past a download")
    }
}

/// A chain whose book stands at its end without being finished.
struct ChapterEntryChainAtTheEndTests {
    @Test("a waiting chain whose book stands at its end plays no chapter, does not resolve, and the advance goes on past it")
    func theAdvanceDoesNotHang() {
        let chapters = ChapterEntryChainRuleTests.chapters
        let chain = ChapterEntryChainRuleTests.chain(0)
        #expect(ChapterEntryRules.playChapter(entryId: chain, chapters: chapters, bookPosition: 3000) == nil)
        #expect(!ChapterEntryRules.resolves(chain, bookChapters: chapters, bookPosition: 3000),
                "a chain with no chapter left resolved")
        let hit = PlaybackAdvance.resolveNext(after: "rss:feed:ep-0", queueIds: [chain, "rss:feed:a"], contextIds: [],
                                              isPlayable: { _ in true },
                                              resolves: { ChapterEntryRules.resolves($0, bookChapters: chapters,
                                                                                     bookPosition: 3000) },
                                              isPodcast: ItemNamespace.isPodcastEpisode, bingeNext: { _ in nil },
                                              seriesEnabled: false, seriesNext: { _ in nil })
        #expect(hit?.id == "rss:feed:a", "the advance stopped at the chain: \(hit?.id ?? "nil")")
    }
}

/// A chain that does not go in says why.
@MainActor
struct ChapterEntryChainRefusalTests {
    @Test("a second chain of the book and a stand after the last chapter are told apart, and each has its sentence")
    func eachRefusalSaysItsSentence() {
        let queue = PlayQueue(isPlayable: { _ in true })
        let chapters = ChapterEntryChainRuleTests.chapters
        #expect(queue.enqueueChain(bookId: "li_book-1", chapters: chapters, bookPosition: 0) == .queued)
        #expect(queue.enqueueChain(bookId: "li_book-1", chapters: chapters, bookPosition: 0) == .waitsAlready)
        #expect(queue.enqueueChain(bookId: "li_book-2", chapters: chapters, bookPosition: 3000) == .noChapterLeft)
        #expect(ChapterEntryRules.chainRefusal(.queued) == nil)
        let sentences = [ChapterEntryRules.ChainOutcome.waitsAlready, .noChapterLeft].compactMap(ChapterEntryRules.chainRefusal)
        #expect(sentences.count == 2, "a refusal says nothing")
        #expect(Set(sentences).count == 2, "two refusals say the same sentence")
    }

    @Test("a chapter that cannot be added says why through the notice the other refusals use", .needsTheSources)
    func theRefusalIsSaid() throws {
        let coordinator = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"),
                       encoding: .utf8))
        let body = try #require(ABSPodcastRefreshTests.body(of: "func addChapter(", in: coordinator))
        // The detail failed, fewer than two chapters, none left to add.
        #expect(body.components(separatedBy: "sayOpenFailure(").count - 1 == 3,
                "a refusal to add a chapter is not said like the others")
    }
}
#endif
