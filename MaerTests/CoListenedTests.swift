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

    @Test("Nach sechzig Tagen ohne weitere Folge steigt die Sendung von selbst aus")
    func leavesAfterTheWindow() {
        let inside = Self.row("a", playedAt: Self.now - 59 * Self.day)
        let outside = Self.row("b", playedAt: Self.now - 61 * Self.day)
        let shows = CoListened.shows(listened: [inside, outside],
                                     subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(shows.map(\.feedKey) == ["a"])
        #expect(CoListened.windowDays == 60)
    }

    @Test("Die Zaehlung nennt, warum eine Zeile fiel: nicht beobachtet, Fenster, abonniert, ausgeblendet")
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

    @Test("Kein Deckel: alle Sendungen im Fenster, die zuletzt gehoerten zuerst, je Sendung das juengste Vollhoeren")
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

    @Test("Die Sendung zaehlt ihre gehoerten Folgen, unabhaengig von der Reihenfolge")
    func showCountsItsPlayedEpisodes() {
        let rows = [Self.row("a", playedAt: Self.now - Self.day),
                    Self.row("a", playedAt: Self.now),
                    Self.row("a", playedAt: Self.now - 2 * Self.day),
                    Self.row("b", playedAt: Self.now)]
        let shows = CoListened.shows(listened: rows, subscribedFeedKeys: [],
                                     hiddenFeedKeys: [], now: Self.now)
        let a = shows.first { $0.feedKey == "a" }
        #expect(a?.playedEpisodes == 3)
        // Der juengste Eintrag bleibt der, der die anderen Felder setzt.
        #expect(a?.lastPlayedAt == Self.now)
        #expect(shows.first { $0.feedKey == "b" }?.playedEpisodes == 1)
    }

    @Test("Eine Folge ist ein Blick, zwei sind Geschmack")
    func oneEpisodeDoesNotCountForTaste() {
        let one = CoListened.shows(listened: [Self.row("a", playedAt: Self.now)],
                                   subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(one.first.map(CoListened.countsForTaste) == false)
        // Die REIHE traegt sie trotzdem: dort ist die Frage eine andere.
        #expect(one.count == 1)
        let two = CoListened.shows(listened: [Self.row("a", playedAt: Self.now),
                                              Self.row("a", playedAt: Self.now - Self.day)],
                                   subscribedFeedKeys: [], hiddenFeedKeys: [], now: Self.now)
        #expect(two.first.map(CoListened.countsForTaste) == true)
    }

    @Test("Eine ausgeblendete mitgehoerte Sendung zaehlt auch im Geschmack nicht")
    func hiddenShowNeverCountsForTaste() {
        let shows = CoListened.shows(listened: [Self.row("a", playedAt: Self.now),
                                                Self.row("a", playedAt: Self.now - Self.day)],
                                     subscribedFeedKeys: [], hiddenFeedKeys: ["a"], now: Self.now)
        #expect(shows.isEmpty, "ausgeblendet faellt vor der Zaehlung")
    }

    @Test("Ein Abo wiegt doppelt so schwer wie eine mitgehoerte Sendung derselben Hoerzeit")
    func subscriptionWeighsTwiceTheCoListened() {
        typealias Taste = PodcastRecommendationsStore.TasteShow
        let listening = ["own": 100.0, "heard": 100.0]
        let shows = [Taste(id: "own", author: "Verlag A", categories: ["History"], share: 1),
                     Taste(id: "heard", author: "Verlag B", categories: ["Comedy"],
                           share: CoListened.tasteShare)]
        // Gleiche Hoerzeit, gleiche eine Sendung: der Autor des Abos fuehrt.
        #expect(PodcastRecommendationsStore.weightedAuthors(shows, listening: listening)
                == ["Verlag A", "Verlag B"])
        #expect(PodcastRecommendationsStore.weightedCategories(shows, listening: listening)
                == ["History", "Comedy"])
        // Und zwar genau doppelt. Der Faktor sitzt am ganzen Gewicht, nicht
        // an der Hoerzeit allein (jede Sendung traegt eine Eins als Sockel,
        // damit ein neues Abo ueberhaupt zaehlt): bei 201 s steht es gleich,
        // erst darueber gewinnt die mitgehoerte Sendung.
        let tie = [shows[0], Taste(id: "heard", author: "Verlag B", categories: [],
                                   share: CoListened.tasteShare)]
        #expect(PodcastRecommendationsStore.weightedAuthors(tie, listening: ["own": 100, "heard": 202])
                .first == "Verlag B")
        #expect(PodcastRecommendationsStore.weightedAuthors(tie, listening: ["own": 100, "heard": 200])
                .first == "Verlag A")
    }

    @Test("Eine mitgehoerte Sendung hebt einen Autor, ohne selbst ein Abo zu sein")
    func coListenedLiftsAnAuthorWithoutSubscribing() {
        typealias Taste = PodcastRecommendationsStore.TasteShow
        let onlyOwn = [Taste(id: "own", author: "Verlag A", categories: [], share: 1)]
        #expect(PodcastRecommendationsStore.weightedAuthors(onlyOwn, listening: [:]) == ["Verlag A"])
        // Dieselbe Menge plus eine mitgehoerte Sendung eines anderen
        // Verlags: der neue Verlag steht in der Liste, das Abo bleibt vorn.
        let withHeard = onlyOwn + [Taste(id: "heard", author: "Verlag B", categories: [],
                                         share: CoListened.tasteShare)]
        #expect(PodcastRecommendationsStore.weightedAuthors(withHeard, listening: [:])
                == ["Verlag A", "Verlag B"])
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
        #expect(!PodcastShowSources.ownedFeedKeys().contains(PodcastSubscriptions.normalizeFeedURL(show.feedURL)))
    }

    /// The set of owned feeds has one name; spelled out again by hand, a
    /// second copy could miss a source and put a followed show back.
    @Test("die Menge der eigenen Feeds steht einmal, unter ihrem Namen", .needsTheSources)
    func theOwnedFeedsHaveOneName() throws {
        var spelled = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            spelled += code.components(separatedBy: "normalizedFeeds(ownedShows())").count - 1
            spelled += code.components(separatedBy: "normalizedFeeds(PodcastShowSources.ownedShows())").count - 1
        }
        #expect(spelled == 1, "the owned feeds are spelled out \(spelled) times")
    }
}
#endif
