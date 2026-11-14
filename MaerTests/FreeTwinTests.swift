// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The free twin of a permanently declined paid show: first the remembered
/// free address, otherwise ONE directory search by title.
/// The show asks, never silently; Yes carries the listening states over and
/// remembers the paid address on the device, No leaves the notice in place.
@MainActor
struct FreeTwinTests {
    /// A directory that counts every search.
    final class FakeDirectory: PodcastDirectory {
        var hits: [PodcastSearchResult] = []
        var fails = false
        var searches: [String] = []
        func search(_ term: String) async throws -> [PodcastSearchResult] {
            searches.append(term)
            if fails { throw URLError(.timedOut) }
            return hits
        }
    }

    private let day = FeedRefusal.span

    private func harness(_ name: String) throws -> (subs: PodcastSubscriptions, defaults: UserDefaults, close: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "twin-\(name)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = PodcastPublishCountTests.openTheRSSGate()
        let subs = PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
        return (subs, defaults, {
            closeTheGate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    private struct Feeds {
        let paid: URL
        let free: URL
    }

    private func feeds() throws -> Feeds {
        let run = UUID().uuidString.prefix(8)
        return Feeds(paid: try #require(URL(string: "https://paid.example/\(run)/feed?token=geheim")),
                     free: try #require(URL(string: "https://free.example/\(run)/feed.xml")))
    }

    /// Paid feed subscribed, then declined three times over a day.
    private func refusedPaidShow(_ subs: PodcastSubscriptions, _ feeds: Feeds,
                                 now: @escaping () -> Double, advance: () -> Void) async throws -> PodcastShow {
        subs.clock = now
        await subs.ensureLoaded()
        subs._testFeedFetcher = { url in .show(FeedRefusalTests.show(url, guidStem: "paid", episodes: 0..<4)) }
        try #require(await subs.subscribe(urlString: feeds.paid.absoluteString, notesCloud: false))
        let show = try #require(subs.shows.first)
        subs._testFeedFetcher = { _ in .status(403) }
        for _ in 0..<3 { await subs.refreshAll(); advance() }
        try #require(subs.isAccessRefused(show), "die Ablehnung ist dauerhaft, sonst misst der Fall nichts")
        return show
    }

    private func hit(_ title: String, _ feedURL: String) -> PodcastSearchResult {
        PodcastSearchResult(title: title, author: nil, artworkURL: nil, feedURL: feedURL)
    }

    // MARK: - The rules

    @Test("A hit needs the same title and no paid marker; remembered before searched; No is no offer")
    func rules() {
        let isPremium: (String) -> Bool = { $0.contains("token=") }
        #expect(FreeTwin.pick(hits: [("Verbrechen", "https://p.example/f?token=x"), ("Verbrechen", "https://f.example/f")],
                              showTitle: "Verbrechen", isPremium: isPremium) == 1)
        #expect(FreeTwin.pick(hits: [("Anderes", "https://f.example/f")], showTitle: "Verbrechen", isPremium: isPremium) == nil)
        #expect(FreeTwin.offer(remembered: "https://a", searched: ["https://b", "B"], declined: false)
                == FreeTwin.Offer(feedURL: "https://a", title: nil))
        #expect(FreeTwin.offer(remembered: nil, searched: ["https://b", "B"], declined: false)
                == FreeTwin.Offer(feedURL: "https://b", title: "B"))
        #expect(FreeTwin.offer(remembered: nil, searched: [], declined: false) == nil, "nichts gefunden")
        #expect(FreeTwin.offer(remembered: "https://a", searched: nil, declined: true) == nil)
    }

    @Test("The remembered address loses only user and password, not a single other character")
    func addressLosesOnlyTheCredentials() {
        #expect(FreeTwin.address("https://name:geheim@feeds.example/Show/Feed/?page=2#x")
                == "https://feeds.example/Show/Feed/?page=2#x")
        #expect(FreeTwin.address("https://name@feeds.example/feed") == "https://feeds.example/feed")
        for unchanged in ["https://feeds.example/feed/", "https://feeds.example/Feed.XML",
                          "https://feeds.example/feed?token=a@b", "http://feeds.example:8080/a/b/",
                          "feeds.example/feed"] {
            #expect(FreeTwin.address(unchanged) == unchanged, "\(unchanged)")
        }
    }

    // MARK: - A: the free address is remembered where it is seen

    @Test("A: the swap from free to premium and the skipped twin remember the free address, without a credential")
    func freeAddressIsRemembered() async throws {
        let h = try harness("merken")
        defer { h.close() }
        let f = try feeds()
        await h.subs.ensureLoaded()
        h.subs._testFeedFetcher = { url in
            .show(FeedRefusalTests.show(url, guidStem: url.absoluteString.contains("paid") ? "paid" : "free", episodes: 0..<4))
        }
        // Swap: first free, then premium, then the consent.
        try #require(await h.subs.subscribe(urlString: f.free.absoluteString, notesCloud: false))
        try #require(await h.subs.subscribe(urlString: f.paid.absoluteString, notesCloud: false))
        let offer = try #require(h.subs.pendingPremiumReplacement, "das Angebot steht, sonst misst der Fall nichts")
        h.subs.replaceFreeWithPremium(offer, notesCloud: false)
        let key = AppStorageKeys.podcastFreeTwin(offer.premiumShowId)
        #expect(h.defaults.string(forKey: key) == f.free.absoluteString)
        #expect(h.defaults.string(forKey: key)?.contains("geheim") == false)

        // Skipping: the premium subscription stays, the free address arrives.
        h.defaults.removeObject(forKey: key)
        let outcome = await h.subs.follow(urlString: f.free.absoluteString, notesCloud: false)
        guard case .freeTwin = outcome else {
            Issue.record("the free twin was not skipped: \(outcome)")
            return
        }
        #expect(h.defaults.string(forKey: key) == f.free.absoluteString)
    }

    @Test("A travels to the second device, without a credential; after that neither writes any more")
    func freeAddressTravels() {
        let cloud = UserChoiceFakeCloud()
        let suites = ["twin-a-\(UUID().uuidString)", "twin-b-\(UUID().uuidString)"]
        defer { for s in suites { UserDefaults().removePersistentDomain(forName: s) } }
        var clock = 1000.0
        let devices = suites.map { suite -> (UserChoiceCloudSync, UserDefaults) in
            let d = UserDefaults(suiteName: suite)!
            return (UserChoiceCloudSync(defaults: d, cloud: cloud, syncEnabled: { true },
                                        now: { clock += 1; return clock }, idFormSettled: { true }), d)
        }
        let key = AppStorageKeys.podcastFreeTwin("feed:abc")
        devices[0].1.set("https://free.example/feed.xml", forKey: key)
        devices[0].0.noteScalar(key: key, value: "https://free.example/feed.xml")
        devices[1].0.reconcile()
        #expect(devices[1].1.string(forKey: key) == "https://free.example/feed.xml")
        let before = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        devices[1].0.reconcile()
        devices[0].0.reconcile()
        let after = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(NSDictionary(dictionary: before).isEqual(to: after), "eingeschwungen")
    }

    // MARK: - B: one search

    @Test("B: exactly one search, only when the refusal is permanent; then zero requests; the hit stands with its title")
    func oneSearchThenSilence() async throws {
        let h = try harness("suche")
        defer { h.close() }
        let f = try feeds()
        let directory = FakeDirectory()
        directory.hits = [hit("Verbrechen", "https://other.example/feed?token=x"), hit("Verbrechen", f.free.absoluteString)]
        h.subs._testDirectory = directory
        var now = 1_000_000.0
        let show = try await refusedPaidShow(h.subs, f, now: { now }, advance: { now += day / 2 })
        #expect(directory.searches == ["Verbrechen"], "eine Suche, nur der Titel")
        #expect(h.subs.freeTwinOffer(show) == FreeTwin.Offer(feedURL: f.free.absoluteString, title: "Verbrechen"))
        for _ in 0..<3 { await h.subs.refreshAll(); now += day }
        #expect(directory.searches.count == 1, "Ruhe: nach dem ersten Ergebnis keine Anfrage mehr")
    }

    @Test("B: nothing found is remembered, a failure is not; no directory means no request")
    func nothingIsKeptFailureIsNot() async throws {
        let h = try harness("nichts")
        defer { h.close() }
        let f = try feeds()
        let directory = FakeDirectory()
        directory.fails = true
        h.subs._testDirectory = directory
        var now = 1_000_000.0
        let show = try await refusedPaidShow(h.subs, f, now: { now }, advance: { now += day / 2 })
        #expect(directory.searches.count == 1)
        #expect(h.subs.freeTwinOffer(show) == nil)
        // The failure remembered nothing: the next refresh asks once more.
        directory.fails = false
        directory.hits = []
        await h.subs.refreshAll()
        #expect(directory.searches.count == 2)
        // „Nichts gefunden“ is remembered.
        await h.subs.refreshAll()
        #expect(directory.searches.count == 2)
        #expect(h.subs.freeTwinOffer(show) == nil)

        // Without a directory no request goes out.
        let g = try harness("ohne")
        defer { g.close() }
        var later = 1_000_000.0
        let other = try await refusedPaidShow(g.subs, try feeds(), now: { later }, advance: { later += day / 2 })
        #expect(g.subs.freeTwinOffer(other) == nil)
    }

    @Test("A before B: if the free address is known, no search happens")
    func rememberedAddressNeedsNoSearch() async throws {
        let h = try harness("bekannt")
        defer { h.close() }
        let f = try feeds()
        let directory = FakeDirectory()
        h.subs._testDirectory = directory
        await h.subs.ensureLoaded()
        // The identifier under which the show soon stands (the fixture
        // builds it from the address) gets the address BEFORE the refusal.
        let paidId = PodcastIdentity.feedKey(f.paid.absoluteString)
        h.defaults.set(f.free.absoluteString, forKey: AppStorageKeys.podcastFreeTwin(paidId))
        var now = 1_000_000.0
        let show = try await refusedPaidShow(h.subs, f, now: { now }, advance: { now += day / 2 })
        try #require(show.id == paidId, "die Vorrichtung traegt die erwartete Kennung")
        await h.subs.refreshAll()
        #expect(directory.searches.isEmpty)
        #expect(h.subs.freeTwinOffer(show) == FreeTwin.Offer(feedURL: f.free.absoluteString, title: nil))
    }

    // MARK: - The person's answer

    @Test("Yes: the free show is there, the listening states went along, the paid address is remembered on the device")
    func switchCarriesOver() async throws {
        let h = try harness("ja")
        defer { h.close() }
        let f = try feeds()
        var now = 1_000_000.0
        let paid = try await refusedPaidShow(h.subs, f, now: { now }, advance: { now += day / 2 })
        h.defaults.set(f.free.absoluteString, forKey: AppStorageKeys.podcastFreeTwin(paid.id))
        ListeningStore.store("rss:paid-2", entry: [700, 1_700_000_000_000, 3000], in: h.defaults)
        h.subs._testFeedFetcher = { url in .show(FeedRefusalTests.show(url, guidStem: "free", episodes: 0..<4)) }

        #expect(await h.subs.switchToFreeTwin(showId: paid.id, notesCloud: false))

        #expect(h.subs.shows.map(\.feedURL) == [f.free.absoluteString])
        #expect(ListeningStore.backup("rss:free-2", in: h.defaults)?.first == 700, "der Hoerstand ging mit")
        let free = try #require(h.subs.shows.first)
        let paidTwins = h.defaults.dictionary(forKey: AppStorageKeys.podcastPaidTwin) as? [String: String]
        #expect(paidTwins?[free.id] == f.paid.absoluteString)
    }

    @Test("Yes, if the free feed is already subscribed: the move goes to the existing show, not silently into nothing")
    func switchOntoTheSubscribedTwin() async throws {
        let h = try harness("ja-schon")
        defer { h.close() }
        let f = try feeds()
        var now = 1_000_000.0
        h.subs.clock = { now }
        await h.subs.ensureLoaded()
        h.subs._testFeedFetcher = { url in
            .show(FeedRefusalTests.show(url, guidStem: url.absoluteString.contains("paid") ? "paid" : "free", episodes: 0..<4))
        }
        // First free, then premium (the offer to swap stays open):
        // both are subscribed.
        try #require(await h.subs.subscribe(urlString: f.free.absoluteString, notesCloud: false))
        try #require(await h.subs.subscribe(urlString: f.paid.absoluteString, notesCloud: false))
        let paid = try #require(h.subs.shows.first { $0.feedURL == f.paid.absoluteString })
        try #require(h.subs.shows.count == 2, "beide abonniert, sonst misst der Fall nichts")
        // Only the paid feed is declined, over a day.
        h.subs._testFeedFetcher = { url in
            url.absoluteString.contains("paid")
                ? .status(403) : .show(FeedRefusalTests.show(url, guidStem: "free", episodes: 0..<4))
        }
        for _ in 0..<3 { await h.subs.refreshAll(); now += day / 2 }
        try #require(h.subs.isAccessRefused(paid))
        h.defaults.set(f.free.absoluteString, forKey: AppStorageKeys.podcastFreeTwin(paid.id))
        ListeningStore.store("rss:paid-1", entry: [400, 1_700_000_000_000, 3000], in: h.defaults)

        #expect(await h.subs.switchToFreeTwin(showId: paid.id, notesCloud: false))

        #expect(h.subs.shows.map(\.feedURL) == [f.free.absoluteString], "nur die freie Sendung bleibt")
        #expect(ListeningStore.backup("rss:free-1", in: h.defaults)?.first == 400, "der Hoerstand ging mit")
    }

    @Test("No: the question goes, the notice stays; a success of the feed clears search and No")
    func declineKeepsTheNotice() async throws {
        let h = try harness("nein")
        defer { h.close() }
        let f = try feeds()
        let directory = FakeDirectory()
        directory.hits = [hit("Verbrechen", f.free.absoluteString)]
        h.subs._testDirectory = directory
        var now = 1_000_000.0
        let show = try await refusedPaidShow(h.subs, f, now: { now }, advance: { now += day / 2 })
        try #require(h.subs.freeTwinOffer(show) != nil)
        h.subs.declineFreeTwin(show)
        #expect(h.subs.freeTwinOffer(show) == nil)
        #expect(h.subs.isAccessRefused(show), "der Hinweis bleibt")

        h.subs._testFeedFetcher = { url in .show(FeedRefusalTests.show(url, guidStem: "paid", episodes: 0..<4)) }
        await h.subs.refreshAll()
        #expect(h.defaults.stringArray(forKey: AppStorageKeys.podcastFreeTwinDeclined)?.contains(show.id) != true)
        let searched = h.defaults.dictionary(forKey: AppStorageKeys.podcastFreeTwinSearched) as? [String: [String]]
        #expect(searched?[show.id] == nil)
    }

    // MARK: - Wiring

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("The show asks through the notice; past the twin only the switch follows", .needsTheSources)
    func wiring() throws {
        let seite = try sourceText("Sources/Views/Podcasts/PodcastShowView.swift")
        for teil in ["freeTwin: subs.freeTwinOffer(show)", "subs.switchToFreeTwin(showId:", "subs.declineFreeTwin(show)"] {
            #expect(seite.contains(teil), "Seite ohne \(teil)")
        }
        let hinweis = try sourceText("Sources/Views/Podcasts/ShowAccessRefusedBanner.swift")
        #expect(hinweis.contains("show-access-free-twin-switch") && hinweis.contains("show-access-free-twin-no"))
        let speicher = try sourceText("Sources/Providers/PodcastSubscriptions.swift")
        #expect(speicher.components(separatedBy: "allowingFreeTwinOf").count == 3,
                "die Erklaerung am Parameter und genau ein Rufer")
        #expect(speicher.components(separatedBy: "rememberFreeTwin(").count == 4,
                "die Erklaerung und zwei Stellen, an denen die freie Adresse gesehen wird")
    }
}
#endif
