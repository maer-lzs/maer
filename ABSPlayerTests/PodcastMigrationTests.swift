// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// The migration core (re-key ids/guids, move progress, dedupe
/// feeds) is pure and must be idempotent; the async bootstrap runs exactly this
/// decode→migrate pipeline, so pinning the pipeline pins the bootstrap.
struct PodcastMigrationTests {

    private func legacyShow(id: String, feedURL: String, guids: [String]) -> PodcastShow {
        PodcastShow(
            id: id, title: "T", author: nil, artworkURL: nil, description: nil,
            feedURL: feedURL,
            episodes: guids.enumerated().map { i, guid in
                PodcastEpisode(guid: guid, title: "E\(i)", audioURL: "https://x/\(i).mp3",
                               pubDate: Double(i), duration: 60, description: nil,
                               imageURL: nil, chaptersURL: nil)
            }
        )
    }

    @Test func rekeysLegacyIdsAndMovesProgress() {
        let feed = "https://example.com/feed"
        let key = PodcastSubscriptions.feedKey(feed)
        let legacy = [legacyShow(id: "12345", feedURL: feed, guids: ["orig-1", "rss:\(key):orig-2"])]

        var moves: [String: String] = [:]
        let (shows, changed) = PodcastSubscriptions.migrate(legacy) { old, new in moves[old] = new }

        #expect(changed)
        #expect(shows.count == 1)
        #expect(shows[0].id == "feed:\(key)")
        #expect(shows[0].episodes.map(\.guid) == ["rss:\(key):orig-1", "rss:\(key):orig-2"])
        // Progress moved ONLY for the re-keyed guid; the already-stable one stays.
        #expect(moves == ["orig-1": "rss:\(key):orig-1"])
    }

    @Test func migrationIsIdempotent() {
        let feed = "https://example.com/feed"
        let legacy = [legacyShow(id: "old", feedURL: feed, guids: ["a", "b", "c"])]

        let (first, changedFirst) = PodcastSubscriptions.migrate(legacy) { _, _ in }
        #expect(changedFirst)

        var secondMoves = 0
        let (second, changedSecond) = PodcastSubscriptions.migrate(first) { _, _ in secondMoves += 1 }
        #expect(!changedSecond, "second run must be a no-op")
        #expect(secondMoves == 0)
        #expect(second.map(\.id) == first.map(\.id))
        #expect(second.flatMap { $0.episodes.map(\.guid) } == first.flatMap { $0.episodes.map(\.guid) })
    }

    @Test("Duplicate shows of the same feed (http/https/www variants) merge into one")
    func dedupesSameFeed() {
        let a = legacyShow(id: "x", feedURL: "https://example.com/feed", guids: ["g1", "g2"])
        let b = legacyShow(id: "y", feedURL: "http://www.example.com/feed/", guids: ["g2", "g3"])

        let (shows, changed) = PodcastSubscriptions.migrate([a, b]) { _, _ in }
        #expect(changed)
        #expect(shows.count == 1)
        let key = PodcastSubscriptions.feedKey("https://example.com/feed")
        // Episodes deduped by guid: g1, g2, g3 exactly once each.
        let guids = Set(shows[0].episodes.map(\.guid))
        #expect(guids == Set(["g1", "g2", "g3"].map { "rss:\(key):\($0)" }))
    }

    @Test func episodeIndexResolvesEveryGuid() {
        let feed = "https://example.com/feed"
        let (shows, _) = PodcastSubscriptions.migrate(
            [legacyShow(id: "s", feedURL: feed, guids: ["a", "b"]),
             legacyShow(id: "t", feedURL: "https://other.org/rss", guids: ["c"])]
        ) { _, _ in }

        let index = PodcastSubscriptions.buildEpisodeIndex(shows)
        #expect(index.count == 3)
        for (s, show) in shows.enumerated() {
            for (e, ep) in show.episodes.enumerated() {
                let hit = index[ep.guid]
                #expect(hit?.show == s)
                #expect(hit?.episode == e)
            }
        }
    }

    /// The bootstrap path is: read file → JSON decode → migrate. Pin the whole
    /// pipeline with a round trip through a temp file — this is exactly what the
    /// old synchronous init did and what the async bootstrap does now.
    @Test func decodeMigratePipelineRoundTrip() throws {
        let feed = "https://example.com/feed"
        let key = PodcastSubscriptions.feedKey(feed)
        let legacy = [legacyShow(id: "legacy", feedURL: feed, guids: ["e1", "e2"])]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("subs.json")
        try JSONEncoder().encode(legacy).write(to: file)

        let decoded = try JSONDecoder().decode([PodcastShow].self, from: Data(contentsOf: file))
        let (shows, changed) = PodcastSubscriptions.migrate(decoded) { _, _ in }

        #expect(changed)
        #expect(shows.map(\.id) == ["feed:\(key)"])
        #expect(shows[0].episodes.map(\.guid) == ["rss:\(key):e1", "rss:\(key):e2"])
        #expect(shows[0].episodes.map(\.title) == decoded[0].episodes.map(\.title))
    }
}
#endif
