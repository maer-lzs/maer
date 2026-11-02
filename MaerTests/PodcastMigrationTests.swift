// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

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

    /// The cases live in `Fixtures/Shared/abos/migration.json`, read by
    /// Swift and Kotlin alike: legacy ids and guids are re-keyed and the
    /// progress moves once, a second run changes nothing, two spellings of
    /// one feed become one show, and the episode index resolves every guid.
    /// The file carries the feed keys as measured hashes, so a side whose
    /// `stableHash` drifts tears here.
    nonisolated static let migration = SharedCases.cases("migration")

    /// A stored show as the file names it: id, feedURL, episodes with guid and pubDate.
    private static func show(_ value: JSONValue) -> PodcastShow {
        let episodes = (value["episodes"]?.array ?? []).enumerated().map { i, episode -> PodcastEpisode in
            let guid = episode["guid"]?.string ?? ""
            return PodcastEpisode(guid: guid, title: "E\(i)", audioURL: "https://x/\(i).mp3",
                                  pubDate: Double(episode["pubDate"]?.int ?? i), duration: 60,
                                  description: nil, imageURL: nil, chaptersURL: nil)
        }
        return PodcastShow(id: value["id"]?.string ?? "", title: "T", author: nil, artworkURL: nil,
                           description: nil, feedURL: value["feedURL"]?.string ?? "", episodes: episodes)
    }

    @Test("gemeinsame Faelle: migration traegt vier Faelle")
    func migrationCasesLoaded() {
        #expect(Self.migration.count == 4)
    }

    @Test("gemeinsame Faelle: der Umzug schluesselt um, verschiebt den Fortschritt und faltet je Fall wie die Datei sagt", arguments: migration)
    func theMigrationAnswersAsTheFileSays(_ c: SharedCase) throws {
        let input = try c.value("input")
        let expect = try c.value("expect")
        let shows = (input["shows"]?.array ?? []).map(Self.show)
        switch c.ask {
        case "migrate":
            var moves: [String: String] = [:]
            let (migrated, changed) = PodcastIdentity.migrate(shows) { old, new in moves[old] = new }
            #expect(changed == expect["changed"]?.bool, "\(c.slug)")
            let actual = JSONValue.array(migrated.map {
                .object(["id": .string($0.id), "guids": .array($0.episodes.map { .string($0.guid) })])
            })
            #expect(actual == expect["shows"], "\(c.slug)")
            #expect(JSONValue.object(moves.mapValues(JSONValue.string)) == expect["moves"], "\(c.slug)")
        case "episodeIndex":
            let index = PodcastSubscriptions.buildEpisodeIndex(shows)
            let actual = JSONValue.object(index.mapValues { .array([.int($0.show), .int($0.episode)]) })
            #expect(actual == expect, "\(c.slug)")
        default:
            Issue.record("\(c.slug): unknown ask \(c.ask)")
        }
    }

    /// The bootstrap path is: read file → JSON decode → migrate. Pin the whole
    /// pipeline with a round trip through a temp file. This is exactly what the
    /// old synchronous init did and what the async bootstrap does now.
    @Test func decodeMigratePipelineRoundTrip() throws {
        let feed = "https://example.com/feed"
        let key = PodcastIdentity.feedKey(feed)
        let legacy = [legacyShow(id: "legacy", feedURL: feed, guids: ["e1", "e2"])]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("subs.json")
        try JSONEncoder().encode(legacy).write(to: file)

        let decoded = try JSONDecoder().decode([PodcastShow].self, from: Data(contentsOf: file))
        let (shows, changed) = PodcastIdentity.migrate(decoded) { _, _ in }

        #expect(changed)
        #expect(shows.map(\.id) == ["feed:\(key)"])
        #expect(shows[0].episodes.map(\.guid) == ["rss:\(key):e1", "rss:\(key):e2"])
        #expect(shows[0].episodes.map(\.title) == decoded[0].episodes.map(\.title))
    }
}
#endif
