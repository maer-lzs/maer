// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Teil 3: the Rediscover picks — source thresholds, daily-deterministic
/// rotation, empty-section behaviour; plus the Discover subscribed-filter and
/// the F3 author-portrait tap rule.
struct RediscoverSectionsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ d: Double) -> Double { now.timeIntervalSince1970 - d * 86_400 }

    @Test("paused source: only items pausing longer than 3 weeks, with the week count")
    func pausedThreshold() {
        let picks = RediscoverSections.picks(
            paused: [(id: "fresh", lastPlayed: daysAgo(5)),
                     (id: "stale", lastPlayed: daysAgo(28)),
                     (id: "never", lastPlayed: 0)],
            unheard: [], seriesNext: [], now: now, daySeed: 1, limit: 10)
        #expect(picks.map(\.id) == ["stale"])
        #expect(picks.first?.reason == .paused(weeks: 4))
    }

    @Test("unheard source: only additions older than 30 days, with the added date")
    func unheardThreshold() {
        let added = daysAgo(45)
        let picks = RediscoverSections.picks(
            paused: [],
            unheard: [(id: "new", addedAt: daysAgo(10)), (id: "old", addedAt: added)],
            seriesNext: [], now: now, daySeed: 1, limit: 10)
        #expect(picks.map(\.id) == ["old"])
        #expect(picks.first?.reason == .unheardSince(added: Date(timeIntervalSince1970: added)))
    }

    @Test("series source passes through with its volume; sources interleave")
    func seriesAndInterleave() {
        let picks = RediscoverSections.picks(
            paused: [(id: "p1", lastPlayed: daysAgo(30))],
            unheard: [(id: "u1", addedAt: daysAgo(40))],
            seriesNext: [(id: "s1", volume: 3)],
            now: now, daySeed: 7, limit: 10)
        #expect(Set(picks.map(\.id)) == ["p1", "u1", "s1"])
        // Round-robin across sources in priority order: one of each first.
        #expect(picks.count == 3)
        #expect(picks.contains { $0.reason == .nextInSeries(volume: 3) })
    }

    @Test("rotation is deterministic per day seed and stable across calls")
    func rotationDeterminism() {
        let paused = (0..<12).map { (id: "p\($0)", lastPlayed: daysAgo(30 + Double($0))) }
        let a = RediscoverSections.picks(paused: paused, unheard: [], seriesNext: [],
                                         now: now, daySeed: 20_260_718, limit: 5)
        let b = RediscoverSections.picks(paused: paused, unheard: [], seriesNext: [],
                                         now: now, daySeed: 20_260_718, limit: 5)
        #expect(a == b)                       // same day → same picks
        let c = RediscoverSections.picks(paused: paused, unheard: [], seriesNext: [],
                                         now: now, daySeed: 20_260_719, limit: 5)
        #expect(a.map(\.id) != c.map(\.id))   // next day rotates (12 candidates)
    }

    @Test("no candidates → empty (the section hides); limit respected; ids unique")
    func emptyAndLimit() {
        #expect(RediscoverSections.picks(paused: [], unheard: [], seriesNext: [],
                                         now: now, daySeed: 1, limit: 4).isEmpty)
        let many = (0..<20).map { (id: "p\($0)", lastPlayed: daysAgo(30)) }
        let picks = RediscoverSections.picks(paused: many, unheard: [], seriesNext: [],
                                             now: now, daySeed: 1, limit: 4)
        #expect(picks.count == 4)
        #expect(Set(picks.map(\.id)).count == 4)
    }

    @Test("volume parses the ABS '#N' series-name convention")
    func volumeParsing() {
        #expect(RediscoverSections.volume(fromSeriesName: "Die Letzte Flotte #5") == 5)
        #expect(RediscoverSections.volume(fromSeriesName: "Reihe #12 – Extra") == 12)
        #expect(RediscoverSections.volume(fromSeriesName: "Ohne Nummer") == nil)
        #expect(RediscoverSections.volume(fromSeriesName: nil) == nil)
    }

    @Test("day seed changes exactly with the calendar day")
    func daySeedCalendar() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let d1 = DateComponents(calendar: cal, year: 2026, month: 7, day: 18, hour: 1).date!
        let d2 = DateComponents(calendar: cal, year: 2026, month: 7, day: 18, hour: 23).date!
        let d3 = DateComponents(calendar: cal, year: 2026, month: 7, day: 19, hour: 0, minute: 5).date!
        #expect(RediscoverSections.daySeed(for: d1, calendar: cal) == RediscoverSections.daySeed(for: d2, calendar: cal))
        #expect(RediscoverSections.daySeed(for: d2, calendar: cal) != RediscoverSections.daySeed(for: d3, calendar: cal))
    }
}

/// Teil 4: a subscribed show must never appear as a recommendation.
@MainActor
struct DiscoverFilterTests {
    @Test("subscribed feeds and duplicates are dropped, order kept")
    func excludesSubscribed() {
        let results = [
            PodcastSearchResult(title: "A", author: nil, artworkURL: nil, feedURL: "https://a.example/feed"),
            PodcastSearchResult(title: "B", author: nil, artworkURL: nil, feedURL: "https://b.example/feed"),
            PodcastSearchResult(title: "A dup", author: nil, artworkURL: nil, feedURL: "https://a.example/feed"),
            PodcastSearchResult(title: "C", author: nil, artworkURL: nil, feedURL: "https://c.example/feed"),
        ]
        let subscribed: Set<String> = [PodcastSubscriptions.normalizeFeedURL("https://b.example/feed")]
        let out = PodcastRecommendationsStore.excludingSubscribed(results, subscribedNormalizedFeeds: subscribed)
        #expect(out.map(\.title) == ["A", "C"])
    }
}

/// F3: the author portrait's tap rule — several works ⇒ tappable filter, a
/// single work ⇒ plain image.
struct AuthorPortraitRuleTests {
    @Test func tapRule() {
        #expect(!LibraryViewModel.authorFilterEnabled(workCount: 0))
        #expect(!LibraryViewModel.authorFilterEnabled(workCount: 1))
        #expect(LibraryViewModel.authorFilterEnabled(workCount: 2))
        #expect(LibraryViewModel.authorFilterEnabled(workCount: 12))
    }

    @Test("5dcbf21: dormant shows join with a share cap and the shared threshold")
    func dormantShows() {
        let now = Date(timeIntervalSince1970: 100 * 24 * 3600)
        let old = now.timeIntervalSince1970 - 30 * 24 * 3600   // > pausedAfter
        let fresh = now.timeIntervalSince1970 - 2 * 24 * 3600  // recently heard
        let shows = (0..<8).map { (id: "show-\($0)", lastPlayed: old) }
            + [(id: "show-fresh", lastPlayed: fresh)]
        let picks = RediscoverSections.picks(
            paused: (0..<10).map { (id: "book-\($0)", lastPlayed: old) },
            unheard: [], seriesNext: [],
            showsDormant: shows,
            now: now, daySeed: 42, limit: 10)
        let showPicks = picks.filter { if case .showDormant = $0.reason { return true }; return false }
        // Share cap: max limit/5 = 2 of 10 — books are never displaced.
        #expect(showPicks.count == RediscoverSections.showCap(limit: 10))
        #expect(showPicks.count == 2)
        // Recently heard shows never qualify (shared pausedAfter threshold).
        #expect(!picks.contains { $0.id == "show-fresh" })
        // Weeks ride in the reason for the honest subtitle.
        if case .showDormant(let weeks) = showPicks[0].reason { #expect(weeks >= 4) }
        // Without shows the behavior is untouched (default parameter).
        let plain = RediscoverSections.picks(
            paused: [(id: "b", lastPlayed: old)], unheard: [], seriesNext: [],
            now: now, daySeed: 42, limit: 10)
        #expect(plain.map(\.id) == ["b"])
    }
}
#endif