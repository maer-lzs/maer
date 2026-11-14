// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// A played mark that comes from elsewhere takes the title out of Up Next,
/// and only the change counts: the rule, the listen log that carries the
/// stand carriers and gpodder, the twins, and the fence over every caller.
@MainActor
@Suite(.serialized)
struct HeardElsewhereTests {
    private static func progress(_ fraction: Double, finished: Bool = false) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: finished, lastUpdate: 1_000)
    }

    @Test("the rule as a table: only the change to played counts, a title without a prior answer does not")
    func theRuleAsATable() {
        #expect(HeardElsewhere.became(wasPlayed: false, isPlayed: true))
        #expect(!HeardElsewhere.became(wasPlayed: true, isPlayed: true), "played before and after: no change")
        #expect(!HeardElsewhere.became(wasPlayed: false, isPlayed: false))
        #expect(!HeardElsewhere.became(wasPlayed: true, isPlayed: false))
        #expect(HeardElsewhere.isPlayed([600, 1_000, 600], duration: 600, tail: 60))
        #expect(!HeardElsewhere.isPlayed([100, 1_000, 600], duration: 600, tail: 60))
        #expect(!HeardElsewhere.isPlayed(nil, duration: 600, tail: 60), "no entry is not played")
        let before = ["a": Self.progress(0.5), "b": Self.progress(1, finished: true), "c": Self.progress(0.2)]
        let after = ["a": Self.progress(1, finished: true), "b": Self.progress(1, finished: true),
                     "c": Self.progress(0.3), "d": Self.progress(1, finished: true)]
        #expect(HeardElsewhere.newlyFinished(before: before, after: after) == ["a"],
                "b was finished before, c is not, d has no answer before")
    }

    @Test("a title the answer before does not name asks the set kept from an earlier run")
    func theKeptSetFillsTheGap() {
        let before = ["b": Self.progress(0.5), "c": Self.progress(1, finished: true)]
        let after = ["a": Self.progress(1, finished: true), "b": Self.progress(1, finished: true),
                     "c": Self.progress(1, finished: true), "d": Self.progress(1, finished: true),
                     "e": Self.progress(0.4)]
        #expect(HeardElsewhere.newlyFinished(before: before, after: after, held: ["a", "c"]) == ["a", "b"],
                "a was held unfinished, b changed in this run, c was finished in this run, d was held by nobody")
        #expect(HeardElsewhere.newlyFinished(before: [:], after: after) == [], "without a kept set the first answer is no change")
        #expect(HeardElsewhere.unfinished(after) == ["e"])
    }

    @Test("after a cold start a book and an episode finished elsewhere meanwhile leave Up Next; the first answer ever brings nothing")
    func aColdStartComparesWithTheKeptSet() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("maer.sqlite").path
        for kind in [HeldUnfinished.Kind.books, .absEpisodes] {
            let first = HeldUnfinished(database: MaerDatabase(path: path), kind: kind)
            #expect(first.adopt(before: [:], after: ["a": Self.progress(0.5), "b": Self.progress(1, finished: true)]) == [],
                    "the first answer ever took something out")
            await first.awaitPendingWrites()
            // A new start: the progress of the run is gone, the kept set is not.
            let next = HeldUnfinished(database: MaerDatabase(path: path), kind: kind)
            #expect(next.held == ["a"], "the set did not survive the start: \(next.held)")
            #expect(next.adopt(before: [:], after: ["a": Self.progress(1, finished: true), "b": Self.progress(1, finished: true)]) == ["a"],
                    "a title finished while the app was closed stayed")
            await next.awaitPendingWrites()
            #expect(HeldUnfinished(database: MaerDatabase(path: path), kind: kind).held.isEmpty,
                    "an answer with nothing unfinished left the old set behind")
        }
    }

    @Test("a server that leaves the device takes its kept set along: the next account's first answer takes nothing out")
    func aLeavingServerForgetsItsKeptSet() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("held-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("maer.sqlite").path
        let held = HeldUnfinished(database: MaerDatabase(path: path), kind: .books)
        _ = held.adopt(before: [:], after: ["a": Self.progress(0.5)])
        await held.awaitPendingWrites()
        try #require(HeldUnfinished(database: MaerDatabase(path: path), kind: .books).held == ["a"], "the precondition: the set is kept")
        held.forget()
        await held.awaitPendingWrites()
        let next = HeldUnfinished(database: MaerDatabase(path: path), kind: .books)
        #expect(next.held.isEmpty, "the set of the server that left survived: \(next.held)")
        #expect(next.adopt(before: [:], after: ["a": Self.progress(1, finished: true)]) == [],
                "the next account's first answer compared with the former server's set")
    }

    private static func log(in folder: URL, queue: PlayQueue) -> PodcastListenLog {
        PodcastListenLog(database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path), upNext: queue)
    }

    @Test("a sync that marks an episode played takes it out of Up Next; one already played stays if the sync does not change its mark")
    func onlyTheChangeTakesItOut() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = UUID().uuidString.prefix(8)
        let became = "rss:heard-\(run):became", kept = "rss:heard-\(run):kept"
        defer {
            for id in [became, kept] { ListeningStore.forgetUserDeleted(id) }
            try? FileManager.default.removeItem(at: folder)
        }
        let queue = PlayQueue()
        queue.playLast(became)
        queue.playLast(kept)
        let log = Self.log(in: folder, queue: queue)
        let now = Date().timeIntervalSince1970 * 1000
        // What the carrier wrote: both played now.
        ListeningStore.store(became, entry: [600, now, 600])
        ListeningStore.store(kept, entry: [600, now, 600])
        log.noteReconciled(guids: [became, kept],
                           before: [became: [100, now - 60_000, 600], kept: [600, now - 60_000, 600]])
        #expect(!queue.contains(became), "an episode that became played stayed in Up Next")
        #expect(queue.contains(kept), "an episode played before, put back on purpose, was taken out again")
    }

    @Test("gpodder brings many ids in one sync: the queue is written once")
    func aWholeHistoryWritesTheQueueOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = UUID().uuidString.prefix(8)
        let ids = (0..<450).map { "rss:heard-\(run):\($0)" }
        defer {
            for id in ids { ListeningStore.forgetUserDeleted(id) }
            try? FileManager.default.removeItem(at: folder)
        }
        let queue = PlayQueue()
        for id in ids { queue.playLast(id) }
        let log = Self.log(in: folder, queue: queue)
        let now = Date().timeIntervalSince1970 * 1000
        for id in ids { ListeningStore.store(id, entry: [600, now, 600]) }
        var changes = 0
        let watch = queue.$ids.dropFirst().sink { _ in changes += 1 }
        defer { watch.cancel() }
        await log.noteReconciled(batched: ids, before: [:])
        #expect(queue.isEmpty, "\(queue.ids.count) episodes stayed")
        #expect(changes == 1, "the queue was written \(changes) times for one round")
    }

    @Test("a played abspod episode takes its queued RSS twin along and the other way round")
    func aTwinLeavesWithIt() {
        let twins = ["abspod:s:e": "rss:k:g", "rss:k:g": "abspod:s:e",
                     "abspod:s:f": "rss:k:h", "rss:k:h": "abspod:s:f"]
        let queue = PlayQueue(equivalents: { id in [id] + (twins[id].map { [$0] } ?? []) })
        queue.playLast("rss:k:g")
        queue.playLast("abspod:s:f")
        queue.playLast("book-1")
        queue.markedPlayed(["abspod:s:e"])
        #expect(queue.ids == ["abspod:s:f", "book-1"], "the RSS twin stayed")
        queue.markedPlayed(["rss:k:h"])
        #expect(queue.ids == ["book-1"], "the abspod twin stayed")
    }

    /// Who takes a title out of Up Next because it was heard, by file, with
    /// the reason. The device's own marks, then each way a mark from
    /// elsewhere arrives; the change of account replaces the whole stock and
    /// calls nothing.
    static let callers: [String: (count: Int, reason: String)] = [
        "BookFinishMark.swift": (1, "the person marks a book"),
        "PlayerViewModel+Sync.swift": (1, "the player marks the title it plays"),
        "PodcastPlayState.swift": (1, "the person marks an episode"),
        "PodcastListenLog.swift": (2, "the stand carriers and gpodder, one door and its batch"),
        "PodcastSubscriptions.swift": (1, "a foreign import"),
        "LibraryViewModel.swift": (1, "the servers' book progress"),
        "ABSPodcastProvider.swift": (1, "the Audiobookshelf episode progress"),
    ]

    @Test("the callers of markedPlayed are in the stock, and every new one asks for the change", .needsTheSources)
    func everyCallerIsNamed() throws {
        var found: [String: Int] = [:]
        var texts: [String: String] = [:]
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let stripped = SyncContractFenceTests.stripped(text)
            let hits = stripped.components(separatedBy: ".markedPlayed(").count - 1
            if hits > 0 { found[file] = hits; texts[file] = stripped }
        }
        #expect(found == Self.callers.mapValues(\.count), "\(found)")
        for file in ["PodcastListenLog.swift", "PodcastSubscriptions.swift"] {
            #expect(texts[file]?.contains("HeardElsewhere.") == true, "\(file) takes out without asking for the change")
        }
        // The two server answers ask through the kept set, so the first
        // answer after a start has a before too.
        for (file, call) in ["LibraryViewModel.swift": "heldUnfinished?.adopt(before: lastProgress, after: progress)",
                             "ABSPodcastProvider.swift": "heldUnfinished.adopt(before: episodeProgress, after: fresh)"] {
            #expect(texts[file]?.contains(call) == true, "\(file) asks for the change without the set kept across starts")
        }
        #expect(texts["PodcastCloudSync.swift"] == nil, "the change of account calls nothing")
        let gpodder = try #require(ProjectFileIntegrityTests.sourceTexts().first { $0.0 == "GPodderSync.swift" }?.1)
        #expect(SyncContractFenceTests.stripped(gpodder).contains("noteReconciled(batched: outcome.pulledGuids, before: outcome.before)"),
                "gpodder hands its entries from before the round")
    }
}
#endif
