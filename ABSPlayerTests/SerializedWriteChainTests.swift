// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// P8 regression: the chained writer must keep the store file valid under many
/// overlapping saves (ordering preserved, last snapshot wins, no interleaved
/// JSON). Run this suite with Thread Sanitizer enabled to verify the detached
/// encode/write path is race-free.
@MainActor
struct SerializedWriteChainTests {

    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maer-writer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.json")
    }

    private func fixtureShows(_ n: Int) -> [PodcastShow] {
        (0..<n).map { i in
            PodcastShow(
                id: "feed:\(i)", title: "Show \(i)", author: "A\(i)", artworkURL: nil,
                description: nil, feedURL: "https://example.com/\(i)",
                episodes: (0..<3).map { e in
                    PodcastEpisode(guid: "rss:\(i):\(e)", title: "E\(e)",
                                   audioURL: "https://example.com/\(i)/\(e).mp3",
                                   pubDate: Double(e), duration: 60, description: nil,
                                   imageURL: nil, chaptersURL: nil)
                }
            )
        }
    }

    @Test func roundTripPreservesTheStore() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let shows = fixtureShows(4)

        let chain = SerializedWriteChain()
        chain.write(to: url) { try? JSONEncoder().encode(shows) }
        await chain.flush()

        let decoded = try JSONDecoder().decode([PodcastShow].self, from: Data(contentsOf: url))
        #expect(decoded.map(\.id) == shows.map(\.id))
        #expect(decoded.flatMap { $0.episodes.map(\.guid) } == shows.flatMap { $0.episodes.map(\.guid) })
    }

    @Test("Many overlapping saves: valid JSON, submission order preserved, last snapshot wins")
    func overlappingWritesStaySerialized() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let chain = SerializedWriteChain()
        // Mutate a store and save after each mutation — like rapid
        // subscribe/refresh/trim bursts. Each write takes a value snapshot.
        var store: [PodcastShow] = []
        for i in 0..<100 {
            store = fixtureShows(i % 7 + 1)
            let snapshot = store
            chain.write(to: url) { try? JSONEncoder().encode(snapshot) }
        }
        let final = store
        await chain.flush()

        // The file must hold EXACTLY the last snapshot — an interleaved or
        // out-of-order write would either corrupt the JSON (decode fails) or
        // leave an older snapshot behind.
        let decoded = try JSONDecoder().decode([PodcastShow].self, from: Data(contentsOf: url))
        #expect(decoded.map(\.id) == final.map(\.id))
        #expect(decoded.count == final.count)
    }

    @Test func flushWithoutWritesIsANoop() async {
        let chain = SerializedWriteChain()
        await chain.flush()   // must simply return
        #expect(Bool(true))
    }
}
#endif
