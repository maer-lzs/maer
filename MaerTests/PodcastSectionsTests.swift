// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// The one-pass `PodcastSections.compute` must produce exactly
/// what the former three separate passes produced, for arbitrary play/download
/// state.
@MainActor
struct PodcastSectionsTests {

    // MARK: - Fixtures

    private func show(_ id: String, episodes: [PodcastEpisode]) -> PodcastShow {
        PodcastShow(id: id, title: "Show \(id)", author: nil, artworkURL: nil,
                    description: nil, feedURL: "https://example.com/\(id)", episodes: episodes)
    }

    private func episode(_ guid: String, pubDate: Double) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: "Ep \(guid)", audioURL: "https://example.com/\(guid).mp3",
                       pubDate: pubDate, duration: 600, description: nil, imageURL: nil, chaptersURL: nil)
    }

    /// Deterministic state world: guid → state, guid → last-played timestamp.
    private struct World {
        var states: [String: EpisodePlayState] = [:]
        var lastPlayed: [String: Double] = [:]
        var downloaded: Set<String> = []
        var inboxOff: Set<String> = []

        func state(_ item: LibraryItem) -> EpisodePlayState { states[item.id] ?? .unplayed }
        func ts(_ id: String) -> Double { lastPlayed[id] ?? 0 }
    }

    /// The FORMER three-pass logic, replicated as the reference oracle.
    private func referenceSections(shows: [PodcastShow], world: World) -> PodcastSectionsResult {
        // Pass 1: nextUp (in-progress by last played; 200 = sanity bound).
        var picks: [(item: LibraryItem, playedAt: Double)] = []
        for show in shows {
            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                guard case .inProgress = world.state(item) else { continue }
                picks.append((item, world.ts(item.id)))
            }
        }
        let nextUp = picks.sorted { $0.playedAt > $1.playedAt }.prefix(200).map(\.item)

        // Pass 2: recently updated with new-episode count.
        var infos: [RecentShowInfo] = []
        for show in shows {
            if world.inboxOff.contains(show.id) { continue }
            guard let newest = show.episodes.map(\.pubDate).max(), newest > 0 else { continue }
            let items = show.episodes.map { podcastLibraryItem(show: show, episode: $0) }
            let lastPlayed = items
                .filter { world.state($0) == .played }
                .map { $0.addedAt ?? 0 }
                .max()
            let newCount: Int
            if let lastPlayed {
                newCount = items.filter { ($0.addedAt ?? 0) > lastPlayed && world.state($0) == .unplayed }.count
            } else {
                newCount = items.filter { world.state($0) == .unplayed }.count
            }
            infos.append(RecentShowInfo(show: show, lastUpdated: newest, newCount: newCount))
        }
        let recent = infos.sorted { $0.lastUpdated > $1.lastUpdated }

        // Pass 3: downloaded, newest first.
        let downloaded = shows
            .flatMap { show in show.episodes.map { podcastLibraryItem(show: show, episode: $0) } }
            .filter { world.downloaded.contains($0.id) }
            .sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }

        return PodcastSectionsResult(nextUp: Array(nextUp), recentShows: recent, downloaded: downloaded)
    }

    private func compute(shows: [PodcastShow], world: World) -> PodcastSectionsResult {
        PodcastSections.compute(
            shows: shows,
            downloadedIds: world.downloaded,
            inboxOff: { world.inboxOff.contains($0) },
            playState: { world.state($0) },
            lastPlayed: { world.ts($0) }
        )
    }

    private func expectEqual(_ a: PodcastSectionsResult, _ b: PodcastSectionsResult) {
        #expect(a.nextUp.map(\.id) == b.nextUp.map(\.id))
        #expect(a.recentShows.map(\.id) == b.recentShows.map(\.id))
        #expect(a.recentShows.map(\.newCount) == b.recentShows.map(\.newCount))
        #expect(a.recentShows.map(\.lastUpdated) == b.recentShows.map(\.lastUpdated))
        #expect(a.downloaded.map(\.id) == b.downloaded.map(\.id))
    }

    // MARK: - Tests

    @Test func matchesThreePassReferenceOnMixedFixture() {
        let shows = [
            show("s1", episodes: [episode("s1e1", pubDate: 100), episode("s1e2", pubDate: 300),
                                  episode("s1e3", pubDate: 200)]),
            show("s2", episodes: [episode("s2e1", pubDate: 500), episode("s2e2", pubDate: 400)]),
            show("s3", episodes: [episode("s3e1", pubDate: 250)]),
        ]
        var world = World()
        world.states = [
            "s1e1": .played,
            "s1e2": .unplayed,
            "s1e3": .inProgress(fraction: 0.5, remaining: 300),
            "s2e1": .inProgress(fraction: 0.2, remaining: 480),
            "s2e2": .played,
            "s3e1": .unplayed,
        ]
        world.lastPlayed = ["s1e3": 1000, "s2e1": 2000]
        world.downloaded = ["s1e2", "s2e2"]

        expectEqual(compute(shows: shows, world: world), referenceSections(shows: shows, world: world))
    }

    @Test func matchesReferenceWithInboxOffAndNoPlays() {
        let shows = [
            show("a", episodes: [episode("ae1", pubDate: 10), episode("ae2", pubDate: 20)]),
            show("b", episodes: [episode("be1", pubDate: 30)]),
        ]
        var world = World()
        world.inboxOff = ["a"]
        expectEqual(compute(shows: shows, world: world), referenceSections(shows: shows, world: world))
    }

    @Test func semanticSpotChecks() {
        let shows = [
            show("s1", episodes: [episode("s1e1", pubDate: 100), episode("s1e2", pubDate: 300),
                                  episode("s1e3", pubDate: 200)]),
            show("s2", episodes: [episode("s2e1", pubDate: 500)]),
        ]
        var world = World()
        world.states = [
            "s1e1": .played,                                    // played at pubDate 100
            "s1e2": .unplayed,                                  // newer than last played → counts
            "s1e3": .inProgress(fraction: 0.1, remaining: 540), // in progress → not "new"
            "s2e1": .unplayed,                                  // no played episode → counts
        ]
        world.lastPlayed = ["s1e3": 42]
        world.downloaded = ["s1e1", "s1e2"]

        let result = compute(shows: shows, world: world)
        #expect(result.nextUp.map(\.id) == ["s1e3"])
        // s2 (newest 500) before s1 (newest 300); newCounts 1 and 1.
        #expect(result.recentShows.map(\.id) == ["s2", "s1"])
        #expect(result.recentShows.map(\.newCount) == [1, 1])
        // Downloaded newest first: s1e2 (300) before s1e1 (100).
        #expect(result.downloaded.map(\.id) == ["s1e2", "s1e1"])
    }

    @Test("S2: snapshot-based off-main compute equals the closure-based compute")
    func snapshotComputeMatchesClosureCompute() async {
        let shows = [
            show("s1", episodes: [episode("s1e1", pubDate: 100), episode("s1e2", pubDate: 300),
                                  episode("s1e3", pubDate: 200)]),
            show("s2", episodes: [episode("s2e1", pubDate: 500)]),
        ]
        // Snapshot world: s1e1 played (sentinel), s1e3 in progress (position),
        // s2e1 served-played via the ABS bridge.
        let snapshot = PodcastSections.StateSnapshot(
            positions: [
                "s1e1": [PodcastProgressStore.playedSentinel, 1000],
                "s1e3": [120, 2000],
            ],
            serverProgress: ["abspod:x:1": BookProgress(fraction: 1, isFinished: true, lastUpdate: 3000)],
            equivalents: ["s2e1": ["s2e1", "abspod:x:1"]],
            downloadedIds: ["s1e2"],
            inboxOff: []
        )
        let detached = await PodcastSections.computeDetached(shows: shows, snapshot: snapshot)
        let direct = PodcastSections.compute(
            shows: shows,
            downloadedIds: snapshot.downloadedIds,
            inboxOff: { snapshot.inboxOff.contains($0) },
            playState: { PodcastSections.state(guid: $0.id, duration: $0.media?.duration ?? 0, snapshot: snapshot) },
            lastPlayed: { PodcastSections.lastPlayed(id: $0, snapshot: snapshot) }
        )
        #expect(detached.nextUp.map(\.id) == direct.nextUp.map(\.id))
        #expect(detached.recentShows.map(\.id) == direct.recentShows.map(\.id))
        #expect(detached.recentShows.map(\.newCount) == direct.recentShows.map(\.newCount))
        #expect(detached.downloaded.map(\.id) == direct.downloaded.map(\.id))
        // Semantic spot checks on the snapshot state derivation itself.
        #expect(PodcastSections.state(guid: "s1e1", duration: 600, snapshot: snapshot) == .played)
        #expect(PodcastSections.state(guid: "s2e1", duration: 600, snapshot: snapshot) == .played)
        if case .inProgress = PodcastSections.state(guid: "s1e3", duration: 600, snapshot: snapshot) {} else {
            Issue.record("s1e3 must be in progress")
        }
        #expect(detached.nextUp.map(\.id) == ["s1e3"])
    }

    /// Welle 3 / C-Lehre: the SOURCE no longer culls (the row previews via
    /// RowPreview, the page shows the full stock). 200 is a sanity bound,
    /// not a curation. This test used to pin the old 10-cap.
    @Test func nextUpKeepsFullStock() {
        let episodes = (1...15).map { episode("e\($0)", pubDate: Double($0)) }
        let shows = [show("s", episodes: episodes)]
        var world = World()
        for i in 1...15 {
            world.states["e\(i)"] = .inProgress(fraction: 0.5, remaining: 10)
            world.lastPlayed["e\(i)"] = Double(i)
        }
        let result = compute(shows: shows, world: world)
        #expect(result.nextUp.count == 15)
        // Most recently played first.
        #expect(result.nextUp.first?.id == "e15")
        expectEqual(result, referenceSections(shows: shows, world: world))
    }

    // MARK: - Teil 2: grid sort + filter

    @Test("Paket B: gespiegelte Shows wandern in die Gruppe, nicht ins Abo-Raster")
    func mirroredShowsSplitIntoTheirGroup() {
        var mirrored = show("m1", episodes: [episode("m1e1", pubDate: 100)])
        mirrored.origin = "pinchflat:tube.example"
        var mirrored2 = show("m2", episodes: [episode("m2e1", pubDate: 300)])
        mirrored2.origin = "pinchflat:tube.example"
        let regular = show("r1", episodes: [episode("r1e1", pubDate: 200)])
        let world = World()
        let result = PodcastSections.compute(
            shows: [mirrored, regular, mirrored2],
            downloadedIds: world.downloaded,
            inboxOff: { world.inboxOff.contains($0) },
            playState: { world.state($0) },
            lastPlayed: { world.ts($0) })
        // The group is the mirrored shows' row. The general grid never
        // doubles them; the group sorts newest first.
        #expect(result.recentShows.map(\.show.id) == ["r1"])
        #expect(result.mirroredShows.map(\.show.id) == ["m2", "m1"])
    }

    @Test("5abb1e9-Kuer: Kapsel-Kennung — mirroredEpisodeGuids und Item-Id sind DIESELBE Kette")
    func capsuleIdsMatchThroughTheRealChain() {
        var mirrored = show("m1", episodes: [episode("rss:m1:e1", pubDate: 100)])
        mirrored.origin = "pinchflat:tube.example"
        // The host set and the tile's item id both come from the SAME
        // episodes array. The guid IS the LibraryItem id.
        let guids = Set(mirrored.episodes.map(\.guid))
        let item = podcastLibraryItem(show: mirrored, episode: mirrored.episodes[0])
        #expect(guids.contains(item.id))
    }

    @Test("Teil 2: arrange sorts by recency / name / unplayed and filters")
    func arrangeSortsAndFilters() {
        // Titles are "Show a/b/c" (fixture); ids are a/b/c.
        let a = RecentShowInfo(show: show("a", episodes: []), lastUpdated: 100, newCount: 1,
                               hasDownloads: true, unplayedCount: 5)
        let b = RecentShowInfo(show: show("b", episodes: []), lastUpdated: 300, newCount: 0,
                               hasDownloads: false, unplayedCount: 0)
        let c = RecentShowInfo(show: show("c", episodes: []), lastUpdated: 200, newCount: 2,
                               hasDownloads: true, unplayedCount: 2)
        let infos = [a, b, c]
        // Recently updated (default): lastUpdated desc → b, c, a.
        #expect(PodcastSections.arrange(infos, sort: .zuletztAktualisiert, filter: .alle).map(\.id) == ["b", "c", "a"])
        // Name A–Z: "Show a/b/c" → a, b, c.
        #expect(PodcastSections.arrange(infos, sort: .nameAZ, filter: .alle).map(\.id) == ["a", "b", "c"])
        // Most unplayed: 5, 2, 0 → a, c, b.
        #expect(PodcastSections.arrange(infos, sort: .meisteUngespielte, filter: .alle).map(\.id) == ["a", "c", "b"])
        // Filter with downloads → a, c (b has none).
        #expect(Set(PodcastSections.arrange(infos, sort: .zuletztAktualisiert, filter: .mitDownloads).map(\.id)) == ["a", "c"])
        // Filter with unplayed → a, c (b has 0).
        #expect(Set(PodcastSections.arrange(infos, sort: .zuletztAktualisiert, filter: .mitUngespielten).map(\.id)) == ["a", "c"])
    }

    @Test("Teil 2: compute derives unplayedCount from the play-state snapshot")
    func computeDerivesUnplayedCount() {
        // show a: 2 episodes both unplayed; show b: 1 played.
        let shows = [
            show("a", episodes: [episode("a1", pubDate: 100), episode("a2", pubDate: 200)]),
            show("b", episodes: [episode("b1", pubDate: 300)]),
        ]
        var world = World()
        world.states = ["b1": .played]   // a1/a2 default .unplayed
        let result = PodcastSections.compute(
            shows: shows, downloadedIds: world.downloaded,
            inboxOff: { world.inboxOff.contains($0) },
            playState: { world.state($0) }, lastPlayed: { world.ts($0) },
            sort: .meisteUngespielte, filter: .alle
        )
        // a (2 unplayed) sorts before b (0 unplayed).
        #expect(result.recentShows.map(\.id) == ["a", "b"])
        #expect(result.recentShows.first { $0.id == "a" }?.unplayedCount == 2)
        #expect(result.recentShows.first { $0.id == "b" }?.unplayedCount == 0)
    }

    /// Newest episode of EACH show (one per show. A daily show never
    /// dominates), newest first, capped.
    @Test("newestPerShow picks one per show, newest first, capped")
    func newestPerShow() {
        let shows = [
            show("daily", episodes: [episode("d1", pubDate: 100), episode("d2", pubDate: 400),
                                     episode("d3", pubDate: 300)]),
            show("weekly", episodes: [episode("w1", pubDate: 200)]),
            show("empty", episodes: []),
            show("old", episodes: [episode("o1", pubDate: 50)]),
        ]
        #expect(PodcastSections.newestPerShow(shows: shows) == ["d2", "w1", "o1"])
        #expect(PodcastSections.newestPerShow(shows: shows, limit: 2) == ["d2", "w1"])
    }
}
#endif

// MARK: - Spiegel seeden nicht, tote Kacheln ruecken nach

struct RecommendationSeedTests {
    private func result(_ id: String, artwork: String?) -> PodcastSearchResult {
        PodcastSearchResult(title: id, author: nil, artworkURL: artwork,
                            feedURL: "https://x.example/\(id).xml")
    }

    @Test("Umordnen statt Wegwerfen — ein flaechiger Ausfall kostet Ordnung, nicht Inhalt")
    func reorderingNeverDrops() async {
        // Keine Artwork-URL ⇒ nachgereiht; nichts verschwindet.
        let entries = [result("a", artwork: nil), result("b", artwork: nil)]
        let out = await PodcastRecommendationsStore.preferLoadableArtwork(entries, shown: 6)
        #expect(out.count == entries.count)
        #expect(Set(out.map(\.id)) == Set(entries.map(\.id)))
    }

    @Test("nicht geprobte Kandidaten bleiben in ihrer Reihenfolge hinten dran")
    func unprobedKeepTheirOrder() async {
        let entries = (1...20).map { result("e\($0)", artwork: nil) }
        let out = await PodcastRecommendationsStore.preferLoadableArtwork(entries, shown: 2)
        #expect(out.count == 20)
        // Der Schwanz (nie geprobt) behaelt seine Ordnung.
        #expect(out.suffix(5).map(\.id) == entries.suffix(5).map(\.id))
    }
}

/// The Empfohlen fix. REAL author equality, and the fences carry
/// the measured cases verbatim (the "Einschlafen" anchor booked 25/25
/// foreign shows as sameAuthor through the old title branch).
@Suite struct RecommendationAuthorMatchTests {

    /// The title branch is GONE: a title carrying the anchor word proves
    /// nothing about authorship.
    @Test("Einschlafen-Anker bucht 0 fremde Autoren als sameAuthor")
    func titleWordsAreNoAuthors() {
        for foreign in ["Toby Baier", "Jan Lindner", "Wikipedia & Schønlein Media",
                        "Understood.org, Laura Key", "SWR",
                        "Frankfurter Allgemeine Zeitung"] {
            #expect(!PodcastRecommendationsStore.sameAuthor(foreign, anchor: "Einschlafen"),
                    "\(foreign) ist nicht der Autor 'Einschlafen'")
        }
        #expect(!PodcastRecommendationsStore.sameAuthor("ZDFde", anchor: "heute"))
    }

    /// The direction hole is gone: a candidate author that merely CONTAINS
    /// the anchor (or vice versa) is a different house.
    @Test("Sport bucht weder Barstool noch FOX")
    func substringsAreNoAuthors() {
        #expect(!PodcastRecommendationsStore.sameAuthor("Barstool Sports", anchor: "Sport"))
        #expect(!PodcastRecommendationsStore.sameAuthor("FOX Sports", anchor: "Sport"))
        #expect(!PodcastRecommendationsStore.sameAuthor("DIE ZEIT", anchor: "ZEIT WISSEN"))
    }

    /// Real matches stay: folded equality is case-, diacritic- and
    /// punctuation-blind, never word-blind.
    @Test("echte ZEIT-Shows bleiben")
    func realAuthorsStillMatch() {
        #expect(PodcastRecommendationsStore.sameAuthor("DIE ZEIT", anchor: "DIE ZEIT"))
        #expect(PodcastRecommendationsStore.sameAuthor("Die  Zeit", anchor: "DIE ZEIT"))
        #expect(PodcastRecommendationsStore.sameAuthor("ZEIT ONLINE", anchor: "zeit online"))
        #expect(!PodcastRecommendationsStore.sameAuthor(nil, anchor: "DIE ZEIT"))
    }
}

/// Authors/publishers first (up to ~half, at most 2 per author,
/// row-wide), category then charts as the guaranteed filler. The row never
/// shrinks, the cap orders and never empties.
@Suite struct RecommendationPriorityTests {
    private func r(_ id: String, author: String?) -> PodcastSearchResult {
        PodcastSearchResult(title: id, author: author, artworkURL: nil,
                            feedURL: "https://x.example/\(id).xml")
    }
    private func reasons(_ map: [String: PodcastRecommendationsStore.Reason])
        -> (PodcastSearchResult) -> PodcastRecommendationsStore.Reason {
        { map[$0.title] ?? .popular }
    }

    @Test("Autoren zuerst bis zur Hälfte, Kategorie dann Charts dahinter")
    func authorsLeadThenCategoryThenCharts() {
        let list = [r("c1", author: nil), r("g1", author: "G"),
                    r("a1", author: "ZEIT"), r("a2", author: "NDR"),
                    r("c2", author: nil), r("g2", author: "H")]
        let out = PodcastRecommendationsStore.composePriority(
            list, reason: reasons(["a1": .sameAuthor("ZEIT", likeShow: nil), "a2": .sameAuthor("NDR", likeShow: nil),
                                   "g1": .genre("History"), "g2": .genre("History")]),
            limit: 6)
        #expect(out.map(\.title) == ["a1", "a2", "g1", "g2", "c1", "c2"])
    }

    @Test("max 2 je Autor — reihenweit, auch über die Kategorie-Karten")
    func perAuthorCapIsRowWide() {
        let list = [r("a1", author: "ZEIT"), r("a2", author: "ZEIT"),
                    r("a3", author: "ZEIT"), r("g1", author: "ZEIT"),
                    r("g2", author: "Other"), r("c1", author: nil)]
        let out = PodcastRecommendationsStore.composePriority(
            list, reason: reasons(["a1": .sameAuthor("ZEIT", likeShow: nil), "a2": .sameAuthor("ZEIT", likeShow: nil),
                                   "a3": .sameAuthor("ZEIT", likeShow: nil),
                                   "g1": .genre("News"), "g2": .genre("News")]),
            limit: 5)
        // Third ZEIT author card AND the ZEIT category card yield to others…
        #expect(out.prefix(4).map(\.title) == ["a1", "a2", "g2", "c1"])
        // …but the row still fills to its length (cap orders, never empties).
        #expect(out.count == 5)
    }

    @Test("der Autoren-Anteil zählt die REIHE, nicht die geordnete Liste")
    func authorShareCountsTheRowNotTheList() {
        // Sechs Autor-Karten, aber die Reihe zeigt nur sechs von zwölf
        // Einträgen: die halbe REIHE sind drei Plätze, nicht sechs.
        let authors = (1...6).map { r("a\($0)", author: "Verlag \(($0 + 1) / 2)") }
        let rest = (1...6).map { r("c\($0)", author: nil) }
        var map: [String: PodcastRecommendationsStore.Reason] = [:]
        for (index, entry) in authors.enumerated() {
            map[entry.title] = .sameAuthor("Verlag \((index + 2) / 2)", likeShow: nil)
        }
        let out = PodcastRecommendationsStore.composePriority(
            authors + rest, reason: reasons(map), limit: 12, rowLength: 6)
        // Drei Autor-Karten führen, dann kommt anderes; die restlichen
        // Autor-Karten fallen hinter die Füllung, statt die Reihe zu füllen.
        #expect(out.prefix(3).map(\.title) == ["a1", "a2", "a3"])
        #expect(out.prefix(6).filter { $0.title.hasPrefix("a") }.count == 3)
        // Die Liste bleibt vollständig: geordnet wird, nie verworfen.
        #expect(out.count == 12)
        // Ohne `rowLength` gilt die alte Lesart, Liste gleich Reihe.
        let whole = PodcastRecommendationsStore.composePriority(
            authors + rest, reason: reasons(map), limit: 12)
        #expect(whole.prefix(6).filter { $0.title.hasPrefix("a") }.count == 6)
    }

    @Test("dünner Autoren-Tag: die Reihe bleibt voll, Charts füllen auf")
    func thinAuthorDayKeepsRowLength() {
        let list = [r("a1", author: "ZEIT"), r("c1", author: nil),
                    r("c2", author: nil), r("c3", author: nil)]
        let out = PodcastRecommendationsStore.composePriority(
            list, reason: reasons(["a1": .sameAuthor("ZEIT", likeShow: nil)]), limit: 4)
        #expect(out.count == 4)
        #expect(out.first?.title == "a1")
    }

    /// Punkt 4 der Karte verlangt „Reihen mit benanntem Grund", und nennt
    /// ZWEI Wendungen: „Weil du … hoerst" und „Vom selben Verlag wie …".
    /// Die erste stand, die zweite nicht: der Grund kannte nur den Verlag,
    /// nicht die Sendung, aus der er stammt. Der Verlagsname allein sagt, WER
    /// es gemacht hat; die Sendung sagt, WARUM es hier steht.
    @Test("Kennt der Grund die eigene Sendung, nennt er sie")
    func thereasonNamesTheOwnShowWhenItKnowsIt() {
        let named = PodcastRecommendationsStore.reasonLine(
            .sameAuthor("ZEIT ONLINE", likeShow: "Alles gesagt?"))
        #expect(named.contains("Alles gesagt?"),
                "der Grund nennt die eigene Sendung nicht")
        #expect(!named.contains("ZEIT ONLINE"),
                "die Wendung mit der Sendung soll den Verlagsnamen ersetzen, nicht ergaenzen")
    }

    /// Gegenprobe, und sie ist der Grund fuer den Rueckfall: kommt der
    /// Spitzen-Autor aus einer mitgehoerten Sendung oder passt keine eigene
    /// Sendung genau, ist die Sendung unbekannt. Dann steht die aeltere
    /// Wendung, die wahr ist und weniger sagt, statt einer Zeile mit Luecke.
    @Test("Ohne bekannte eigene Sendung bleibt die aeltere Wendung")
    func withoutAKnownOwnShowTheOlderWordingStands() {
        let plain = PodcastRecommendationsStore.reasonLine(
            .sameAuthor("ZEIT ONLINE", likeShow: nil))
        #expect(plain.contains("ZEIT ONLINE"))
        #expect(!plain.isEmpty)
    }

    @Test("die Kategorie-Zeile klingt nie wie ein Autoren-Treffer")
    func categoryLineNeverSoundsLikeAnAuthorHit() {
        // The invariant of the reason line: it never lies, and a category
        // weight must be audibly distinct from an author hit. With one
        // shared wording, "History" read like a show named History.
        let author = PodcastRecommendationsStore.reasonLine(.sameAuthor("History", likeShow: nil))
        let genre = PodcastRecommendationsStore.reasonLine(.genre("History"))
        #expect(author != genre)
        let popular = PodcastRecommendationsStore.reasonLine(.popular)
        #expect(popular != author && popular != genre)
    }
}
