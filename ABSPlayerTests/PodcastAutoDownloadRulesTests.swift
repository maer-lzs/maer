// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// The one condition that must never soften: the cleanup touches ONLY what the
/// automatism downloaded itself.
struct PodcastAutoDownloadRulesTests {
    private let day: Double = 24 * 3600

    @Test("a hand-picked download is never swept — however old and however finished")
    func manualDownloadsAreUntouchable() {
        let now: Double = 1_000 * day
        let mine = PodcastAutoDownloadRules.Item(id: "rss:a:1", isFinished: true, finishedAt: now - 900 * day)
        #expect(PodcastAutoDownloadRules.expired([mine], ownedByAutomation: [], now: now).isEmpty,
                "an episode the user downloaded must survive any sweep")
        #expect(PodcastAutoDownloadRules.expired([mine], ownedByAutomation: ["rss:a:1"], now: now) == ["rss:a:1"])
    }

    @Test("finished is not enough — the keep window has to have passed")
    func keepWindowIsRespected() {
        let now: Double = 1_000 * day
        let justFinished = PodcastAutoDownloadRules.Item(id: "x", isFinished: true, finishedAt: now - 2 * day)
        let longDone = PodcastAutoDownloadRules.Item(id: "y", isFinished: true, finishedAt: now - 8 * day)
        let unfinished = PodcastAutoDownloadRules.Item(id: "z", isFinished: false, finishedAt: 0)
        let gone = PodcastAutoDownloadRules.expired([justFinished, longDone, unfinished],
                                                    ownedByAutomation: ["x", "y", "z"], now: now)
        #expect(gone == ["y"], "only the one finished longer ago than the window")
    }

    @Test("a finished state without a timestamp is not a licence to delete")
    func missingTimestampNeverExpires() {
        let now: Double = 1_000 * day
        let stampless = PodcastAutoDownloadRules.Item(id: "x", isFinished: true, finishedAt: 0)
        #expect(PodcastAutoDownloadRules.expired([stampless], ownedByAutomation: ["x"], now: now).isEmpty)
    }

    @Test("the note forgets what it deleted and what the user deleted by hand")
    func theNoteDoesNotGrowForever() {
        let owned: Set<String> = ["a", "b", "c"]
        let left = PodcastAutoDownloadRules.forget(ownedByAutomation: owned,
                                                   deleted: ["a"],
                                                   stillDownloaded: ["b"])
        #expect(left == ["b"], "deleted by us AND deleted by hand both leave the note")
    }

    /// The direction of working a backlog: first N unheard, ascending —
    /// played and already-local episodes fall out BEFORE the cap, so the cap
    /// always buys N new listenable files.
    @Test("nextInOrder picks the first unheard episodes, ascending")
    func nextInOrderPicksOldestUnheard() {
        let episodes = [
            PodcastAutoDownloadRules.Candidate(guid: "e5", pubDate: 500),
            PodcastAutoDownloadRules.Candidate(guid: "e1", pubDate: 100),
            PodcastAutoDownloadRules.Candidate(guid: "e3", pubDate: 300),
            PodcastAutoDownloadRules.Candidate(guid: "e2", pubDate: 200),
            PodcastAutoDownloadRules.Candidate(guid: "e4", pubDate: 400),
        ]
        // e1 is heard, e3 is already local: the first three UNHEARD, in order.
        let picked = PodcastAutoDownloadRules.nextInOrder(
            episodes,
            isPlayed: { $0 == "e1" },
            isDownloaded: { $0 == "e3" },
            limit: 3)
        #expect(picked == ["e2", "e4", "e5"])
        // Everything heard or local: nothing to fetch, never an invention.
        #expect(PodcastAutoDownloadRules.nextInOrder(
            episodes, isPlayed: { _ in true }, isDownloaded: { _ in false }, limit: 3).isEmpty)
    }
}
#endif
