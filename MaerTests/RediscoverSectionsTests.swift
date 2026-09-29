// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Teil 3: the Rediscover picks. Source thresholds, daily-deterministic
/// rotation, empty-section behaviour; plus the Discover subscribed-filter and
/// the author-portrait tap rule.
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

    @Test("fb94905: the free twin of a premium subscription is excluded by SHOW identity")
    func excludesByShowIdentity() {
        // The reported case: premium feed subscribed (podcatcher URL), the
        // free Simplecast variant shows up in the pool. Different URL, same
        // show. And the mirror image: free subscribed, premium recommended.
        let pool = [
            PodcastSearchResult(title: "Servus. Grüezi. Hallo.", author: "ZEIT",
                                artworkURL: nil, feedURL: "https://feeds.simplecast.com/sgh"),
            PodcastSearchResult(title: "Servus. Gruezi. Hallo.", author: "ZEIT",
                                artworkURL: nil, feedURL: "https://other.example/sgh2"),
            PodcastSearchResult(title: "Servus. Grüezi. Hallo. Spezial", author: "ZEIT",
                                artworkURL: nil, feedURL: "https://other.example/spezial"),
            PodcastSearchResult(title: "Ganz anderer Podcast", author: nil,
                                artworkURL: nil, feedURL: "https://c.example/feed"),
        ]
        let out = PodcastRecommendationsStore.excludingSubscribed(
            pool,
            subscribedNormalizedFeeds: [PodcastSubscriptions.normalizeFeedURL(
                "https://zeit.de/podcasts/servus-gruezi-hallo/rss-podcatcher?freebie=X")],
            subscribedTitles: ["Servus. Grüezi. Hallo."])
        // Both spellings of the same show drop (diacritics folded)…
        #expect(!out.contains { $0.feedURL.contains("simplecast") })
        #expect(!out.contains { $0.feedURL.contains("sgh2") })
        // …while a SIMILAR but different title survives (no substring match).
        #expect(out.map(\.title) == ["Servus. Grüezi. Hallo. Spezial", "Ganz anderer Podcast"])
    }

    @Test("without titles the behaviour is exactly as before")
    func titlesAreOptional() {
        let pool = [PodcastSearchResult(title: "X", author: nil, artworkURL: nil,
                                        feedURL: "https://x.example/feed")]
        #expect(PodcastRecommendationsStore.excludingSubscribed(
            pool, subscribedNormalizedFeeds: []).count == 1)
    }
}

/// The author portrait's tap rule. Several works ⇒ tappable filter, a
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
        // Share cap: max limit/5 = 2 of 10. Books are never displaced.
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

    @Test("49dc2c3: unknown last listen means DORMANT, never excluded; proven pauses rank first")
    func dormantUnknownJoins() {
        let now = Date(timeIntervalSince1970: 100 * 24 * 3600)
        let fresh = now.timeIntervalSince1970 - 2 * 24 * 3600     // heard recently
        let old = now.timeIntervalSince1970 - 35 * 24 * 3600      // 5 weeks ago
        // matrix: (a) freshly heard, (b) long ago, (c) never logged,
        // (d) backfill-stamped ⇒ reaches picks() as unknown, like (c).
        let picks = RediscoverSections.picks(
            paused: [], unheard: [], seriesNext: [],
            showsDormant: [(id: "a-fresh", lastPlayed: fresh),
                           (id: "b-old", lastPlayed: old),
                           (id: "c-never", lastPlayed: nil),
                           (id: "d-backfill", lastPlayed: nil)],
            // limit 20 ⇒ share cap 4, so the cap is not what this test measures.
            now: now, daySeed: 5, limit: 20)
        #expect(!picks.contains { $0.id == "a-fresh" })
        #expect(Set(picks.map(\.id)) == ["b-old", "c-never", "d-backfill"])
        // Proven pause before never-observed.
        #expect(picks.first?.id == "b-old")
        #expect(picks.first?.reason == .showDormant(weeks: 5))
        // The unknown ones carry no invented week count.
        #expect(picks.dropFirst().allSatisfy { $0.reason == .showDormantUnknown })
    }

    @Test("49dc2c3: unknown shows count against the SAME share cap")
    func unknownSharesTheCap() {
        let now = Date(timeIntervalSince1970: 100 * 24 * 3600)
        let old = now.timeIntervalSince1970 - 30 * 24 * 3600
        let picks = RediscoverSections.picks(
            paused: (0..<10).map { (id: "book-\($0)", lastPlayed: old) },
            unheard: [], seriesNext: [],
            showsDormant: (0..<8).map { (id: "show-\($0)", lastPlayed: nil) },
            now: now, daySeed: 42, limit: 10)
        let showPicks = picks.filter { $0.reason == .showDormantUnknown }
        #expect(showPicks.count == RediscoverSections.showCap(limit: 10))
        // Books keep their places. The new source never displaces them.
        #expect(picks.count == 10)
    }
}

/// The categories must reach the QUERY. Compound Apple
/// names decompose for PodcastIndex, and map to genre ids for the keyless
/// iTunes charts.
struct PodcastCategoryMappingTests {
    @Test("compound Apple names split into the separate PodcastIndex categories")
    func compoundSplit() {
        // The measured bug: "Society & Culture" does not exist in PI.
        #expect(PodcastCategoryMapping.podcastIndexCategories(for: ["Society & Culture"])
                == ["Society", "Culture"])
        #expect(PodcastCategoryMapping.podcastIndexCategories(for: ["Health & Fitness"])
                == ["Health", "Fitness"])
        // Order kept, duplicates dropped across categories.
        #expect(PodcastCategoryMapping.podcastIndexCategories(
            for: ["History", "Society & Culture", "History"]) == ["History", "Society", "Culture"])
        // "and" spelling and stray whitespace still map.
        #expect(PodcastCategoryMapping.podcastIndexCategories(for: [" Society and Culture "])
                == ["Society", "Culture"])
    }

    @Test("unknown categories yield nothing — no guessing")
    func conservative() {
        #expect(PodcastCategoryMapping.podcastIndexCategories(for: ["Völlig Unbekannt"]).isEmpty)
        #expect(PodcastCategoryMapping.itunesGenreIds(for: ["Völlig Unbekannt"]).isEmpty)
        #expect(PodcastCategoryMapping.podcastIndexCategories(for: []).isEmpty)
    }

    @Test("genre ids for the keyless branch, and the reverse lookup for the reason")
    func genreIds() {
        #expect(PodcastCategoryMapping.itunesGenreIds(for: ["History", "Fiction"]) == [1487, 1483])
        #expect(PodcastCategoryMapping.itunesGenreIds(for: ["Society & Culture"]) == [1324])
        // Duplicates collapse (two categories, one chart).
        #expect(PodcastCategoryMapping.itunesGenreIds(for: ["History", "History"]) == [1487])
        // The reason names the category a hit actually came from.
        #expect(PodcastCategoryMapping.appleCategory(forGenreId: 1487) == "history")
        #expect(PodcastCategoryMapping.appleCategory(forGenreId: 999_999) == nil)
    }

    /// The header caption names only what DEVIATES from the default.
    /// That is what makes an invisible filter visible without shouting.
    @Test("Sort indicator names only deviations")
    func sortIndicatorSummary() {
        #expect(SortIndicator.summary([nil, nil]) == nil)
        #expect(SortIndicator.summary([]) == nil)
        // An empty string is not a deviation either.
        #expect(SortIndicator.summary([""]) == nil)
        #expect(SortIndicator.summary(["Titel A–Z", nil]) == "Titel A–Z")
        #expect(SortIndicator.summary(["Titel A–Z", "Ungehörte"]) == "Titel A–Z · Ungehörte")

        #expect(SortIndicator.part("X", ifNot: true) == nil)
        #expect(SortIndicator.part("X", ifNot: false) == "X")
    }

    /// Hiding a title from Continue must not touch its position.
    /// And must not banish it forever either. The marker holds the progress
    /// stamp at the moment of hiding, so listening on brings the entry back.
    @Test("Continue-hide marker releases as soon as progress moves on")
    func continueHiddenMarker() {
        var markers: [String: Double] = [:]
        #expect(!ContinueHidden.isHidden(id: "b1", lastUpdate: 1_700_000_000, markers: markers))

        markers = ContinueHidden.hiding(id: "b1", lastUpdate: 1_700_000_000, in: markers)
        #expect(ContinueHidden.isHidden(id: "b1", lastUpdate: 1_700_000_000, markers: markers))
        // Same position, restart: still hidden (it survives).
        #expect(ContinueHidden.isHidden(id: "b1", lastUpdate: 1_699_999_000, markers: markers))
        // Listened on → back on its own.
        #expect(!ContinueHidden.isHidden(id: "b1", lastUpdate: 1_700_000_001, markers: markers))
        // Milliseconds (ABS) are normalised, not misread as the far future.
        #expect(ContinueHidden.isHidden(id: "b1", lastUpdate: 1_700_000_000_000, markers: markers))

        // Untouched ids stay untouched.
        #expect(!ContinueHidden.isHidden(id: "other", lastUpdate: 0, markers: markers))

        // Pruning drops what has moved on, keeps the unknown.
        let pruned = ContinueHidden.pruned(markers, progress: ["b1": 1_700_000_500])
        #expect(pruned["b1"] == nil)
        #expect(ContinueHidden.pruned(markers, progress: [:])["b1"] != nil)
    }

    /// Device finding: Gutenberg tiles had no covers. The url was in
    /// the Gutendex answer all along. Measured before the fix: 32/32 entries
    /// carry image/jpeg, and the urls answer 200.
    @Test("Gutenberg cover comes out of the formats map")
    func gutenbergCover() {
        let real = ["audio/mpeg": "https://x/a.mp3",
                    "image/jpeg": "https://www.gutenberg.org/cache/epub/26471/pg26471.cover.medium.jpg"]
        #expect(FreeCatalog.gutenbergCoverURL(formats: real)?.absoluteString.hasSuffix("medium.jpg") == true)
        // png as the fallback key
        #expect(FreeCatalog.gutenbergCoverURL(formats: ["image/png": "https://x/c.png"]) != nil)
        // No image, no url, no guessing.
        #expect(FreeCatalog.gutenbergCoverURL(formats: ["audio/mpeg": "https://x/a.mp3"]) == nil)
        #expect(FreeCatalog.gutenbergCoverURL(formats: nil) == nil)
        // Plain http is not accepted (ATS would block it anyway. Silently).
        #expect(FreeCatalog.gutenbergCoverURL(formats: ["image/jpeg": "http://x/c.jpg"]) == nil)
    }

    @Test("6fcb301: one cap for every preview row, chevron only when there is more")
    func rowPreview() {
        #expect(RowPreview.limit == 12)
        // The cut never grows the collection and never exceeds the cap.
        #expect(RowPreview.cut(Array(1...50)).count == 12)
        #expect(RowPreview.cut(Array(1...5)).count == 5)
        #expect(RowPreview.cut([Int]()).isEmpty)
        // A chevron only where something is hidden.
        #expect(RowPreview.showsChevron(total: 13))
        #expect(!RowPreview.showsChevron(total: 12))
        #expect(!RowPreview.showsChevron(total: 3))
        #expect(!RowPreview.showsChevron(total: 0))
        // Rows with their own cap pass it (radio recents ring = 8).
        #expect(!RowPreview.showsChevron(total: 8, shown: 8))
        #expect(RowPreview.showsChevron(total: 9, shown: 8))
    }

    @Test("757e2eb: a language spans several storefronts, primary always first")
    func storefronts() {
        // English deviates by up to 56 % between US and NZ. Asking only the
        // US chart hid that half.
        let en = SuggestionLanguages.storefronts(for: "en", perRun: 2, daySeed: 20_260_805,
                                                 deviceRegion: "DE")
        #expect(en.count == 2)
        #expect(en[0] == "us")                       // primary market leads
        #expect(en[1] != "us")                       // plus a rotating one
        #expect(SuggestionLanguages.storefrontsByLanguage["en"]?.contains(en[1]) == true)

        // The rotation moves with the day, so the variety arrives over the week…
        let other = SuggestionLanguages.storefronts(for: "en", perRun: 2, daySeed: 20_260_806,
                                                    deviceRegion: "DE")
        #expect(other[0] == "us")
        #expect(other[1] != en[1])
        // …and the same day always yields the same request set.
        #expect(SuggestionLanguages.storefronts(for: "en", perRun: 2, daySeed: 20_260_805,
                                                deviceRegion: "DE") == en)

        // A language with ONE market behaves exactly as before.
        #expect(SuggestionLanguages.storefronts(for: "ja", perRun: 3, deviceRegion: "DE") == ["jp"])
        // perRun 1 = the old behaviour, no extra requests.
        #expect(SuggestionLanguages.storefronts(for: "en", perRun: 1, deviceRegion: "DE") == ["us"])
        // More requested than available cannot duplicate entries.
        let all = SuggestionLanguages.storefronts(for: "pt", perRun: 9, daySeed: 1, deviceRegion: "DE")
        #expect(Set(all).count == all.count)
        #expect(all.first == "pt")
    }

    @Test("8f0fc27/4ab17e8: the DEVICE REGION leads — priority, not exclusivity")
    func deviceRegionLeads() {
        // The case: Swiss device, German suggestions. The Swiss chart
        // deviates from the German one by 58 % and carries "Schreckmümpfeli";
        // it must lead instead of being a rotating afterthought.
        let de = SuggestionLanguages.storefronts(for: "de", perRun: 2, daySeed: 20_260_805,
                                                 deviceRegion: "CH")
        #expect(de.first == "ch")
        // …but Germany still appears. Priority, not exclusivity.
        #expect(de.count == 2)
        #expect(de.contains("de") || de.contains("at"))

        // French on the same device: Switzerland leads there too.
        #expect(SuggestionLanguages.storefronts(for: "fr", perRun: 2, daySeed: 1,
                                                deviceRegion: "CH").first == "ch")
        // A region the language does not serve changes nothing.
        #expect(SuggestionLanguages.storefronts(for: "de", perRun: 2, daySeed: 1,
                                                deviceRegion: "JP").first == "de")
        #expect(SuggestionLanguages.storefronts(for: "de", perRun: 2, daySeed: 1,
                                                deviceRegion: nil).first == "de")
        // The measured lists themselves.
        #expect(SuggestionLanguages.storefrontsByLanguage["es"] == ["es", "mx", "ar", "co", "cl"])
        #expect(SuggestionLanguages.storefrontsByLanguage["fr"] == ["fr", "be", "ch", "ca"])
    }

    @Test("the cap belongs AFTER the mapping — dead compounds must not eat slots")
    func capAfterMapping() {
        // Three compound categories used to occupy three slots and match
        // nothing; mapped first, they produce six usable terms.
        let raw = ["Society & Culture", "Health & Fitness", "TV & Film"]
        let mapped = PodcastCategoryMapping.podcastIndexCategories(for: raw)
        #expect(mapped.count == 6)
        #expect(Array(mapped.prefix(3)) == ["Society", "Culture", "Health"])
    }

    /// The chart share rotates daily THROUGH ITS OWN SLOTS. The
    /// personally justified entries keep their signal order and positions.
    @Test("chart entries rotate daily, personal entries keep their slots")
    func chartRotationKeepsPersonalSlots() {
        func r(_ id: String) -> PodcastSearchResult {
            PodcastSearchResult(title: id, author: nil, artworkURL: nil, feedURL: "https://\(id)")
        }
        // Slots: personal `P1` at 0, charts at 1/2/4, personal `P2` at 3.
        let list = [r("P1"), r("C1"), r("C2"), r("P2"), r("C3")]
        let isChart: (PodcastSearchResult) -> Bool = { $0.title.hasPrefix("C") }
        let day0 = PodcastRecommendationsStore.rotatingCharts(list, isChart: isChart, daySeed: 0)
        #expect(day0.map(\.title) == ["P1", "C1", "C2", "P2", "C3"])
        let day1 = PodcastRecommendationsStore.rotatingCharts(list, isChart: isChart, daySeed: 1)
        #expect(day1.map(\.title) == ["P1", "C2", "C3", "P2", "C1"])
        // Personal entries never move, whatever the day says.
        for day in 0..<7 {
            let rotated = PodcastRecommendationsStore.rotatingCharts(list, isChart: isChart, daySeed: day)
            #expect(rotated[0].title == "P1")
            #expect(rotated[3].title == "P2")
        }
        // One chart entry (or none): nothing to rotate.
        #expect(PodcastRecommendationsStore.rotatingCharts([r("P1"), r("C1")], isChart: isChart, daySeed: 3)
            .map(\.title) == ["P1", "C1"])
    }
}
#endif
