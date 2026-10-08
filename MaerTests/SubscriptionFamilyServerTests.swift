// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The family (iCloud or the service) and the podcast server say the same
/// thing. Two devices in one family, one of them with a gpodder server
/// standing in as a list in memory: what gpodder holds reaches the device
/// without a server, what that device changes reaches gpodder, a pull after
/// an unsubscribe brings nothing back, and the stands of the feed stay.
/// The device with the server is the shared subscription store; the device
/// without one is a dictionary.
@MainActor
struct SubscriptionFamilyServerTests {
    final class FakeGPodder: GPodderSubscriptionTransport {
        var server: Set<String>
        var uploads: [(add: [String], remove: [String])] = []
        init(_ server: Set<String>) { self.server = server }
        func subscriptions() async throws -> [String] { Array(server) }
        func uploadSubscriptions(add: [String], remove: [String]) async throws {
            uploads.append((add, remove))
            server.formUnion(add)
            server.subtract(remove)
        }
    }

    private static let mergeKeys = [AppStorageKeys.gpodderLastSyncedFeeds, AppStorageKeys.gpodderPendingRemoveLocal,
                                    AppStorageKeys.gpodderPendingRemoveServer, AppStorageKeys.gpodderUserRemovedFeeds]

    private func show(_ feedURL: String, guid: String) -> PodcastShow {
        PodcastShow(id: "rss:\(PodcastSubscriptions.feedKey(feedURL))", title: "Show \(guid)", author: "Host",
                    artworkURL: nil, description: nil, feedURL: feedURL,
                    episodes: [PodcastEpisode(guid: guid, title: "Ep", audioURL: "https://x.example/\(guid).mp3",
                                              pubDate: 1_700_000_000_000, duration: 1800,
                                              description: nil, imageURL: nil, chaptersURL: nil)])
    }

    @Test("gpodder → iPhone → iPad; Abbestellen iPad → iPhone → gpodder, der Pull bringt es nicht zurueck; neues Abo iPad → gpodder; Hoerstaende bleiben")
    func theFamilyAndGpodderConverge() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let run = UUID().uuidString.prefix(8)
        let feed = "https://example.org/family-\(run)/feed.xml"
        let other = "https://example.org/family-\(run)/other.xml"
        let guid = "rss:family:\(run):ep-1"
        let feedNorm = PodcastSubscriptions.normalizeFeedURL(feed)
        // The merge keeps its state in the standard defaults: kept, cleared
        // for a first-run union (a stale prior state would read the feeds
        // of other witnesses as removed), and put back.
        let kept = Self.mergeKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for key in Self.mergeKeys { UserDefaults.standard.removeObject(forKey: key) }
        subs._testFeedFetcher = { url in .show(self.show(url.absoluteString, guid: url.absoluteString == feed ? guid : "\(guid)-other")) }
        defer {
            subs._testFeedFetcher = nil
            for show in subs.shows where show.feedURL == feed || show.feedURL == other { subs.unsubscribe(id: show.id, notesCloud: false) }
            for (key, value) in kept { UserDefaults.standard.set(value, forKey: key) }
            ListeningStore.clearBackup(guid)
        }
        func settle(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<150 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        }

        // The family: iPad without a server (a dictionary), iPhone with one
        // (the shared store).
        let cloud = UserChoiceFakeCloud()
        let padSuite = "family-pad-\(run)", phoneSuite = "family-phone-\(run)"
        let padDefaults = UserDefaults(suiteName: padSuite)!, phoneDefaults = UserDefaults(suiteName: phoneSuite)!
        defer { UserDefaults().removePersistentDomain(forName: padSuite); UserDefaults().removePersistentDomain(forName: phoneSuite) }
        var clock: Double = 1_000
        var padSubs: [String: String] = [:]
        let pad = UserChoiceCloudSync(defaults: padDefaults, cloud: cloud, syncEnabled: { true },
                                      now: { clock += 1; return clock })
        pad.localSubscriptions = { padSubs }
        pad.subscriptionAdopter = { added, removed in
            for entry in added { padSubs[PodcastSubscriptions.feedKey(entry.feedURL)] = entry.feedURL }
            for key in removed { padSubs[key] = nil }
        }
        let phone = UserChoiceCloudSync(defaults: phoneDefaults, cloud: cloud, syncEnabled: { true },
                                        now: { clock += 1; return clock })
        phone.localSubscriptions = { subs.subscriptionsForCloud() }
        phone.subscriptionAdopter = { added, removed in subs.adoptCloudSubscriptions(added: added, removed: removed) }
        let gpodder = FakeGPodder([feed])
        let sync = GPodderSync.shared

        // (a) gpodder → iPhone → iPad.
        _ = try await sync.syncSubscriptions(gpodder)
        #expect(subs.shows.contains { $0.feedURL == feed }, "the precondition: the pull followed the feed here")
        phone.reconcile()
        pad.reconcile()
        #expect(padSubs.values.contains(feed), "the server's feed reached the device without a server")

        // (d) a stand of the feed, before the unsubscribe.
        ListeningStore.store(guid, entry: [420, clock, 1800])
        let standBefore = ListeningStore.backup(guid)
        #expect(standBefore != nil)

        // (b) the iPad unsubscribes: iPhone applies, gpodder loses the feed,
        // and the pull after that brings nothing back.
        padSubs = [:]
        pad.noteSubscription(feedURL: feed, subscribed: false)
        phone.reconcile()
        try await settle { !subs.shows.contains { $0.feedURL == feed } }
        #expect(!subs.shows.contains { $0.feedURL == feed }, "the device with the server applied the family's unsubscribe")
        #expect(PodcastSubscriptions.userRemovedFeeds().contains(feedNorm), "the family's unsubscribe is the person's intent")
        _ = try await sync.syncSubscriptions(gpodder)
        #expect(!gpodder.server.contains(feed), "gpodder lost the feed")
        _ = try await sync.syncSubscriptions(gpodder)
        #expect(!subs.shows.contains { $0.feedURL == feed }, "the pull after the push brings it not back")
        #expect(!gpodder.server.contains(feed))
        #expect(ListeningStore.backup(guid) == standBefore, "the stand of the feed is untouched")

        // (c) a new subscription on the iPad reaches gpodder.
        padSubs[PodcastSubscriptions.feedKey(other)] = other
        pad.noteSubscription(feedURL: other, subscribed: true)
        phone.reconcile()
        try await settle { subs.shows.contains { $0.feedURL == other } }
        #expect(subs.shows.contains { $0.feedURL == other }, "the device with the server followed the family's new feed")
        _ = try await sync.syncSubscriptions(gpodder)
        #expect(gpodder.server.contains(other), "the new subscription reached gpodder")
    }

    /// What the round applies locally is noted to the family (the fence on
    /// the two call sites, because the shared family runner stays silent in
    /// the test host and cannot witness the note itself).
    @Test("die gpodder-Runde notiert, was sie lokal anwendet, in die Familie")
    func theRoundNotesItsLocalChangesToTheFamily() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/GPodderSync.swift"), encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(!code.contains("notesCloud: false"), "a server-driven change left unnoted comes back through the family")
        #expect(code.contains("subs.unsubscribe(id: show.id, notesCloud: true)"))
        // Through the door before `subscribe`, with the same note.
        #expect(code.contains("subs.subscribeUnlessOnServer(urlString: raw, notesCloud: true"))
    }
}
#endif
