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

    @Test("die Regel als Tabelle: nur der Wechsel zu gehoert zaehlt, ein Titel ohne Antwort davor nicht")
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

    private static func log(in folder: URL, queue: PlayQueue) -> PodcastListenLog {
        PodcastListenLog(database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path), upNext: queue)
    }

    @Test("ein Abgleich, der eine Folge gehoert macht, nimmt sie aus Als Naechstes; eine schon gehoerte bleibt, wenn der Abgleich ihre Marke nicht aendert")
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

    @Test("gpodder bringt viele Kennungen in einem Abgleich: die Warteschlange wird einmal geschrieben")
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

    @Test("eine gehoerte abspod-Folge nimmt ihren eingereihten RSS-Zwilling mit und umgekehrt")
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

    @Test("die Rufer von markedPlayed stehen im Bestand, und jeder neue fragt den Wechsel", .needsTheSources)
    func everyCallerIsNamed() throws {
        var found: [String: Int] = [:]
        var texts: [String: String] = [:]
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let stripped = SyncContractFenceTests.stripped(text)
            let hits = stripped.components(separatedBy: ".markedPlayed(").count - 1
            if hits > 0 { found[file] = hits; texts[file] = stripped }
        }
        #expect(found == Self.callers.mapValues(\.count), "\(found)")
        for file in ["PodcastListenLog.swift", "PodcastSubscriptions.swift", "LibraryViewModel.swift", "ABSPodcastProvider.swift"] {
            #expect(texts[file]?.contains("HeardElsewhere.") == true, "\(file) takes out without asking for the change")
        }
        #expect(texts["PodcastCloudSync.swift"] == nil, "the change of account calls nothing")
        let gpodder = try #require(ProjectFileIntegrityTests.sourceTexts().first { $0.0 == "GPodderSync.swift" }?.1)
        #expect(SyncContractFenceTests.stripped(gpodder).contains("noteReconciled(batched: outcome.pulledGuids, before: outcome.before)"),
                "gpodder hands its entries from before the round")
    }
}
#endif
