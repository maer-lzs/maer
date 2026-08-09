// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// RSS hardening: a weak fetch (valid title, few/zero episodes) must never
/// shrink a show — refreshAll/subscribe union with the cache instead of
/// replacing it. Exercises the reused `PodcastSubscriptions.merge`.
struct RSSHardeningTests {
    private func episode(_ guid: String, pub: Double) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: guid, audioURL: "https://x/\(guid).mp3",
                       pubDate: pub, duration: 0)
    }
    private func show(_ guids: [String]) -> PodcastShow {
        PodcastShow(id: "feed1", title: "Zeit-Podcast", feedURL: "https://feed.example/rss",
                    episodes: guids.enumerated().map { episode($1, pub: Double($0)) })
    }

    @Test func zeroEpisodeFetchKeepsCache() {
        let cached = show((0..<50).map { "e\($0)" })
        let weak = PodcastShow(id: "feed1", title: "Zeit-Podcast",
                               feedURL: "https://feed.example/rss", episodes: [])
        let merged = PodcastSubscriptions.merge(cached, weak)
        #expect(merged.episodes.count == 50)   // NOT 0
    }

    @Test func fewerEpisodesFetchLosesNothingAndAddsNew() {
        let cached = show((0..<50).map { "e\($0)" })
        // Fresh fetch: one overlapping ("e0") + one genuinely new ("new1").
        let fresh = show(["e0", "new1"])
        let merged = PodcastSubscriptions.merge(cached, fresh)
        #expect(merged.episodes.count == 51)   // 50 old + 1 new, not 2
        #expect(merged.episodes.contains { $0.guid == "new1" })
    }

    @Test func growthStillAddsAll() {
        let cached = show((0..<10).map { "e\($0)" })
        let fresh = show((0..<15).map { "e\($0)" })   // 5 new
        let merged = PodcastSubscriptions.merge(cached, fresh)
        #expect(merged.episodes.count == 15)
    }
}
#endif
