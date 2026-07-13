#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// P3 regression: the one-pass `PodcastSections.compute` must produce exactly
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
        // Pass 1: nextUp (in-progress by last played, max 10).
        var picks: [(item: LibraryItem, playedAt: Double)] = []
        for show in shows {
            for ep in show.episodes {
                let item = podcastLibraryItem(show: show, episode: ep)
                guard case .inProgress = world.state(item) else { continue }
                picks.append((item, world.ts(item.id)))
            }
        }
        let nextUp = picks.sorted { $0.playedAt > $1.playedAt }.prefix(10).map(\.item)

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

    @Test func nextUpCapsAtTen() {
        let episodes = (1...15).map { episode("e\($0)", pubDate: Double($0)) }
        let shows = [show("s", episodes: episodes)]
        var world = World()
        for i in 1...15 {
            world.states["e\(i)"] = .inProgress(fraction: 0.5, remaining: 10)
            world.lastPlayed["e\(i)"] = Double(i)
        }
        let result = compute(shows: shows, world: world)
        #expect(result.nextUp.count == 10)
        // Most recently played first.
        #expect(result.nextUp.first?.id == "e15")
        expectEqual(result, referenceSections(shows: shows, world: world))
    }
}
#endif
