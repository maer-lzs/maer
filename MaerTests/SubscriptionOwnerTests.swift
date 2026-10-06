// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The subscriptions follow the account (decision of 03.10.2026, a new
/// beginning): at a switch the holder's shows rest on the shelf with their
/// episodes and the feeds waiting for a sign-in, nothing is unsubscribed,
/// and the way back brings every show back as it was. gpodder, whose
/// account is the device's, rests while another account holds them.
@MainActor
struct SubscriptionOwnerTests {
    private static func show(_ name: String, episodes: Int) -> PodcastShow {
        let url = "https://feeds.example/\(name).xml"
        let key = PodcastSubscriptions.feedKey(url)
        return PodcastShow(id: "feed:\(key)", title: name, author: nil, artworkURL: nil,
                           description: nil, feedURL: url,
                           episodes: (0..<episodes).map {
                               PodcastEpisode(guid: "rss:\(key):\($0)", title: "Folge \($0)",
                                              audioURL: "https://feeds.example/\(name)/\($0).mp3",
                                              pubDate: Double($0 + 1) * 1000, duration: 600)
                           })
    }

    private struct Rig {
        let folder: URL
        let suite: String
        let defaults: UserDefaults
        var database: MaerDatabase { MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path) }
        func store() async -> PodcastSubscriptions {
            let subs = PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                                            database: database, defaults: defaults, isTheApp: false)
            await subs.ensureLoaded()
            return subs
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func rig() throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subs-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "subs-owner-\(UUID().uuidString)"
        return Rig(folder: folder, suite: suite, defaults: try #require(UserDefaults(suiteName: suite)))
    }

    private func sorted(_ shows: [PodcastShow]) -> [PodcastShow] { shows.sorted { $0.id < $1.id } }

    @Test("A's Abos ruhen samt Folgen und wartenden Feeds, B sieht keine davon, nichts wird abbestellt, der Rueckweg bringt jede Sendung Zeile fuer Zeile zurueck")
    func theSubscriptionsRestUnderTheirAccount() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        try await PodcastRowStore(connection: try rig.database.connection())
            .replaceAll([Self.show("moor", episodes: 3), Self.show("hafen", episodes: 2)])
        FeedAdoptionPending.mark(feedKey: "wartet", feedURL: "https://feeds.example/wartet.xml",
                                 reason: .signIn, defaults: rig.defaults)
        let subs = await rig.store()
        #expect(subs.follow(owner: "account-a"), "the first account takes the shows")
        let ofA = sorted(subs.shows)
        let waitingOfA = subs.feedsNotFollowed
        #expect(ofA.count == 2 && waitingOfA.count == 1)

        #expect(subs.follow(owner: "account-b"))
        #expect(subs.shows.isEmpty, "B sees A's shows")
        #expect(subs.feedsNotFollowed.isEmpty, "B would follow A's waiting feeds")
        #expect(subs.subscriptionsForCloud() == [:], "the choice family reads A's shows under B")
        #expect(rig.defaults.object(forKey: AppStorageKeys.gpodderUserRemovedFeeds) == nil,
                "the switch told gpodder of removals")

        #expect(subs.follow(owner: "account-a"))
        #expect(sorted(subs.shows) == ofA, "A's shows did not come back as they were")
        #expect(subs.feedsNotFollowed == waitingOfA)

        // Row for row: a new start on the same rows reads A's shows.
        await subs.awaitPendingWrites()
        #expect(sorted(await rig.store().shows) == ofA)
    }

    @Test("ein offenes Ersetzen eines frueheren Laufs und ein drittes Konto: B's Ruhe traegt keine Sendung von A, A's bleiben bei A")
    func aThirdAccountAfterAnOpenReplacement() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let family = PodcastSubscriptions.shelfFamily
        // The replacement of a run before never landed: the rows hold A's.
        try await PodcastRowStore(connection: try rig.database.connection()).replaceAll([Self.show("moor", episodes: 2)])
        let shelf = try #require(rig.database.restingShelf)
        let restOfA = PodcastSubscriptions.Resting(shows: [Self.show("moor", episodes: 2)], waiting: nil)
        let restOfB = PodcastSubscriptions.Resting(shows: [Self.show("deich", episodes: 1)], waiting: nil)
        try shelf.lay(restOfA, of: family, owner: "account-a")
        try shelf.lay(restOfB, of: family, owner: "account-b")
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "open"), of: family)
        let subs = await rig.store()
        #expect(subs.shows.map(\.title) == ["moor"], "the precondition: A's shows are live")
        #expect(subs.follow(owner: "account-c"))
        #expect(try shelf.rest(PodcastSubscriptions.Resting.self, of: family, owner: "account-b") == restOfB,
                "A's shows were laid as B's")
        #expect(try shelf.rest(PodcastSubscriptions.Resting.self, of: family, owner: "account-a") == restOfA)
        #expect(subs.shows.isEmpty, "C sees a show of another account")
    }

    @Test("das Ersetzen der Abos landet mit seiner Marke, erst dann settled der Halter; ein Neustart davor ersetzt nicht noch einmal, was B danach abonnierte")
    func theReplacementLandsWithItsMark() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let family = PodcastSubscriptions.shelfFamily
        try await PodcastRowStore(connection: try rig.database.connection()).replaceAll([Self.show("moor", episodes: 2)])
        let shelf = try #require(rig.database.restingShelf)
        let subs = await rig.store()
        #expect(subs.follow(owner: "account-a"))
        #expect(subs.follow(owner: "account-b"))
        let name = try #require(try shelf.holding(of: family)?.replacement)
        await subs.awaitPendingWrites()
        #expect(try OwnerMark.stands(family: family, replacement: name, database: rig.database),
                "the rows of the replacement landed without its mark")
        #expect(try shelf.holding(of: family) == .init(owner: "account-b"), "the holding did not settle with the mark")

        // B subscribes; then a restart finds the holding unsettled.
        subs._testFeedFetcher = { _ in .show(Self.show("deich", episodes: 1)) }
        try #require(await subs.subscribe(urlString: "https://feeds.example/deich.xml", notesCloud: false))
        await subs.awaitPendingWrites()
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: name), of: family)
        let restarted = await rig.store()
        #expect(restarted.follow(owner: "account-b"))
        #expect(restarted.shows.map(\.title) == ["deich"], "a landed replacement was done again over B's subscription")
        #expect(try shelf.holding(of: family) == .init(owner: "account-b"))
    }

    @Test("solange der Bestand nicht geladen ist, ruht nichts und die Runde der Wahlen haelt an")
    func anUnloadedStockHoldsTheChoices() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let subs = await rig.store()
        #expect(subs.follow(owner: "account-a"))
        subs._testSetLoaded(false)
        #expect(!subs.follow(owner: "account-b"), "an unloaded stock was handed over")
        #expect(try rig.database.restingShelf?.holding(of: PodcastSubscriptions.shelfFamily) == .init(owner: "account-a"))

        // The choice runner asks the subscriptions first and holds its round.
        var scope: String? = "account-a"
        let cloud = UserChoiceFakeCloud()
        let sync = UserChoiceCloudSync(defaults: rig.defaults, cloud: cloud, syncEnabled: { true },
                                       identity: { scope }, shelf: RestingShelf(directory: rig.folder.appendingPathComponent("choices")))
        sync.sourcesAdopted = {}
        sync.subscriptionsFollow = { subs.follow(owner: $0) }
        rig.defaults.set("title", forKey: "librarySortOption")
        scope = "account-b"
        sync.noteScalar(key: "librarySortOption", value: "title")
        sync.reconcile()
        #expect(cloud.storage.isEmpty, "the round ran while the subscriptions could not follow")
    }

    @Test("gpodder ruht, solange ein anderes Konto die Abos haelt als das, fuer das es lief", .needsTheSources)
    func gpodderRestsUnderAnotherAccount() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gpodder-rest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = RestingShelf(directory: folder)
        #expect(GPodderSync.followsTheSubscriptions(on: shelf), "no holder yet: gpodder runs")
        try shelf.setHolding(.init(owner: "account-a"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.followsTheSubscriptions(on: shelf), "gpodder takes the first holder")
        try shelf.setHolding(.init(owner: "account-b"), of: PodcastSubscriptions.shelfFamily)
        #expect(!GPodderSync.followsTheSubscriptions(on: shelf), "gpodder ran under another account")
        try shelf.setHolding(.init(owner: "account-a"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.followsTheSubscriptions(on: shelf))

        let round = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderSync.swift"), encoding: .utf8))
        let start = try #require(round.range(of: "func reconcile() async -> Report {"))
        let head = round[start.upperBound...].prefix(400)
        #expect(head.contains("guard Self.followsTheSubscriptions(on: MaerDatabase.restingShelf) else { return report }"),
                "the gpodder round does not ask whose subscriptions these are")
    }

    @Test("auch der Einzel-Push einer Wiedergabe an gpodder ruht unter einem anderen Konto, still", .needsTheSources)
    func gpodderPlaybackPushRestsToo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gpodder-push-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = RestingShelf(directory: folder)
        try shelf.setHolding(.init(owner: "account-a"), of: PodcastSubscriptions.shelfFamily)
        #expect(GPodderSync.followsTheSubscriptions(on: shelf, quietly: true))
        try shelf.setHolding(.init(owner: "account-b"), of: PodcastSubscriptions.shelfFamily)
        #expect(!GPodderSync.followsTheSubscriptions(on: shelf, quietly: true), "the quiet question answers otherwise")

        let sync = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderSync.swift"), encoding: .utf8))
        let start = try #require(sync.range(of: "func notePlayback(itemId: String, position: Double, duration: Double) {"))
        let head = sync[start.upperBound...].prefix(300)
        #expect(head.contains("guard Self.followsTheSubscriptions(on: MaerDatabase.restingShelf, quietly: true) else { return }"),
                "a playback under another account pushes to gpodder")
    }
}
#endif
