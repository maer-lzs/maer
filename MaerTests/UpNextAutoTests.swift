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

    @Test("the rule as a table: off, top, end; heard, begun, already in, before switching on; two shows by appearance")
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

    @Test("a feed that reissues its ids floods nothing: 50 new ids, all appeared before switching on")
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

    @Test("what arrives is only what the storage did not have before; a show for the first time brings nothing")
    func onlyWhatWasNotStoredArrives() {
        let stored = Self.show("arrive", episodes: [("e1", 1_000), ("e2", 2_000)])
        let fresh = Self.show("arrive", episodes: [("e2", 2_000), ("e3", 3_000)])
        let arrivals = UpNextAuto.arrivals(stored: stored, merged: PodcastIdentity.merge(stored, fresh))
        #expect(arrivals.map(\.id) == [Self.id("arrive", "e3")])
        #expect(UpNextAuto.arrivals(stored: nil, merged: fresh).isEmpty, "the first contact is the backlog")
    }

    @Test("the queue: at the top as a block before the stock, at the end after it, nothing existing moves")
    func theQueueTakesBlocks() {
        let queue = PlayQueue()
        queue.playLast("book-1")
        queue.playLast("rss:q:old")
        queue.addArrivals(UpNextAuto.Plan(top: ["rss:q:t1", "rss:q:t2"], end: ["rss:q:e1", "rss:q:old"]))
        #expect(queue.ids == ["rss:q:t1", "rss:q:t2", "book-1", "rss:q:old", "rss:q:e1"])
        queue.addArrivals(UpNextAuto.Plan(top: ["radio:x", "rss:q:t1"], end: []))
        #expect(queue.ids.count == 5, "a station never, a queued one not again")
    }

    @Test("a refresh queues the new episode, a second one queues nothing twice, a removed one does not come back, switching on queues nothing")
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

    @Test("a second subscription to a followed show queues the new episode, like a refresh")
    func aSecondSubscribeQueuesTheNewEpisode() async throws {
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
        let feed = try #require(URL(string: "https://upnext.example/\(UUID().uuidString.prefix(8))/feed.xml"))
        let queue = PlayQueue()
        let subs = PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                                        database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
                                        defaults: defaults, isTheApp: false, upNext: queue)
        await subs.ensureLoaded()
        let now = Date().timeIntervalSince1970 * 1000
        var episodes: [(String, Double)] = [("e1", now - 86_400_000)]
        subs._testFeedFetcher = { url in .show(Self.show(url, episodes: episodes)) }
        try #require(await subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        #expect(queue.ids.isEmpty, "the first subscription queued its backlog")
        let showId = try #require(subs.shows.first?.id)
        defaults.set(UpNextAuto.Placement.end.rawValue, forKey: UpNextAuto.key(showId))
        defaults.set(now - 60_000, forKey: UpNextAuto.sinceKey(showId))

        episodes.append(("e2", now))
        _ = await subs.subscribe(urlString: feed.absoluteString, notesCloud: false)
        let new = try #require(subs.shows.first?.episodes.first { $0.guid.hasSuffix(":e2") }?.guid)
        #expect(queue.ids == [new], "the episode a second subscription brought never reaches Up Next: \(queue.ids)")
    }

    @Test("an adopted choice without a moment gets the moment of the refresh, and what arrives now stays out")
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

    @Test("the choice travels like New Episodes, the moment stays on the device, the open sheet reads it again")
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

    @Test("every path that leads a fresh feed into a followed show hands the arrivals to the one place; subscribing does not", .needsTheSources)
    func everyMergeHandsItsArrivals() throws {
        let source = try PodcastGeneralRuleTests.source("Sources/Providers/PodcastSubscriptions.swift")
        let stripped = SyncContractFenceTests.stripped(source)
        #expect(stripped.components(separatedBy: "PodcastIdentity.merge(").count - 1 == 4,
                "a new way merges a feed: hand its arrivals over, or say why not")
        for head in ["func absorb(_ fresh: PodcastShow, showId: String) async -> Int? {",
                     "func recheckAccess(showId: String) async {", "func follow(urlString:"] {
            let body = try #require(functionBody(of: head, in: stripped), "\(head) was not found")
            #expect(body.contains("PodcastIdentity.merge(") && body.contains("UpNextArrivals.take("), "\(head)")
        }
        // The refresh of all feeds merges through its pure rule, by id onto
        // the stock as it stands, and hands the pairs it made over.
        let refresh = try #require(functionBody(of: "func refreshAll() async {", in: stripped))
        #expect(refresh.contains("Self.mergedRefresh(current: shows, fetched: fetched)") && refresh.contains("UpNextArrivals.take("))
        let rule = try #require(functionBody(of: "nonisolated static func mergedRefresh(current: [PodcastShow], fetched: [String: PodcastShow])", in: stripped))
        #expect(rule.contains("PodcastIdentity.merge("))
        #expect(stripped.components(separatedBy: "UpNextArrivals.take(").count - 1 == 4)
        // The one exception is the first subscription: its branch hands nothing.
        let follow = try #require(functionBody(of: "func follow(urlString:", in: stripped))
        let merge = try #require(follow.range(of: "PodcastIdentity.merge("))
        let firstBranch = try #require(follow.range(of: "} else {", range: merge.upperBound..<follow.endIndex))
        let take = try #require(follow.range(of: "UpNextArrivals.take("))
        #expect(merge.lowerBound < take.lowerBound && take.lowerBound < firstBranch.lowerBound,
                "the merge of a followed show hands its arrivals before the branch of the first subscription")
        // The queue's door for arrivals has one caller, and playNext and
        // playLast stay the person's.
        var doors: [String: Int] = [:]
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let hits = SyncContractFenceTests.stripped(text).components(separatedBy: ".addArrivals(").count - 1
            if hits > 0 { doors[file] = hits }
        }
        #expect(doors == ["UpNextArrivals.swift": 1], "\(doors)")
    }

    // MARK: - Audiobookshelf

    private static func absShow(_ item: String, _ episodes: [(String, Double)]) -> PodcastShow {
        PodcastShow(id: "abspod:\(item)", title: item, author: nil, artworkURL: nil, description: nil, feedURL: "",
                    episodes: episodes.map {
                        PodcastEpisode(guid: "abspod:\(item):\($0.0)", title: $0.0, audioURL: "", pubDate: $0.1, duration: 600)
                    })
    }

    @Test("Audiobookshelf after a cold start: the episode that came out in between arrives; the first meeting brings nothing")
    func aColdStartSeesWhatArrivedBetween() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("absknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("maer.sqlite").path
        let first = ABSKnownEpisodes(database: MaerDatabase(path: path))
        #expect(first.adopt([Self.absShow("s1", [("e1", 1_000), ("e2", 2_000)])]).isEmpty,
                "the first meeting is the backlog")
        await first.awaitPendingWrites()

        // A new start: the shows are gone from memory, the ids are not.
        let again = ABSKnownEpisodes(database: MaerDatabase(path: path))
        let found = again.adopt([Self.absShow("s1", [("e1", 1_000), ("e2", 2_000), ("e3", 3_000)])])
        #expect(found.flatMap(\.arrivals).map(\.id) == ["abspod:s1:e3"], "what arrived while the app was closed: \(found)")
    }

    @Test("Audiobookshelf: a show the server no longer names loses its row")
    func aShowTheServerDropsLosesItsRow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("absknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("maer.sqlite").path
        let known = ABSKnownEpisodes(database: MaerDatabase(path: path))
        _ = known.adopt([Self.absShow("keep", [("e1", 1_000)]), Self.absShow("gone", [("e1", 1_000)])])
        await known.awaitPendingWrites()
        _ = known.adopt([Self.absShow("keep", [("e1", 1_000)])])
        await known.awaitPendingWrites()
        let again = ABSKnownEpisodes(database: MaerDatabase(path: path))
        #expect(Set(again.known.keys) == ["abspod:keep"], "rows: \(again.known.keys.sorted())")
    }

    @Test("Audiobookshelf: an episode whose RSS twin is queued already does not come twice")
    func anAudiobookshelfTwinIsNotQueuedTwice() throws {
        let suite = "upnext-abs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let twins = ["abspod:t:e2": "rss:t:g2", "rss:t:g2": "abspod:t:e2"]
        let queue = PlayQueue(equivalents: { id in [id] + (twins[id].map { [$0] } ?? []) })
        queue.playLast("rss:t:g2")
        let show = Self.absShow("t", [("e2", 5_000)])
        defaults.set(UpNextAuto.Placement.top.rawValue, forKey: UpNextAuto.key(show.id))
        defaults.set(1_000.0, forKey: UpNextAuto.sinceKey(show.id))
        UpNextArrivals.take(found: [(show: show, arrivals: UpNextAuto.arrivals(known: [], show: show))],
                            queue: queue, store: defaults)
        #expect(queue.ids == ["rss:t:g2"], "the twin was queued again: \(queue.ids)")
    }

    @Test("the queue asks its own check whether an episode can be heard: a text-only episode stays out")
    func theQueueAsksItsOwnPlayableCheck() {
        let queue = PlayQueue(isPlayable: { $0 != "rss:t:text" })
        queue.addArrivals(UpNextAuto.Plan(top: ["rss:t:text", "rss:t:audio"], end: []))
        queue.playNext("rss:t:text")
        queue.playLast("rss:t:text")
        #expect(queue.ids == ["rss:t:audio"])
    }

    @Test("Audiobookshelf: only an adopted refresh moves the set, and it hands its arrivals to the one place", .needsTheSources)
    func onlyAnAdoptedRefreshMovesTheSet() throws {
        let source = SyncContractFenceTests.stripped(try PodcastGeneralRuleTests.source("Sources/Providers/ABSPodcastProvider.swift"))
        #expect(source.components(separatedBy: "known.adopt(").count - 1 == 1)
        let rule = try #require(source.range(of: "ABSPodcastRefreshRule.adopts("))
        let adopt = try #require(source.range(of: "known.adopt(loaded)"))
        let replace = try #require(source.range(of: "replaceShows(loaded,"))
        let take = try #require(source.range(of: "UpNextArrivals.take(found: found, queue: upNext)"))
        #expect(rule.lowerBound < adopt.lowerBound && adopt.lowerBound < replace.lowerBound && replace.lowerBound < take.lowerBound,
                "the set moves inside the adopted branch, the arrivals go after the bridge is new")
        // The branch ends before the next `} else if`; the set is not moved there.
        let elseBranch = try #require(source.range(of: "} else if fetched.holdsBack {"))
        #expect(take.lowerBound < elseBranch.lowerBound)
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
