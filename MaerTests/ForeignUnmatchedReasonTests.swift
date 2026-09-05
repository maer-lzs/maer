// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A state no episode claims names why, in the order the ladder needed
/// things: a show we have, a handle, a unique title. The reasons feed the
/// per-show line of the preview and the log.
struct ForeignUnmatchedReasonTests {
    private func target(_ id: String, title: String, feedKey: String) -> ForeignMatchTarget {
        ForeignMatchTarget(id: id, rawGUID: id, enclosureURL: "https://cdn.example.org/\(id).mp3",
                           link: nil, title: title, feedKey: feedKey)
    }

    private func state(feed: String?, title: String?, enclosure: String? = nil) -> ForeignListeningState {
        ForeignListeningState(feedURL: feed, showTitle: feed.map { "Show \($0)" }, episodeGUID: nil,
                              enclosureURL: enclosure, episodeLink: nil, episodeTitle: title,
                              position: 600, finished: false, stampedAt: nil)
    }

    @Test("Vier Gruende, je einer, in Leiter-Reihenfolge")
    func reasonsNameWhereTheLadderStopped() {
        let targets = [target("e1", title: "One", feedKey: "f1"), target("e2", title: "Two", feedKey: "f1"),
                       target("e3", title: "Dup", feedKey: "f1"), target("e4", title: "Dup", feedKey: "f1")]
        let states = [
            // A show we do not have. (A unique title would still match
            // across shows, that is the ladder's title rung; so no title
            // of ours.)
            state(feed: "f9", title: "Zero"),
            state(feed: "f1", title: nil),                                  // no handle at all
            state(feed: "f1", title: "Dup", enclosure: "https://x/dup.mp3"),   // title twice on our side
            state(feed: "f1", title: "Nine", enclosure: "https://x/nine.mp3")   // simply not in the feed
        ]
        let plan = ForeignStateMatcher.plan(states: states, targets: targets, feedKeyOf: { $0 })
        #expect(plan.matches.isEmpty)
        #expect(plan.unmatched.count == 4)
        #expect(plan.whyUnmatched == [.showUnknown, .noHandle, .titleAmbiguous, .notInFeed])
        // Rot-Probe: a state that matches carries no reason.
        let hit = ForeignStateMatcher.plan(states: [state(feed: "f1", title: "One")], targets: targets, feedKeyOf: { $0 })
        #expect(hit.matches.count == 1 && hit.whyUnmatched.isEmpty)
    }
}
#endif
