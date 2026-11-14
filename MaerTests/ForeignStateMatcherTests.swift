// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every rung of the ladder on its own, the ambiguity rules, and the
/// preview count. The feed key is a plain lowercase here; the real
/// normalizer is the caller's business.
struct ForeignStateMatcherTests {
    /// The preview says before the import how much of the shared pot the
    /// states take: measured 124 B per state, cap one million bytes.
    @Test("the preview estimates the room in the pot from the number of states")
    func previewEstimatesThePotSpace() {
        var preview = ForeignImportPreview()
        #expect(preview.estimatedPotBytes == 0)
        preview.states = 2_621
        #expect(preview.estimatedPotBytes == 2_621 * 124)
        #expect(preview.estimatedPotBytes < ForeignImportPreview.potLimitBytes)
        // Red probe: an import that bursts the pot lies above the cap.
        preview.states = 9_000
        #expect(preview.estimatedPotBytes > ForeignImportPreview.potLimitBytes)
    }

    private func key(_ feed: String) -> String { feed.lowercased() }

    private func target(_ id: String, guid: String? = nil, enclosure: String,
                        link: String? = nil, title: String, feed: String = "https://a.example/rss") -> ForeignMatchTarget {
        ForeignMatchTarget(id: id, rawGUID: guid, enclosureURL: enclosure, link: link,
                           title: title, feedKey: key(feed))
    }

    private func state(feed: String? = "https://a.example/rss", guid: String? = nil,
                       enclosure: String? = nil, link: String? = nil,
                       title: String? = nil) -> ForeignListeningState {
        ForeignListeningState(feedURL: feed, episodeGUID: guid, enclosureURL: enclosure,
                              episodeLink: link, episodeTitle: title,
                              position: 120, finished: false, stampedAt: 1_000)
    }

    private func plan(_ states: [ForeignListeningState], _ targets: [ForeignMatchTarget],
                      twin: [String: String] = [:]) -> ForeignStateMatcher.Plan {
        ForeignStateMatcher.plan(states: states, targets: targets, twinBridge: twin, feedKeyOf: key)
    }

    @Test("the GUID matches, even if enclosure and title differ")
    func guidRung() {
        let t = target("e1", guid: "guid-1", enclosure: "https://cdn/1.mp3", title: "One")
        let p = plan([state(guid: "guid-1", enclosure: "https://other/x.mp3", title: "Other")], [t])
        #expect(p.matches.map(\.targetID) == ["e1"])
        #expect(p.matches.first?.step == .guid)
        #expect(p.unmatched.isEmpty)
    }

    @Test("the raw GUID comes from the stored key")
    func rawGUID() {
        #expect(ForeignStateMatcher.rawGUID(storedGUID: "rss:abc123:https://a.example/p/1") == "https://a.example/p/1")
        #expect(ForeignStateMatcher.rawGUID(storedGUID: "rss:abc123:plain-guid") == "plain-guid")
        #expect(ForeignStateMatcher.rawGUID(storedGUID: "something-else") == "something-else")
    }

    @Test("the enclosure matches across scheme, query and trailing slash")
    func enclosureRung() {
        let t = target("e1", enclosure: "https://cdn.example/1.mp3", title: "One")
        let p = plan([state(enclosure: "http://CDN.example/1.mp3/?token=abc")], [t])
        #expect(p.matches.first?.targetID == "e1")
        #expect(p.matches.first?.step == .enclosure)
    }

    @Test("the twin bridge leads a free enclosure to the premium episode")
    func twinRung() {
        let premium = target("p1", enclosure: "https://premium.example/1.mp3?token=x", title: "One")
        let p = plan([state(enclosure: "https://free.example/1.mp3")], [premium],
                     twin: ["free.example/1.mp3": "p1"])
        #expect(p.matches.first?.targetID == "p1")
        #expect(p.matches.first?.step == .twin)
    }

    @Test("the link matches the episode link and the permalink GUID")
    func linkRung() {
        let byLink = target("e1", enclosure: "https://cdn/1.mp3", link: "https://a.example/episodes/1", title: "One")
        let byPermalink = target("e2", guid: "https://a.example/episodes/2", enclosure: "https://cdn/2.mp3", title: "Two")
        let p = plan([state(enclosure: "https://drifted/1.mp3", link: "https://a.example/episodes/1/"),
                      state(enclosure: "https://drifted/2.mp3", link: "http://a.example/episodes/2")],
                     [byLink, byPermalink])
        #expect(p.matches.map(\.targetID) == ["e1", "e2"])
        #expect(p.matches.allSatisfy { $0.step == .link })
    }

    @Test("the title matches only if it is unique in source AND stock")
    func titleRung() {
        let one = target("e1", enclosure: "https://cdn/1.mp3", title: "  Folge Eins ")
        let twinA = target("e2", enclosure: "https://cdn/2.mp3", title: "Doppelt")
        let twinB = target("e3", enclosure: "https://cdn/3.mp3", title: "Doppelt", feed: "https://b.example/rss")
        let unique = plan([state(enclosure: "https://gone/1.mp3", title: "folge eins")], [one])
        #expect(unique.matches.first?.step == .title)
        #expect(unique.matches.first?.targetID == "e1")
        // Twice in the source: neither may take the one episode.
        let twiceInSource = plan([state(enclosure: "https://gone/a.mp3", title: "Folge Eins"),
                                  state(enclosure: "https://gone/b.mp3", title: "Folge Eins")], [one])
        #expect(twiceInSource.matches.isEmpty)
        #expect(twiceInSource.unmatched.count == 2)
        // Twice in the stock, but in different shows: the state's feed settles it.
        let settled = plan([state(feed: "https://B.example/rss", enclosure: "https://gone/x.mp3", title: "Doppelt")],
                           [twinA, twinB])
        #expect(settled.matches.first?.targetID == "e3")
        // Without a feed to settle it, the rung does not count.
        let open = plan([state(feed: nil, enclosure: "https://gone/x.mp3", title: "Doppelt")], [twinA, twinB])
        #expect(open.matches.isEmpty)
        #expect(open.unmatched.count == 1)
    }

    @Test("the rungs apply in their order: a GUID beats an enclosure")
    func rungOrder() {
        let right = target("e1", guid: "g1", enclosure: "https://cdn/1.mp3", title: "One")
        let wrong = target("e2", guid: "g2", enclosure: "https://cdn/moved.mp3", title: "Two")
        let p = plan([state(guid: "g1", enclosure: "https://cdn/moved.mp3")], [right, wrong])
        #expect(p.matches.first?.targetID == "e1")
        #expect(p.matches.first?.step == .guid)
    }

    @Test("Apple rows without a feed search across all shows")
    func rowsWithoutFeed() {
        let t = target("e1", enclosure: "https://cdn/1.mp3", title: "One", feed: "https://b.example/rss")
        let p = plan([state(feed: nil, enclosure: "https://cdn/1.mp3")], [t])
        #expect(p.matches.first?.targetID == "e1")
    }

    @Test("what is not assigned is counted and keeps its name")
    func unmatchedKeepsName() {
        let p = plan([state(enclosure: "https://nowhere/9.mp3", title: "Nine")], [])
        #expect(p.matches.isEmpty)
        #expect(p.unmatched.first?.episodeTitle == "Nine")
    }

    @Test("the preview counts what the file carries, not what the source promises")
    func previewCounts() {
        var finished = state(feed: "https://a.example/rss", enclosure: "https://cdn/1.mp3")
        finished.finished = true
        var noMoment = state(feed: "https://c.example/rss", enclosure: "https://cdn/2.mp3")
        noMoment.stampedAt = nil
        let library = ForeignLibrary(feedURLs: ["https://a.example/rss", "https://c.example/rss"],
                                     states: [finished, noMoment, state(enclosure: "https://cdn/3.mp3")],
                                     unimportablePaidCount: 2)
        let preview = ForeignImportPreview.make(library, subscribedFeedKeys: [key("https://a.example/rss")],
                                                feedKeyOf: key)
        #expect(preview.shows == 2)
        #expect(preview.alreadySubscribed == 1)
        #expect(preview.states == 3)
        #expect(preview.finished == 1)
        #expect(preview.inProgress == 2)
        #expect(preview.withMoment == 2)
        #expect(preview.unimportablePaid == 2)
    }

    /// Several rows of one source for one episode are reduced to the one
    /// that speaks for it BEFORE the rule. Passing them through the rule
    /// one by one measurably depended on the order: a finished row that
    /// arrived first shielded the newer unfinished one.
    @Test("duplicate rows of a source are reduced to one before the rule, independent of order")
    func duplicatesReduceToOne() {
        func row(_ position: Double, finished: Bool = false, at stamp: Double?) -> ForeignListeningState {
            ForeignListeningState(feedURL: nil, episodeGUID: nil, enclosureURL: "https://cdn/1.mp3",
                                  episodeLink: nil, episodeTitle: nil, position: position,
                                  finished: finished, stampedAt: stamp)
        }
        let t = target("e1", enclosure: "https://cdn/1.mp3", title: "One")
        let older = row(900, at: 1_000), newer = row(300, at: 2_000), stale = row(0, finished: true, at: 500)
        for order in [[older, stale, newer], [stale, newer, older], [newer, older, stale]] {
            let p = plan(order, [t])
            #expect(p.matches.count == 1)
            #expect(p.matches.first?.state == newer)
            #expect(p.unmatched.isEmpty)
        }
        // Without moments: finished speaks, then the further position.
        let a = row(100, at: nil), b = row(700, at: nil), c = row(0, finished: true, at: nil)
        #expect(ForeignStateMerge.preferred(a, b) == b)
        #expect(ForeignStateMerge.preferred(b, a) == b)
        #expect(ForeignStateMerge.preferred(b, c) == c)
        #expect(ForeignStateMerge.preferred(c, b) == c)
        // A moment on one side only decides nothing; the mark decides.
        #expect(ForeignStateMerge.preferred(c, older) == c)
    }
}
#endif
