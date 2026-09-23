// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// How often the subscription store publishes. Every publish re-runs every
/// view that observes it, so whether an observation belongs in a leaf
/// depends on this number: a store that publishes per show and per refresh
/// is expensive to observe in a container, one that publishes once per event
/// is not.
struct PodcastPublishCountTests {
    @MainActor
    final class Tally {
        var count = 0
        var episodes: [String: Int] = [:]
    }

    static func fixture(_ url: URL, episodes: Int) -> PodcastShow {
        PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString), title: "Count",
                    author: nil, artworkURL: nil, description: nil,
                    feedURL: url.absoluteString,
                    episodes: (0..<episodes).map {
                        PodcastEpisode(guid: "rss:count:\(url.lastPathComponent)-\($0)", title: "Ep \($0)",
                                       audioURL: "https://count.example/\($0).mp3",
                                       pubDate: Double($0 + 1), duration: 60)
                    })
    }

    @Test("Wie oft der Abo-Speicher meldet: je Auffrischen, je Abo, je Abbestellen")
    @MainActor
    func howOftenTheSubscriptionStorePublishes() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        try #require(AppStorageKeys.rssActive, "ohne offenes RSS-Tor frischt nichts auf, der Fall misst nichts")
        let tally = Tally()
        let run = UUID().uuidString.prefix(8)
        // Only the feeds of this run answer; every other show in the store
        // gets no fresh copy and stays as it is.
        subs._testFeedFetcher = { url in
            guard url.host == "count.example" else { return .status(404) }
            let episodes = await MainActor.run { tally.episodes[url.absoluteString] ?? 1 }
            return .show(Self.fixture(url, episodes: episodes))
        }
        let listener = subs.objectWillChange.sink { _ in
            MainActor.assumeIsolated { tally.count += 1 }
        }
        var subscribed: [String] = []
        defer {
            listener.cancel()
            subs._testFeedFetcher = nil
            for feed in subscribed {
                subs.unsubscribe(id: PodcastSubscriptions.feedKey(feed), notesCloud: false)
            }
        }

        var refreshes: [Int: Int] = [:]
        var subscribes: [Int] = []
        var unsubscribes: [Int] = []
        for size in [1, 5, 20] {
            var feeds: [String] = []
            for index in 0..<size {
                let feed = "https://count.example/\(run)-\(size)-\(index)/feed.xml"
                tally.count = 0
                let added = await subs.subscribe(urlString: feed, notesCloud: false)
                try #require(added, "das Abo \(feed) kam nicht zustande")
                subscribes.append(tally.count)
                feeds.append(feed)
                subscribed.append(feed)
            }
            // Each feed now carries one new episode, as a refresh would find.
            for feed in feeds { tally.episodes[feed] = 2 }
            tally.count = 0
            await subs.refreshAll()
            refreshes[size] = tally.count
            #expect(feeds.allSatisfy { feed in
                subs.shows.first { $0.feedURL == feed }?.episodes.count == 2
            }, "das Auffrischen hat die neue Folge nicht uebernommen, der Fall misst nichts")
            for feed in feeds {
                tally.count = 0
                subs.unsubscribe(id: PodcastSubscriptions.feedKey(feed), notesCloud: false)
                unsubscribes.append(tally.count)
                subscribed.removeAll { $0 == feed }
            }
        }
        print("MESSUNG Auffrischen je N: \(refreshes.sorted { $0.key < $1.key })")
        print("MESSUNG je Abo: \(Set(subscribes).sorted()) je Abbestellen: \(Set(unsubscribes).sorted())")
        // Measured, then written down: one publish per refresh whatever the
        // number of shows, one per subscription, one per removal.
        #expect(refreshes == [1: 1, 5: 1, 20: 1], "ein Auffrischen meldet einmal, nicht je Sendung")
        #expect(subscribes.count == 26 && subscribes.allSatisfy { $0 == 1 })
        #expect(unsubscribes.count == 26 && unsubscribes.allSatisfy { $0 == 1 })
    }
}
#endif
