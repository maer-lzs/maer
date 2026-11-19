// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A chapter entry stays in Up Next while it plays, so a restart finds it;
/// no list a person sees and no advance offers it as the next title.
struct ChapterEntryRunningRuleTests {
    static let chapters = [
        ABSChapter(id: 0, start: 0, end: 600, title: "Opening"),
        ABSChapter(id: 1, start: 600, end: 1200, title: "The Middle"),
    ]
    static let middle = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 600_000)

    @Test("the lists a person sees and the advance leave out the chapter entry that plays now, and only it")
    func theRunningEntryIsNotNext() {
        let episode = "rss:feed:ep-1"
        #expect(ChapterEntryRules.shown([Self.middle, episode], running: Self.middle) == [episode])
        #expect(ChapterEntryRules.shown([episode, Self.middle], running: Self.middle) == [episode])
        #expect(ChapterEntryRules.shown([Self.middle, episode], running: nil) == [Self.middle, episode])
        let other = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 0)
        #expect(ChapterEntryRules.shown([other, Self.middle], running: Self.middle) == [other],
                "another chapter of the same book went with the running one")
    }

    @Test("the skip to the next title starts what follows the running entry, never the running entry again")
    func theSkipNeverTakesTheRunningEntry() {
        let episode = "rss:feed:ep-1"
        let shown = ChapterEntryRules.shown([Self.middle, episode], running: Self.middle)
        let hit = PlaybackAdvance.next(queueIds: shown, contextIds: [], isPlayable: { _ in true }, resolves: { _ in true })
        #expect(hit?.id == episode)
    }

    @Test("a restored book plays as the chapter entry at the head of Up Next when that chapter holds its position, otherwise as a book")
    func aRestoreFindsTheEntry() {
        let found = ChapterEntryRules.restoredEntry(queueIds: [Self.middle, "rss:feed:ep-1"], bookId: "li_book-1",
                                                    position: 900, chapters: Self.chapters)
        #expect(found?.entryId == Self.middle)
        #expect(found?.chapter.title == "The Middle")
        #expect(ChapterEntryRules.restoredEntry(queueIds: [Self.middle], bookId: "li_book-1", position: 100,
                                                chapters: Self.chapters) == nil, "a position outside the chapter restored the entry")
        #expect(ChapterEntryRules.restoredEntry(queueIds: [Self.middle], bookId: "li_book-2", position: 900,
                                                chapters: Self.chapters) == nil, "another book took the entry")
        #expect(ChapterEntryRules.restoredEntry(queueIds: ["rss:feed:ep-1", Self.middle], bookId: "li_book-1", position: 900,
                                                chapters: Self.chapters) == nil, "an entry behind another title was taken as playing")
        #expect(ChapterEntryRules.restoredEntry(queueIds: [], bookId: "li_book-1", position: 900, chapters: Self.chapters) == nil)
        let gone = ItemNamespace.chapterEntryId(bookId: "li_book-1", startMs: 650_000)
        #expect(ChapterEntryRules.restoredEntry(queueIds: [gone], bookId: "li_book-1", position: 900,
                                                chapters: Self.chapters) == nil, "an unknown chapter was restored")
    }

    @Test("a move or a removal in the list a person sees lands on the same entries in the queue behind it")
    func theShownPlacesMapToTheQueue() {
        let ids = ["a", Self.middle, "b", "c"]
        // Shown: a, b, c. Removing b (shown 1) is the queue's place 2.
        #expect(PlayQueue.actualOffsets(IndexSet(integer: 1), ids: ids, running: Self.middle) == IndexSet(integer: 2))
        // Moving c (shown 2) before a (shown 0): to the queue's place 0.
        #expect(PlayQueue.actualOffsets(IndexSet(integer: 2), ids: ids, running: Self.middle) == IndexSet(integer: 3))
        #expect(PlayQueue.actualDestination(0, ids: ids, running: Self.middle) == 0)
        // To the end of the shown list is the end of the queue.
        #expect(PlayQueue.actualDestination(3, ids: ids, running: Self.middle) == 4)
        // Before b (shown 1) is before the queue's place 2.
        #expect(PlayQueue.actualDestination(1, ids: ids, running: Self.middle) == 2)
        #expect(PlayQueue.actualOffsets(IndexSet(integer: 1), ids: ids, running: nil) == IndexSet(integer: 1))
    }
}

@MainActor
struct ChapterEntryRunningQueueTests {
    @Test("the queue shows everything but the running entry, a move among the shown keeps it where it is, and a book heard to its end takes it along")
    func theQueueHidesTheRunningEntry() {
        let queue = PlayQueue(isPlayable: { _ in true })
        let entry = ChapterEntryRunningRuleTests.middle
        for id in [entry, "rss:feed:a", "rss:feed:b"] { queue.playLast(id) }
        queue.running = entry
        #expect(queue.shownIds == ["rss:feed:a", "rss:feed:b"])
        queue.move(shownFrom: IndexSet(integer: 1), to: 0)
        #expect(queue.ids == [entry, "rss:feed:b", "rss:feed:a"], "the move landed on the wrong entries: \(queue.ids)")
        queue.markedPlayed("li_book-1")
        #expect(!queue.ids.contains(entry), "the running entry outlived its book heard to its end")
    }

    @Test("a jump out of the chapter calls the leave once and never the end")
    func aJumpOutCallsTheLeave() {
        let chapter = ABSChapter(id: 1, start: 600, end: 1200, title: "The Middle")
        let model = PlayerViewModel(provider: MockProvider())
        model.currentTime = 700
        var left = 0
        var ended = 0
        model.watchChapterRange(chapter, onLeave: { left += 1 }, onEnd: { ended += 1 })
        model.currentTime = 2000
        model.currentTime = 2100
        #expect(left == 1 && ended == 0, "left \(left), ended \(ended)")
        model.stop()
    }
}

/// Every reader that shows Up Next or picks the next title reads the list
/// without the running entry, and the restore sets the range the way the
/// open does.
struct ChapterEntryRunningFenceTests {
    private static func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("the car rebuilds its lists when what decides the shown list changes: the queue and the running entry, in both of its signals", .needsTheSources)
    func theCarHearsTheRunningEntry() throws {
        let car = try Self.code("Sources/CarPlay/CarPlaySceneDelegate.swift")
        let observe = try #require(ABSPodcastRefreshTests.body(of: "private func observe()", in: car))
        for source in ["queue.$ids", "queue.$running"] {
            let count = observe.components(separatedBy: source).count - 1
            #expect(count == 2, "\(source) drives \(count) of the two signals of the car")
        }
    }

    @Test("Up Next, the home rows, CarPlay, the widget and the advance read the shown list", .needsTheSources)
    func theReadersReadTheShownList() throws {
        let readers = ["Sources/Views/PlayQueueView.swift", "Sources/Views/HomeView.swift", "Sources/CarPlay/CarPlaySceneDelegate.swift"]
        for path in readers {
            let text = try Self.code(path)
            #expect(!text.contains("queue.ids"), "\(path) reads the whole queue, the running entry with it")
            #expect(text.contains("queue.shownIds"), "\(path) does not read the shown list")
        }
        let queue = try Self.code("Sources/Providers/PlayQueue.swift")
        let snapshot = try #require(ABSPodcastRefreshTests.body(of: "private func writeWidgetSnapshot()", in: queue))
        #expect(snapshot.contains("shownIds.prefix("), "the widget shows the running entry as next")
        let coordinator = try Self.code("Sources/ViewModels/PlayerCoordinator.swift")
        let inputs = try #require(ABSPodcastRefreshTests.body(of: "private func advanceInputs()", in: coordinator))
        #expect(inputs.contains("orders.shownIds"), "the advance may start the running entry again")
        #expect(!inputs.contains("orders.ids"))
    }

    @Test("the open and the restore set the range through one watch that leaves Up Next at the end and on a jump out", .needsTheSources)
    func theOpenAndTheRestoreWatchAlike() throws {
        let coordinator = try Self.code("Sources/ViewModels/PlayerCoordinator.swift")
        let open = try #require(ABSPodcastRefreshTests.body(of: "private func openChapter(", in: coordinator))
        #expect(open.contains("watchEntry("), "the open sets the range by hand")
        #expect(!open.contains("leaveBothLists(entryId)"), "the open takes the entry out of Up Next at its start")
        let restore = try #require(ABSPodcastRefreshTests.body(of: "func restoreLastSession(", in: coordinator))
        #expect(restore.contains("ChapterEntryRules.restoredEntry("), "the restore does not look for a running entry")
        #expect(restore.contains("watchEntry("), "the restore sets the range another way than the open")
        let watch = try #require(ABSPodcastRefreshTests.body(of: "private func watchEntry(", in: coordinator))
        #expect(watch.contains("onLeave:"), "a jump out does not take the entry out of Up Next")
        #expect(watch.contains("orders.running ="), "the queue does not learn which entry plays")
    }
}
#endif
