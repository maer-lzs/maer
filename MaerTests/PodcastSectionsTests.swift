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

    @Test("snapshot-based off-main compute equals the closure-based compute")
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

    /// Wave 3 / C lesson: the SOURCE no longer culls (the row previews via
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

    @Test("mirrored shows move into the group, not into the subscription grid")
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

    @Test("5abb1e9 free-skate: capsule identifier, mirroredEpisodeGuids and item id are the SAME chain")
    func capsuleIdsMatchThroughTheRealChain() {
        var mirrored = show("m1", episodes: [episode("rss:m1:e1", pubDate: 100)])
        mirrored.origin = "pinchflat:tube.example"
        // The host set and the tile's item id both come from the SAME
        // episodes array. The guid IS the LibraryItem id.
        let guids = Set(mirrored.episodes.map(\.guid))
        let item = podcastLibraryItem(show: mirrored, episode: mirrored.episodes[0])
        #expect(guids.contains(item.id))
    }

    @Test("compute derives unplayedCount from the play-state snapshot")
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

    // MARK: - The shared cases

    /// The cases live in `Fixtures/Shared/abos/show-order.json`, read by
    /// Swift and Kotlin alike: the show grid sorts by recency, name or
    /// unplayed count and filters, and `newestPerShow` takes ONE episode per
    /// show, newest first, capped. The name order names an umlaut case: the
    /// Swift side compares with `localizedCaseInsensitiveCompare`, the
    /// Kotlin side with a collator, and the file holds both to one order.
    nonisolated static let order = SharedCases.cases("show-order")

    private static let sorts: [String: PodcastSortOption] = [
        "zuletztAktualisiert": .zuletztAktualisiert, "nameAZ": .nameAZ, "meisteUngespielte": .meisteUngespielte,
    ]
    private static let filters: [String: PodcastFilterOption] = [
        "alle": .alle, "mitDownloads": .mitDownloads, "mitUngespielten": .mitUngespielten,
    ]

    /// A grid row as the file names it: id, title, lastUpdated, downloads, unplayed.
    private static func info(_ value: JSONValue) -> RecentShowInfo {
        let id = value["id"]?.string ?? ""
        let show = PodcastShow(id: id, title: value["title"]?.string ?? "", author: nil, artworkURL: nil,
                               description: nil, feedURL: "https://example.com/\(id)", episodes: [])
        return RecentShowInfo(show: show, lastUpdated: Double(value["lastUpdated"]?.int ?? 0), newCount: 0,
                              hasDownloads: value["hasDownloads"]?.bool ?? false,
                              unplayedCount: value["unplayedCount"]?.int ?? 0)
    }

    /// A show with its episodes as the file names them: guid and pubDate.
    private static func show(_ value: JSONValue) -> PodcastShow {
        let id = value["id"]?.string ?? ""
        let episodes = (value["episodes"]?.array ?? []).map { episode -> PodcastEpisode in
            let guid = episode["guid"]?.string ?? ""
            return PodcastEpisode(guid: guid, title: "Ep \(guid)", audioURL: "https://example.com/\(guid).mp3",
                                  pubDate: Double(episode["pubDate"]?.int ?? 0), duration: 600,
                                  description: nil, imageURL: nil, chaptersURL: nil)
        }
        return PodcastShow(id: id, title: "Show \(id)", author: nil, artworkURL: nil, description: nil,
                           feedURL: "https://example.com/\(id)", episodes: episodes)
    }

    @Test("shared cases: show-order carries eleven cases")
    func orderCasesLoaded() {
        #expect(Self.order.count == 11)
    }

    @Test("shared cases: the grid orders and filters per case as the file says, newestPerShow takes the newest per show", arguments: order)
    func theGridOrdersAsTheFileSays(_ c: SharedCase) throws {
        let input = try c.value("input")
        let shows = input["shows"]?.array ?? []
        let expect = try #require(c["expect"]?.strings)
        switch c.ask {
        case "arrange":
            let sort = try #require(Self.sorts[input["sort"]?.string ?? ""])
            let filter = try #require(Self.filters[input["filter"]?.string ?? ""])
            #expect(PodcastSections.arrange(shows.map(Self.info), sort: sort, filter: filter).map(\.id) == expect, "\(c.slug)")
        case "newestPerShow":
            let limit = input["limit"]?.int ?? 30
            #expect(PodcastSections.newestPerShow(shows: shows.map(Self.show), limit: limit) == expect, "\(c.slug)")
        default:
            Issue.record("\(c.slug): unknown ask \(c.ask)")
        }
    }
}
#endif

// MARK: - Mirrors do not seed, dead tiles move up

struct RecommendationSeedTests {
    private func result(_ id: String, artwork: String?) -> PodcastSearchResult {
        PodcastSearchResult(title: id, author: nil, artworkURL: artwork,
                            feedURL: "https://x.example/\(id).xml")
    }

    @Test("Reorder instead of discarding: a widespread outage costs order, not content")
    func reorderingNeverDrops() async {
        // No artwork URL ⇒ moved to the back; nothing disappears.
        let entries = [result("a", artwork: nil), result("b", artwork: nil)]
        let out = await PodcastRecommendationsStore.preferLoadableArtwork(entries, shown: 6)
        #expect(out.count == entries.count)
        #expect(Set(out.map(\.id)) == Set(entries.map(\.id)))
    }

    @Test("untested candidates stay at the back in their order")
    func unprobedKeepTheirOrder() async {
        let entries = (1...20).map { result("e\($0)", artwork: nil) }
        let out = await PodcastRecommendationsStore.preferLoadableArtwork(entries, shown: 2)
        #expect(out.count == 20)
        // The tail (never tested) keeps its order.
        #expect(out.suffix(5).map(\.id) == entries.suffix(5).map(\.id))
    }
}

/// The „Empfohlen" fix. REAL author equality, and the fences carry
/// the measured cases verbatim (the "Einschlafen" anchor booked 25/25
/// foreign shows as sameAuthor through the old title branch).
@Suite struct RecommendationAuthorMatchTests {

    /// The title branch is GONE: a title carrying the anchor word proves
    /// nothing about authorship.
    @Test("„Einschlafen“ anchor books 0 foreign authors as sameAuthor")
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
    @Test("Sport books neither Barstool nor FOX")
    func substringsAreNoAuthors() {
        #expect(!PodcastRecommendationsStore.sameAuthor("Barstool Sports", anchor: "Sport"))
        #expect(!PodcastRecommendationsStore.sameAuthor("FOX Sports", anchor: "Sport"))
        #expect(!PodcastRecommendationsStore.sameAuthor("DIE ZEIT", anchor: "ZEIT WISSEN"))
    }

    /// Real matches stay: folded equality is case-, diacritic- and
    /// punctuation-blind, never word-blind.
    @Test("real ZEIT shows stay")
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

    @Test("Authors first up to the half, category then charts behind")
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

    @Test("max 2 per author, row-wide, also across the category cards")
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

    @Test("the author share counts the ROW, not the ordered list")
    func authorShareCountsTheRowNotTheList() {
        // Six author cards, but the row shows only six of twelve
        // entries: half the ROW is three slots, not six.
        let authors = (1...6).map { r("a\($0)", author: "Verlag \(($0 + 1) / 2)") }
        let rest = (1...6).map { r("c\($0)", author: nil) }
        var map: [String: PodcastRecommendationsStore.Reason] = [:]
        for (index, entry) in authors.enumerated() {
            map[entry.title] = .sameAuthor("Verlag \((index + 2) / 2)", likeShow: nil)
        }
        let out = PodcastRecommendationsStore.composePriority(
            authors + rest, reason: reasons(map), limit: 12, rowLength: 6)
        // Three author cards lead, then something else follows; the remaining
        // author cards fall behind the filler, instead of filling the row.
        #expect(out.prefix(3).map(\.title) == ["a1", "a2", "a3"])
        #expect(out.prefix(6).filter { $0.title.hasPrefix("a") }.count == 3)
        // The list stays complete: it is ordered, never discarded.
        #expect(out.count == 12)
        // Without `rowLength` the old reading applies, list equals row.
        let whole = PodcastRecommendationsStore.composePriority(
            authors + rest, reason: reasons(map), limit: 12)
        #expect(whole.prefix(6).filter { $0.title.hasPrefix("a") }.count == 6)
    }

    @Test("thin author day: the row stays full, charts fill up")
    func thinAuthorDayKeepsRowLength() {
        let list = [r("a1", author: "ZEIT"), r("c1", author: nil),
                    r("c2", author: nil), r("c3", author: nil)]
        let out = PodcastRecommendationsStore.composePriority(
            list, reason: reasons(["a1": .sameAuthor("ZEIT", likeShow: nil)]), limit: 4)
        #expect(out.count == 4)
        #expect(out.first?.title == "a1")
    }

    /// Point 4 of the map demands „Reihen mit benanntem Grund", and names
    /// TWO phrasings: „Weil du … hoerst" and „Vom selben Verlag wie …".
    /// The first existed, the second did not: the reason knew only the publisher,
    /// not the show it comes from. The publisher name alone says WHO
    /// made it; the show says WHY it appears here.
    @Test("If the reason knows its own show, it names it")
    func thereasonNamesTheOwnShowWhenItKnowsIt() {
        let named = PodcastRecommendationsStore.reasonLine(
            .sameAuthor("ZEIT ONLINE", likeShow: "Alles gesagt?"))
        #expect(named.contains("Alles gesagt?"),
                "der Grund nennt die eigene Sendung nicht")
        #expect(!named.contains("ZEIT ONLINE"),
                "die Wendung mit der Sendung soll den Verlagsnamen ersetzen, nicht ergaenzen")
    }

    /// Counter-check, and it is the reason for the fallback: if the
    /// top author comes from a co-listened show or no own
    /// show matches exactly, the show is unknown. Then the older
    /// phrasing appears, which is true and says less, instead of a line with a gap.
    @Test("Without a known own show the older phrasing stays")
    func withoutAKnownOwnShowTheOlderWordingStands() {
        let plain = PodcastRecommendationsStore.reasonLine(
            .sameAuthor("ZEIT ONLINE", likeShow: nil))
        #expect(plain.contains("ZEIT ONLINE"))
        #expect(!plain.isEmpty)
    }

    @Test("the category line never sounds like an author hit")
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
