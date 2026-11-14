// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The co-listened rule is pure: kept browsed episodes joined with the
/// listen log, minus subscriptions and the hidden list, inside a window,
/// capped. Every decision of the order has a witness here.
struct CoListenedTests {
    static let day: Double = 24 * 3600 * 1000
    static let now: Double = 1_800_000_000_000

    static func row(_ feed: String, playedAt: Double, played: Bool = true, observed: Bool = true,
                    title: String = "Show") -> CoListened.Listened {
        CoListened.Listened(feedKey: feed, feedURL: "https://" + feed + "/feed", showTitle: title,
                            playedAt: playedAt, isPlayed: played, hasObservedTime: observed)
    }

    /// Every view that lists the co-listened shows recomputes on the
    /// notification, so "Don't show this show" acts at once on every
    /// surface, the full page included (it used to wait for a tab switch).
    @Test("Every surface with co-listened shows listens to coListenedChanged", .needsTheSources)
    func everySurfaceListens() throws {
        var deaf: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("CoListenedShows.shows()") else { continue }
            if !text.contains(".coListenedChanged") { deaf.append(file.lastPathComponent) }
        }
        #expect(deaf.isEmpty, "these surfaces list co-listened shows but never hear the change: \(deaf)")
    }

    @Test("A fully listened episode in the window makes the show co-listened")
    func oneObservedPlayThroughInsideTheWindow() {
        let shows = CoListened.shows(listened: [Self.row("a", playedAt: Self.now - 2 * Self.day)],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.map(\.feedKey) == ["a"])
        #expect(shows.first?.feedURL == "https://a/feed")
    }

    @Test("After sixty days without another episode the show drops out by itself")
    func leavesAfterTheWindow() {
        let inside = Self.row("a", playedAt: Self.now - 59 * Self.day)
        let outside = Self.row("b", playedAt: Self.now - 61 * Self.day)
        let shows = CoListened.shows(listened: [inside, outside],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.map(\.feedKey) == ["a"])
        #expect(CoListened.windowDays == 60)
    }

    @Test("The count names why a row fell: not observed, window, subscribed, hidden")
    func tallyNamesEveryDrop() {
        let rows = [Self.row("kept", playedAt: Self.now - Self.day),
                    Self.row("old", playedAt: Self.now - 61 * Self.day),
                    Self.row("book", playedAt: Self.now - Self.day, observed: false),
                    Self.row("sub", playedAt: Self.now - Self.day),
                    Self.row("hid", playedAt: Self.now - Self.day),
                    Self.row("", playedAt: Self.now)]
        let (shows, tally) = CoListened.evaluate(listened: rows, subscribedFeedKeys: ["sub"],
                                                 hiddenFeedKeys: ["hid"], now: Self.now)
        #expect(shows.map(\.feedKey) == ["kept"])
        #expect(tally == CoListened.Tally(listened: 6, shows: 1, unobservedDropped: 2, windowDropped: 1,
                                          subscribedDropped: 1, hiddenDropped: 1))
    }

    @Test("Time booked afterwards does not count, nor does a tombstone")
    func bookkeepingAndTombstonesDoNotCount() {
        let synthesized = Self.row("a", playedAt: Self.now - Self.day, observed: false)
        let unplayed = Self.row("b", playedAt: Self.now - Self.day, played: false)
        let shows = CoListened.shows(listened: [synthesized, unplayed],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.isEmpty)
    }

    @Test("Subscribed or hidden is never co-listened")
    func subscribedAndHiddenAreOut() {
        let rows = [Self.row("subscribed", playedAt: Self.now - Self.day),
                    Self.row("hidden", playedAt: Self.now - Self.day),
                    Self.row("free", playedAt: Self.now - Self.day)]
        let shows = CoListened.shows(listened: rows, subscribedFeedKeys: ["subscribed"],
                                     hiddenFeedKeys: ["hidden"], now: Self.now)
        #expect(shows.map(\.feedKey) == ["free"])
    }

    @Test("No cap: all shows in the window, the most recently listened first, per show the latest full listen")
    func noCapAndOrder() {
        var rows: [CoListened.Listened] = []
        for i in 0..<12 {
            rows.append(Self.row("s\(i)", playedAt: Self.now - Double(i) * Self.day))
            rows.append(Self.row("s\(i)", playedAt: Self.now - Double(i + 20) * Self.day))
        }
        let shows = CoListened.shows(listened: rows.shuffled(),
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.count == 12, "the old cap of ten fell; the window is the only limit")
        #expect(shows.map(\.feedKey) == (0..<12).map { "s\($0)" })
        #expect(shows.first?.lastPlayedAt == Self.now)
    }

    @Test("The show counts its listened episodes, regardless of order")
    func showCountsItsPlayedEpisodes() {
        let rows = [Self.row("a", playedAt: Self.now - Self.day),
                    Self.row("a", playedAt: Self.now),
                    Self.row("a", playedAt: Self.now - 2 * Self.day),
                    Self.row("b", playedAt: Self.now)]
        let shows = CoListened.shows(listened: rows, subscribedFeedKeys: [],
                                     hiddenFeedKeys: [], now: Self.now)
        let a = shows.first { $0.feedKey == "a" }
        #expect(a?.playedEpisodes == 3)
        // The latest entry stays the one that sets the other fields.
        #expect(a?.lastPlayedAt == Self.now)
        #expect(shows.first { $0.feedKey == "b" }?.playedEpisodes == 1)
    }

    @Test("One episode is a glance, two are taste")
    func oneEpisodeDoesNotCountForTaste() {
        let one = CoListened.shows(listened: [Self.row("a", playedAt: Self.now)],
                                   subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(one.first.map(CoListened.countsForTaste) == false)
        // The ROW carries it anyway: there the question is a different one.
        #expect(one.count == 1)
        let two = CoListened.shows(listened: [Self.row("a", playedAt: Self.now),
                                              Self.row("a", playedAt: Self.now - Self.day)],
                                   subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(two.first.map(CoListened.countsForTaste) == true)
    }

    @Test("A hidden co-listened show does not count in taste either")
    func hiddenShowNeverCountsForTaste() {
        let shows = CoListened.shows(listened: [Self.row("a", playedAt: Self.now),
                                                Self.row("a", playedAt: Self.now - Self.day)],
                                     subscribedFeedKeys: [], hiddenFeedKeys: ["a"], now: Self.now)
        #expect(shows.isEmpty, "ausgeblendet faellt vor der Zaehlung")
    }

    @Test("A subscription weighs twice as much as a co-listened show of the same listening time")
    func subscriptionWeighsTwiceTheCoListened() {
        typealias Taste = PodcastRecommendationsStore.TasteShow
        let listening = ["own": 100.0, "heard": 100.0]
        let shows = [Taste(id: "own", author: "Verlag A", categories: ["History"], share: 1),
                     Taste(id: "heard", author: "Verlag B", categories: ["Comedy"],
                           share: CoListened.tasteShare)]
        // Same listening time, same single show: the subscription's author leads.
        #expect(PodcastRecommendationsStore.weightedAuthors(shows, listening: listening)
                == ["Verlag A", "Verlag B"])
        #expect(PodcastRecommendationsStore.weightedCategories(shows, listening: listening)
                == ["History", "Comedy"])
        // Exactly twice. The factor applies to the whole weight, not to the
        // listening time alone (every show carries a one as base, so that a
        // new subscription counts at all): at 201 s it is level, only above
        // that does the co-listened show win.
        let tie = [shows[0], Taste(id: "heard", author: "Verlag B", categories: [],
                                   share: CoListened.tasteShare)]
        #expect(PodcastRecommendationsStore.weightedAuthors(tie, listening: ["own": 100, "heard": 202])
                .first == "Verlag B")
        #expect(PodcastRecommendationsStore.weightedAuthors(tie, listening: ["own": 100, "heard": 200])
                .first == "Verlag A")
    }

    @Test("A co-listened show lifts an author without itself being a subscription")
    func coListenedLiftsAnAuthorWithoutSubscribing() {
        typealias Taste = PodcastRecommendationsStore.TasteShow
        let onlyOwn = [Taste(id: "own", author: "Verlag A", categories: [], share: 1)]
        #expect(PodcastRecommendationsStore.weightedAuthors(onlyOwn, listening: [:]) == ["Verlag A"])
        // The same set plus a co-listened show of another publisher: the
        // new publisher is in the list, the subscription stays in front.
        let withHeard = onlyOwn + [Taste(id: "heard", author: "Verlag B", categories: [],
                                         share: CoListened.tasteShare)]
        #expect(PodcastRecommendationsStore.weightedAuthors(withHeard, listening: [:])
                == ["Verlag A", "Verlag B"])
    }

    @Test("An entry without a feed address carries no show")
    func emptyFeedKeyIsIgnored() {
        let shows = CoListened.shows(listened: [Self.row("", playedAt: Self.now)],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.isEmpty)
    }

    @Test("The exclusion list belongs to the user and stays")
    func hiddenStoreKeeps() {
        CoListenedHiddenStore._resetForTest()
        defer { CoListenedHiddenStore._resetForTest() }
        #expect(CoListenedHiddenStore.feedKeys().isEmpty)
        CoListenedHiddenStore.hide(feedKey: "a")
        CoListenedHiddenStore.hide(feedKey: "b")
        CoListenedHiddenStore.hide(feedKey: "a")
        #expect(CoListenedHiddenStore.feedKeys() == ["a", "b"])
    }

    /// No subscription through the back door: the session half knows a show,
    /// the subscription stock does not, and that stays so, whatever the rule says.
    @Test("Co-listened does not reach the subscription stock")
    @MainActor
    func noSubscriptionThroughTheBackDoor() {
        BrowsedEpisodes.shared._testReset()
        defer { BrowsedEpisodes.shared._testReset() }
        let show = PodcastShow(id: "co-1", title: "Co", author: nil, artworkURL: nil, description: nil,
                               feedURL: "https://co.example/feed",
                               episodes: [PodcastEpisode(guid: "rss:co-ep", title: "Ep", audioURL: "https://co.example/1.mp3",
                                                         pubDate: 1, duration: 60)])
        BrowsedEpisodes.shared.remember(show: show)
        #expect(BrowsedEpisodes.shared.sessionShows().map(\.id) == ["co-1"])
        #expect(!PodcastSubscriptions.shared.shows.contains { $0.id == "co-1" })
        #expect(!PodcastAutoContinue.allShows().contains { $0.id == "co-1" })
        #expect(!PodcastShowSources.ownedFeedKeys().contains(PodcastIdentity.normalizeFeedURL(show.feedURL)))
    }

    /// The set of owned feeds has one name; built again by hand, in one step
    /// or in two, a second copy could miss a source and put a followed show
    /// back. Every call that folds shows into feed addresses is counted, in
    /// whatever spelling, and only the sources' own file may make one.
    @Test("the set of own feeds stands once, under its name", .needsTheSources)
    func theOwnedFeedsHaveOneName() throws {
        var texts: [String: String] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            texts[file.lastPathComponent] = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        }
        #expect(texts["PodcastsView.swift"] != nil, "the precondition: the fence read the sources")
        #expect(Self.calls(of: "normalizedFeeds", in: texts) == ["PodcastShowSources.swift": 1],
                "shows are folded into feed addresses outside the sources' file: \(Self.calls(of: "normalizedFeeds", in: texts))")
        // The one door that keeps the owned shows out, by feed and by title.
        #expect(Self.calls(of: "excludingSubscribed", in: texts) == ["PodcastShowSources.swift": 1],
                "a list keeps the owned shows out past the door: \(Self.calls(of: "excludingSubscribed", in: texts))")
        // Calibration: the two-step form counts, the definition does not.
        #expect(Self.calls(of: "normalizedFeeds",
                           in: ["A.swift": "let shows = x()\nlet f = PodcastShowMerge.normalizedFeeds(shows)",
                                "B.swift": "static func normalizedFeeds(_ shows: [PodcastShow]) -> Set<String> {"])
                == ["A.swift": 1])
    }

    /// Per file, the lines that call `name(`; its definition is no call.
    nonisolated static func calls(of name: String, in texts: [String: String]) -> [String: Int] {
        var found: [String: Int] = [:]
        for (file, text) in texts {
            let calls = text.split(separator: "\n").filter {
                $0.contains("\(name)(") && !$0.contains("func \(name)(")
            }.count
            if calls > 0 { found[file] = calls }
        }
        return found
    }
}
#endif
