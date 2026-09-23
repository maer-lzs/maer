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
///
/// The store under measurement is its OWN instance, on a folder, a database
/// and a defaults suite of its own, and not connected to the app: the
/// witness runs the same on an erased simulator and leaves nothing in the
/// app's stock.
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

    /// The refresh is gated by the RSS source switches, which live in the
    /// app's settings. The witness sets them and puts back exactly what was
    /// there, instead of assuming them.
    @MainActor
    static func openTheRSSGate() -> @MainActor () -> Void {
        let keys = [AppStorageKeys.podcastsTabEnabled, AppStorageKeys.rssEnabled]
        let was = keys.map { UserDefaults.standard.object(forKey: $0) }
        for key in keys { UserDefaults.standard.set(true, forKey: key) }
        return {
            for (key, value) in zip(keys, was) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    /// The seat became replaceable; the app's store must still take exactly
    /// the app's values, or every subscription would move to a place the app
    /// never reads.
    @Test("der Abo-Speicher der App nimmt die Werte der App")
    @MainActor
    func theAppStoreTakesTheAppsValues() {
        let app = PodcastSubscriptions.shared
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #expect(app._testFileURL == documents.appendingPathComponent("podcast_subscriptions.json"))
        #expect(app._testDatabase === MaerDatabase.shared)
        #expect(app._testDefaults === UserDefaults.standard)
        #expect(app.isTheApp)
    }

    @Test("Wie oft der Abo-Speicher meldet: je Auffrischen, je Abo, je Abbestellen")
    @MainActor
    func howOftenTheSubscriptionStorePublishes() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-count-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "publish-count-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = Self.openTheRSSGate()
        defer {
            closeTheGate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try #require(AppStorageKeys.rssActive, "das RSS-Tor ist trotz Setzen zu, der Fall misst nichts")

        // The app's stock, to show afterwards that the witness left it alone.
        let appStore = PodcastSubscriptions.shared
        await appStore.ensureLoaded()
        let appShowsBefore = appStore.shows.map(\.feedURL)
        // The app's stock is what lands on disk, not what the app's store
        // holds in memory (it does not reload): its rows and the settings key
        // a removal writes.
        let appRowsBefore = await appStore._testRowCounts()
        let appRemovedBefore = PodcastSubscriptions.userRemovedFeeds()

        let subs = PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
        await subs.ensureLoaded()
        let tally = Tally()
        let run = UUID().uuidString.prefix(8)
        subs._testFeedFetcher = { url in
            guard url.host == "count.example" else { return .status(404) }
            let episodes = await MainActor.run { tally.episodes[url.absoluteString] ?? 1 }
            return .show(Self.fixture(url, episodes: episodes))
        }
        let listener = subs.objectWillChange.sink { _ in
            MainActor.assumeIsolated { tally.count += 1 }
        }
        defer { listener.cancel() }

        var refreshes: [Int: Int] = [:]
        var subscribes: [Int] = []
        var unsubscribes: [Int] = []
        var guids: [String] = []
        for size in [1, 5, 20] {
            var feeds: [String] = []
            for index in 0..<size {
                let feed = "https://count.example/\(run)-\(size)-\(index)/feed.xml"
                tally.count = 0
                let added = await subs.subscribe(urlString: feed, notesCloud: false)
                try #require(added, "das Abo \(feed) kam nicht zustande")
                subscribes.append(tally.count)
                feeds.append(feed)
            }
            #expect(subs.shows.count == size, "die eigene Instanz traegt genau ihre Test-Feeds")
            // Each feed now carries one new episode, as a refresh would find.
            for feed in feeds { tally.episodes[feed] = 2 }
            tally.count = 0
            await subs.refreshAll()
            refreshes[size] = tally.count
            #expect(feeds.allSatisfy { feed in
                subs.shows.first { $0.feedURL == feed }?.episodes.count == 2
            }, "das Auffrischen hat die neue Folge nicht uebernommen, der Fall misst nichts")
            guids += subs.shows.flatMap { $0.episodes.map(\.guid) }
            for feed in feeds {
                tally.count = 0
                subs.unsubscribe(id: PodcastSubscriptions.feedKey(feed), notesCloud: false)
                unsubscribes.append(tally.count)
            }
        }
        print("MESSUNG Auffrischen je N: \(refreshes.sorted { $0.key < $1.key })")
        print("MESSUNG je Abo: \(Set(subscribes).sorted()) je Abbestellen: \(Set(unsubscribes).sorted())")
        // Measured, then written down: one publish per refresh whatever the
        // number of shows, one per subscription, one per removal.
        #expect(refreshes == [1: 1, 5: 1, 20: 1], "ein Auffrischen meldet einmal, nicht je Sendung")
        #expect(subscribes.count == 26 && subscribes.allSatisfy { $0 == 1 })
        #expect(unsubscribes.count == 26 && unsubscribes.allSatisfy { $0 == 1 })

        // Nothing reached the app's stock: its subscriptions are the same, and
        // the healing pass at the end of each refresh wrote no listening
        // entry for the test episodes.
        #expect(appStore.shows.map(\.feedURL) == appShowsBefore, "der Abo-Bestand der App ist unberuehrt")
        #expect(await appStore._testRowCounts() == appRowsBefore,
                "in die Zeilen der App ist nichts geschrieben worden")
        #expect(PodcastSubscriptions.userRemovedFeeds() == appRemovedBefore,
                "die Einstellungen der App kennen keinen entfernten Test-Feed")
        #expect(guids.count == 52 && guids.allSatisfy { ListeningStore.backup($0) == nil },
                "das Heilen hat fuer die Test-Folgen nichts in den Hoerbestand geschrieben")
    }
}
#endif
