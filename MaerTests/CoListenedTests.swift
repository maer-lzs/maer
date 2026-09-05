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
    @Test("Jede Flaeche mit mitgehoerten Sendungen hoert auf coListenedChanged")
    func everySurfaceListens() throws {
        var deaf: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("CoListenedShows.shows()") else { continue }
            if !text.contains(".coListenedChanged") { deaf.append(file.lastPathComponent) }
        }
        #expect(deaf.isEmpty, "these surfaces list co-listened shows but never hear the change: \(deaf)")
    }

    @Test("Eine voll gehoerte Folge im Fenster macht die Sendung mitgehoert")
    func oneObservedPlayThroughInsideTheWindow() {
        let shows = CoListened.shows(listened: [Self.row("a", playedAt: Self.now - 2 * Self.day)],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.map(\.feedKey) == ["a"])
        #expect(shows.first?.feedURL == "https://a/feed")
    }

    @Test("Nach dreissig Tagen ohne weitere Folge steigt die Sendung von selbst aus")
    func leavesAfterTheWindow() {
        let inside = Self.row("a", playedAt: Self.now - 29 * Self.day)
        let outside = Self.row("b", playedAt: Self.now - 31 * Self.day)
        let shows = CoListened.shows(listened: [inside, outside],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.map(\.feedKey) == ["a"])
    }

    @Test("Nachgebuchte Zeit zaehlt nicht, ein Grabstein auch nicht")
    func bookkeepingAndTombstonesDoNotCount() {
        let synthesized = Self.row("a", playedAt: Self.now - Self.day, observed: false)
        let unplayed = Self.row("b", playedAt: Self.now - Self.day, played: false)
        let shows = CoListened.shows(listened: [synthesized, unplayed],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.isEmpty)
    }

    @Test("Abonniert oder ausgeblendet ist nie mitgehoert")
    func subscribedAndHiddenAreOut() {
        let rows = [Self.row("subscribed", playedAt: Self.now - Self.day),
                    Self.row("hidden", playedAt: Self.now - Self.day),
                    Self.row("free", playedAt: Self.now - Self.day)]
        let shows = CoListened.shows(listened: rows, subscribedFeedKeys: ["subscribed"],
                                     hiddenFeedKeys: ["hidden"], now: Self.now)
        #expect(shows.map(\.feedKey) == ["free"])
    }

    @Test("Deckel zehn, die zuletzt gehoerten zuerst, je Sendung das juengste Vollhoeren")
    func capAndOrder() {
        var rows: [CoListened.Listened] = []
        for i in 0..<12 {
            rows.append(Self.row("s\(i)", playedAt: Self.now - Double(i) * Self.day))
            rows.append(Self.row("s\(i)", playedAt: Self.now - Double(i + 20) * Self.day))
        }
        let shows = CoListened.shows(listened: rows.shuffled(),
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.count == CoListened.cap)
        #expect(shows.map(\.feedKey) == (0..<10).map { "s\($0)" })
        #expect(shows.first?.lastPlayedAt == Self.now)
    }

    @Test("Ein Eintrag ohne Feed-Adresse traegt keine Sendung")
    func emptyFeedKeyIsIgnored() {
        let shows = CoListened.shows(listened: [Self.row("", playedAt: Self.now)],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.isEmpty)
    }

    @Test("Die Ausschlussliste ist des Nutzers und bleibt")
    func hiddenStoreKeeps() {
        CoListenedHiddenStore._resetForTest()
        defer { CoListenedHiddenStore._resetForTest() }
        #expect(CoListenedHiddenStore.feedKeys().isEmpty)
        CoListenedHiddenStore.hide(feedKey: "a")
        CoListenedHiddenStore.hide(feedKey: "b")
        CoListenedHiddenStore.hide(feedKey: "a")
        #expect(CoListenedHiddenStore.feedKeys() == ["a", "b"])
    }

    /// Kein Abo durch die Hintertuer: die Sitzungshaelfte kennt eine Sendung,
    /// der Abo-Bestand nicht, und das bleibt so, was immer die Regel sagt.
    @Test("Mitgehoert erreicht den Abo-Bestand nicht")
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
        #expect(!CoListenedShows.subscribedFeedKeys().contains(PodcastSubscriptions.normalizeFeedURL(show.feedURL)))
    }
}
#endif
