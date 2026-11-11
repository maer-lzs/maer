// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A refresh of all feeds lands on the stock as it stands after the last
/// answer, by id, not on the copy it took before the first fetch.
struct RefreshAllMergeTests {
    private func show(_ id: String, episodes: [String]) -> PodcastShow {
        PodcastShow(id: id, title: id, author: nil, artworkURL: nil, description: nil,
                    feedURL: "https://\(id).example/feed",
                    episodes: episodes.enumerated().map { index, guid in
                        PodcastEpisode(guid: guid, title: guid, audioURL: "https://\(id).example/\(guid).mp3",
                                       pubDate: Double(index + 1), duration: 60)
                    })
    }

    @Test("Auffrischen aller Feeds: eine waehrenddessen abonnierte Sendung bleibt, eine abbestellte bleibt weg, die Antwort landet nach Kennung")
    func theRefreshLandsOnTheStockAsItStandsNow() {
        // The copy before the fetches held a and b; meanwhile b was dropped
        // and c subscribed, in another order.
        let current = [show("c", episodes: ["c1"]), show("a", episodes: ["a1"])]
        let fetched = ["a": show("a", episodes: ["a1", "a2"]), "b": show("b", episodes: ["b1", "b2"])]
        let refreshed = PodcastSubscriptions.mergedRefresh(current: current, fetched: fetched)
        #expect(refreshed.shows.map(\.id) == ["c", "a"], "a subscription made during the refresh was lost or a dropped one came back")
        #expect(Set(refreshed.shows.first { $0.id == "a" }?.episodes.map(\.guid) ?? []) == ["a1", "a2"])
        #expect(refreshed.shows.first { $0.id == "c" }?.episodes.map(\.guid) == ["c1"])
        #expect(refreshed.pairs.map(\.stored.id) == ["a"], "a pair belongs to a show that got an answer")
    }
}
#endif
