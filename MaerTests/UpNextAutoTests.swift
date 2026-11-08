// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// New episodes of a show into Up Next, at the top, at the end or not at
/// all: the rule, the queue's door, the refresh that calls it, and the fence
/// over every way that merges a fresh feed.
@MainActor
struct UpNextAutoTests {
    typealias Arrival = UpNextAuto.Arrival

    private static func plan(_ arrivals: [Arrival], placement: [String: UpNextAuto.Placement],
                             since: [String: Double], heard: Set<String> = [], queued: Set<String> = []) -> UpNextAuto.Plan {
        UpNextAuto.plan(arrivals, placement: { placement[$0] ?? .off }, since: { since[$0] },
                        isUnheard: { !heard.contains($0) }, isQueued: { queued.contains($0) })
    }

    @Test("die Regel als Tabelle: aus, oben, hinten; gehoert, angefangen, schon drin, vor dem Einschalten; zwei Sendungen nach Erscheinen")
    func theRuleAsATable() {
        let arrivals = [Arrival(id: "a2", showId: "A", pubDate: 2_000), Arrival(id: "a1", showId: "A", pubDate: 1_500),
                        Arrival(id: "b1", showId: "B", pubDate: 1_800), Arrival(id: "c1", showId: "C", pubDate: 1_900),
                        Arrival(id: "a0", showId: "A", pubDate: 900), Arrival(id: "a3", showId: "A", pubDate: 2_100),
                        Arrival(id: "a4", showId: "A", pubDate: 2_200)]
        let plan = Self.plan(arrivals, placement: ["A": .top, "B": .end, "C": .off],
                             since: ["A": 1_000, "B": 1_000, "C": 1_000], heard: ["a3"], queued: ["a4"])
        #expect(plan.top == ["a1", "a2"], "the top block in the order the episodes appeared")
        #expect(plan.end == ["b1"])
        // Each line on its own: off, before the moment, heard or begun, queued.
        #expect(Self.plan([arrivals[3]], placement: ["C": .off], since: ["C": 0]).isEmpty, "off adds nothing")
        #expect(Self.plan([arrivals[4]], placement: ["A": .top], since: ["A": 1_000]).isEmpty, "before the moment")
        #expect(Self.plan([arrivals[1]], placement: ["A": .top], since: [:]).isEmpty, "no moment, nothing")
        #expect(Self.plan([arrivals[5]], placement: ["A": .end], since: ["A": 0], heard: ["a3"]).isEmpty, "heard or begun")
        #expect(Self.plan([arrivals[6]], placement: ["A": .end], since: ["A": 0], queued: ["a4"]).isEmpty, "already queued")
        #expect(Self.plan([arrivals[0], arrivals[0]], placement: ["A": .end], since: ["A": 0]).end == ["a2"], "once")
        // Two shows at the end mix by appearance.
        let mixed = Self.plan([Arrival(id: "x2", showId: "X", pubDate: 30), Arrival(id: "y1", showId: "Y", pubDate: 20),
                               Arrival(id: "x1", showId: "X", pubDate: 10)],
                              placement: ["X": .end, "Y": .end], since: ["X": 0, "Y": 0])
        #expect(mixed.end == ["x1", "y1", "x2"])
    }

    @Test("ein Feed, der seine Kennungen neu vergibt, flutet nichts: 50 neue Kennungen, alle vor dem Einschalten erschienen")
    func newIdsForAnOldBacklogQueueNothing() {
        let stored = Self.show("flood", episodes: (0..<50).map { ("old-\($0)", Double($0) * 1_000) })
        let moved = Self.show("flood", episodes: (0..<50).map { ("new-\($0)", Double($0) * 1_000) })
        let arrivals = UpNextAuto.arrivals(stored: stored, merged: PodcastIdentity.merge(stored, moved))
        #expect(arrivals.count == 50, "the precondition: every episode arrives under a new id")
        let plan = Self.plan(arrivals, placement: [stored.id: .top], since: [stored.id: 60_000])
        #expect(plan.isEmpty, "a backlog under new ids went into Up Next: \(plan.top.count)")
        // The same arrivals after the moment do go: the date is what held them.
        #expect(Self.plan(arrivals, placement: [stored.id: .top], since: [stored.id: -1]).top.count == 50)
    }

    @Test("was ankommt, ist nur, was die Ablage vorher nicht hatte; eine Sendung zum ersten Mal bringt nichts")
    func onlyWhatWasNotStoredArrives() {
        let stored = Self.show("arrive", episodes: [("e1", 1_000), ("e2", 2_000)])
        let fresh = Self.show("arrive", episodes: [("e2", 2_000), ("e3", 3_000)])
        let arrivals = UpNextAuto.arrivals(stored: stored, merged: PodcastIdentity.merge(stored, fresh))
        #expect(arrivals.map(\.id) == [Self.id("arrive", "e3")])
        #expect(UpNextAuto.arrivals(stored: nil, merged: fresh).isEmpty, "the first contact is the backlog")
    }

    @Test("die Warteschlange: oben als Block vor dem Bestand, hinten danach, nichts Vorhandenes bewegt sich")
    func theQueueTakesBlocks() {
        let queue = PlayQueue()
        queue.playLast("book-1")
        queue.playLast("rss:q:old")
        queue.addArrivals(UpNextAuto.Plan(top: ["rss:q:t1", "rss:q:t2"], end: ["rss:q:e1", "rss:q:old"]))
        #expect(queue.ids == ["rss:q:t1", "rss:q:t2", "book-1", "rss:q:old", "rss:q:e1"])
        queue.addArrivals(UpNextAuto.Plan(top: ["radio:x", "rss:q:t1"], end: []))
        #expect(queue.ids.count == 5, "a station never, a queued one not again")
    }

    @Test("ein Auffrischen reiht die neue Folge ein, ein zweites reiht nichts doppelt ein, eine entfernte kommt nicht zurueck, das Einschalten reiht nichts ein")
    func aRefreshQueuesOnceAndNotAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("upnext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "upnext-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = PodcastPublishCountTests.openTheRSSGate()
        defer {
            closeTheGate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try #require(AppStorageKeys.rssActive, "the RSS gate is closed, the case measures nothing")
        let run = UUID().uuidString.prefix(8)
        let feed = try #require(URL(string: "https://upnext.example/\(run)/feed.xml"))
        let queue = PlayQueue()
        let subs = PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                                        database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
                                        defaults: defaults, isTheApp: false, upNext: queue)
        await subs.ensureLoaded()
        let now = Date().timeIntervalSince1970 * 1000
        var episodes: [(String, Double)] = [("e1", now - 86_400_000), ("e2", now - 3_600_000)]
        subs._testFeedFetcher = { url in .show(Self.show(url, episodes: episodes)) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        let showId = try #require(subs.shows.first?.id)

        // Switched on now: the episodes that are there stay out.
        defaults.set(UpNextAuto.Placement.top.rawValue, forKey: UpNextAuto.key(showId))
        defaults.set(now - 60_000, forKey: UpNextAuto.sinceKey(showId))
        await subs.refreshAll()
        #expect(queue.ids.isEmpty, "switching on queued the episodes that were there")

        episodes.append(("e3", now))
        await subs.refreshAll()
        let new = try #require(subs.shows.first?.episodes.first { $0.guid.hasSuffix(":e3") }?.guid)
        #expect(queue.ids == [new], "the new episode is at the top")

        // The background refresh and a pull shortly after: nothing twice.
        await subs.refreshAll()
        #expect(queue.ids == [new], "a second refresh queued again: \(queue.ids)")

        queue.remove(new)
        await subs.refreshAll()
        #expect(queue.ids.isEmpty, "a removed episode came back")
    }

    @Test("eine uebernommene Wahl ohne Moment bekommt den Moment des Auffrischens, und was jetzt ankommt, bleibt draussen")
    func anAdoptedChoiceTakesTheMomentOfTheRefresh() throws {
        let suite = "upnext-adopted-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = Self.show("adopted", episodes: [("e1", 1_000)])
        let merged = PodcastIdentity.merge(stored, Self.show("adopted", episodes: [("e2", 2_000)]))
        defaults.set(UpNextAuto.Placement.end.rawValue, forKey: UpNextAuto.key(stored.id))
        let queue = PlayQueue()
        UpNextArrivals.take([(stored: stored, merged: merged)], queue: queue, store: defaults, now: 5_000)
        #expect(UpNextAutoChoice.since(stored.id, store: defaults) == 5_000, "the moment was not noted")
        #expect(queue.ids.isEmpty, "an episode from before the moment was queued")
    }

    @Test("die Wahl reist wie Neue Folgen, der Moment bleibt auf dem Geraet, das offene Blatt liest sie nach")
    func whatTravels() {
        #expect(UserChoiceCatalog.prefixes["podcastUpNextAdd."] == .travels)
        #expect(UserChoiceCatalog.travelingPrefixes.contains("podcastUpNextAdd."))
        #expect(UserChoiceCatalog.statics[UpNextAuto.generalKey] == .travels)
        #expect(UserChoiceCatalog.travelingScalars.contains(UpNextAuto.generalKey))
        #expect(UserChoiceCatalog.prefixes["podcastUpNextAddSince."] == .device)
        #expect(UserChoiceCatalog.statics[UpNextAuto.generalSinceKey] == .device)
        #expect(UpNextAuto.key("s") == "podcastUpNextAdd.s" && UpNextAuto.sinceKey("s") == "podcastUpNextAddSince.s")
        #expect(PodcastShowPreferences.travellingKeys(showId: "s").contains(UpNextAuto.key("s")))
    }

    @Test("jeder Weg, der einen frischen Feed in eine gefolgte Sendung fuehrt, gibt die Ankuenfte an die eine Stelle; das Abonnieren nicht", .needsTheSources)
    func everyMergeHandsItsArrivals() throws {
        let source = try PodcastGeneralRuleTests.source("Sources/Providers/PodcastSubscriptions.swift")
        let stripped = SyncContractFenceTests.stripped(source)
        #expect(stripped.components(separatedBy: "PodcastIdentity.merge(").count - 1 == 4,
                "a new way merges a feed: hand its arrivals over, or say why not")
        for head in ["func refreshAll() async {", "func absorb(_ fresh: PodcastShow, showId: String) async -> Int? {",
                     "func recheckAccess(showId: String) async {"] {
            let body = try #require(functionBody(of: head, in: stripped), "\(head) was not found")
            #expect(body.contains("PodcastIdentity.merge(") && body.contains("UpNextArrivals.take("), "\(head)")
        }
        #expect(stripped.components(separatedBy: "UpNextArrivals.take(").count - 1 == 3)
        // The queue's door for arrivals has one caller, and playNext and
        // playLast stay the person's.
        var doors: [String: Int] = [:]
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let hits = SyncContractFenceTests.stripped(text).components(separatedBy: ".addArrivals(").count - 1
            if hits > 0 { doors[file] = hits }
        }
        #expect(doors == ["UpNextArrivals.swift": 1], "\(doors)")
    }

    // MARK: - Shows

    static func id(_ name: String, _ guid: String) -> String { "rss:\(name):\(guid)" }

    static func show(_ name: String, episodes: [(String, Double)]) -> PodcastShow {
        PodcastShow(id: "rss:\(name)", title: name, author: nil, artworkURL: nil, description: nil,
                    feedURL: "https://\(name).example/feed.xml",
                    episodes: episodes.map {
                        PodcastEpisode(guid: id(name, $0.0), title: $0.0, audioURL: "https://\(name).example/\($0.0).mp3",
                                       pubDate: $0.1, duration: 600)
                    })
    }

    static func show(_ url: URL, episodes: [(String, Double)]) -> PodcastShow {
        let key = PodcastIdentity.feedKey(url.absoluteString)
        return PodcastShow(id: key, title: "Up Next", author: nil, artworkURL: nil, description: nil,
                           feedURL: url.absoluteString,
                           episodes: episodes.map {
                               PodcastEpisode(guid: "rss:\(key):\($0.0)", title: $0.0,
                                              audioURL: "https://upnext.example/\($0.0).mp3", pubDate: $0.1, duration: 600)
                           })
    }
}
#endif
