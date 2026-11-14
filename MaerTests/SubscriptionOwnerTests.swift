// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The subscriptions follow the account (a new
/// beginning): at a switch the holder's shows rest on the shelf with their
/// episodes and the feeds waiting for a sign-in, nothing is unsubscribed,
/// and the way back brings every show back as it was. gpodder, whose
/// account is the device's, rests while another account holds them.
@MainActor
struct SubscriptionOwnerTests {
    private static func show(_ name: String, episodes: Int) -> PodcastShow {
        let url = "https://feeds.example/\(name).xml"
        let key = PodcastIdentity.feedKey(url)
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

    @Test("A's subscriptions rest together with episodes and waiting feeds, B sees none of them, nothing is unsubscribed, the way back brings every show back row for row")
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

    @Test("rows that this build does not read rest with A, never stand under B and come back unread on the way back")
    func unreadRowsRestWithTheirAccount() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let moor = Self.show("moor", episodes: 2)
        try await PodcastRowStore(connection: try rig.database.connection()).replaceAll([moor])
        // A show of a later form with its episode, and an episode of a later
        // form under a show this build reads.
        let later = Data("a show in a form of a later build".utf8)
        let laterEpisode = Data("an episode in a form of a later build".utf8)
        let connection = try rig.database.connection()
        _ = try await connection.run("INSERT INTO show (id, position, payload) VALUES (?, ?, ?)",
                                     [.text("feed:later"), .integer(9), .blob(later)])
        _ = try await connection.run("INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, ?, ?, ?, ?)",
                                     [.text("later-1"), .text("feed:later"), .integer(0), .real(1), .blob(laterEpisode)])
        _ = try await connection.run("INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, ?, ?, ?, ?)",
                                     [.text("later-2"), .text(moor.id), .integer(5), .real(2), .blob(laterEpisode)])
        func undecoded() throws -> PodcastRowStore.RawRows {
            try PodcastRowStore.undecodedNow(reader: try #require(try rig.database.readerNow()))
        }
        let before = try undecoded()
        #expect(before.shows.map(\.id) == ["feed:later"] && before.episodes.map(\.guid) == ["later-1", "later-2"],
                "the precondition: one show and two episodes unread")
        let subs = await rig.store()
        #expect(subs.shows.map(\.title) == ["moor"])
        #expect(subs.follow(owner: "account-a"))
        // The unread rows are read off the main actor: the first round holds,
        // a later one hands over.
        #expect(!subs.follow(owner: "account-b"), "the hand-over read every episode on the main actor")
        var handed = false
        for _ in 0..<100 where !handed {
            try await Task.sleep(for: .milliseconds(20))
            handed = subs.follow(owner: "account-b")
        }
        #expect(handed, "the hand-over never came after the read")
        await subs.awaitPendingWrites()
        let shelf = try #require(rig.database.restingShelf)
        let rest = try #require(try shelf.rest(PodcastSubscriptions.Resting.self, of: PodcastSubscriptions.shelfFamily, owner: "account-a"))
        #expect(rest.unread == before, "A's unread rows did not rest with A")
        #expect(try undecoded().isEmpty, "A's unread rows stand under B")
        #expect(subs.shows.isEmpty)

        // After each replacement the unread rows are read again (the memo
        // follows the table, not the intent): a hand-over holds once, a later
        // round goes.
        func handOver(to owner: String) async throws -> Bool {
            var handed = subs.follow(owner: owner)
            for _ in 0..<100 where !handed {
                try await Task.sleep(for: .milliseconds(20))
                handed = subs.follow(owner: owner)
            }
            return handed
        }
        #expect(try await handOver(to: "account-a"))
        await subs.awaitPendingWrites()
        #expect(try undecoded() == before, "A's unread rows did not come back as they were")
        #expect(subs.startIncomplete, "this process takes its rows for whole after rows came back unread")
        #expect(sorted(await rig.store().shows) == [moor], "the way back lost A's show")

        // The rows read before still name the unread episode under moor.
        // Unsubscribed, moor takes it out of the rows (cascade); a switch and
        // the way back must not try to put it back under a show that is gone,
        // or the foreign key fails the whole replacement at every start.
        subs.unsubscribe(id: moor.id, notesCloud: false)
        await subs.awaitPendingWrites()
        #expect(try undecoded().episodes.map(\.guid) == ["later-1"], "the precondition: the cascade took the episode under moor")
        #expect(try await handOver(to: "account-b"))
        await subs.awaitPendingWrites()
        let restAgain = try #require(try shelf.rest(PodcastSubscriptions.Resting.self, of: PodcastSubscriptions.shelfFamily, owner: "account-a"))
        #expect(restAgain.unread?.episodes.map(\.guid) == ["later-1"], "an episode whose show is gone rested with A")
        #expect(try await handOver(to: "account-a"))
        await subs.awaitPendingWrites()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try shelf.holding(of: PodcastSubscriptions.shelfFamily) == .init(owner: "account-a"),
                "the replacement of the way back did not land")
        #expect(try undecoded().shows.map(\.id) == ["feed:later"] && undecoded().episodes.map(\.guid) == ["later-1"],
                "the unread rows of the way back did not land")
    }

    @Test("an unread episode package inserts only episodes whose show stands")
    func carriedEpisodesNeedTheirShow() {
        let raw = PodcastRowStore.RawRows(
            shows: [.init(id: "feed:raw", position: 0, payload: Data("x".utf8))],
            episodes: [.init(guid: "under-raw", showId: "feed:raw", position: 0, pubDate: 1, payload: Data("y".utf8)),
                       .init(guid: "under-kept", showId: "feed:kept", position: 0, pubDate: 1, payload: Data("y".utf8)),
                       .init(guid: "under-gone", showId: "feed:gone", position: 0, pubDate: 1, payload: Data("y".utf8))])
        let statements = PodcastRowStore.carriedRows(leaving: .init(), coming: raw, keptShows: ["feed:kept"], keptEpisodes: [])
        let inserted = statements.filter { $0.sql.contains("INTO episode") }.compactMap { $0.params.first?.string }
        #expect(inserted == ["under-raw", "under-kept"], "an episode without its show was inserted: \(inserted)")
        #expect(raw.standing(under: ["feed:kept"]).episodes.map(\.guid) == ["under-raw", "under-kept"])
    }

    /// An unfinished replacement of a run before, met at a start whose rows
    /// hold a row this build cannot read: the hand-over asks `replace`
    /// without `current()` before, so the read of the unread rows starts
    /// there. The first round holds and touches nothing; a later one replaces.
    @Test("an interrupted replacement over an unread row holds without touching anything, and replaces afterwards")
    func anUnfinishedReplacementOverAnUnreadRowTouchesNothingFirst() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let moor = Self.show("moor", episodes: 1)
        try await PodcastRowStore(connection: try rig.database.connection()).replaceAll([moor])
        _ = try await rig.database.connection().run("INSERT INTO show (id, position, payload) VALUES (?, ?, ?)",
                                                    [.text("feed:later"), .integer(9), .blob(Data("a later form".utf8))])
        let shelf = try #require(rig.database.restingShelf)
        let family = PodcastSubscriptions.shelfFamily
        try shelf.lay(PodcastSubscriptions.Resting(shows: [Self.show("deich", episodes: 1)], waiting: nil),
                      of: family, owner: "account-b")
        try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "open"), of: family)
        let subs = await rig.store()
        #expect(subs.shows.map(\.title) == ["moor"], "the precondition: the rows of before are live")
        #expect(!subs.follow(owner: "account-b"), "the first round did not hold for the unread rows")
        #expect(subs.shows.map(\.title) == ["moor"], "a replacement that threw swapped the shows")
        var handed = false
        for _ in 0..<100 where !handed {
            try await Task.sleep(for: .milliseconds(20))
            handed = subs.follow(owner: "account-b")
        }
        #expect(handed, "the replacement never came after the read")
        await subs.awaitPendingWrites()
        #expect(subs.shows.map(\.title) == ["deich"])
        #expect(try PodcastRowStore.undecodedNow(reader: try #require(try rig.database.readerNow())).shows.isEmpty,
                "the unread row stands under the account replaced in")
    }

    /// After a replacement the memo of the unread rows does not say what
    /// should stand: the next question reads the table. A row that appears
    /// there after the hand-over rests with its account at the next one.
    @Test("after a replacement the next question reads the table anew, instead of believing the memo of the intent")
    func theUnreadMemoFollowsTheTableAfterAReplacement() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        try await PodcastRowStore(connection: try rig.database.connection()).replaceAll([Self.show("moor", episodes: 1)])
        _ = try await rig.database.connection().run("INSERT INTO show (id, position, payload) VALUES (?, ?, ?)",
                                                    [.text("feed:early"), .integer(9), .blob(Data("a later form".utf8))])
        let subs = await rig.store()
        #expect(subs.follow(owner: "account-a"))
        func handOver(to owner: String) async throws -> Bool {
            var handed = subs.follow(owner: owner)
            for _ in 0..<100 where !handed {
                try await Task.sleep(for: .milliseconds(20))
                handed = subs.follow(owner: owner)
            }
            await subs.awaitPendingWrites()
            return handed
        }
        #expect(try await handOver(to: "account-b"), "the precondition: the hand-over to B")
        // A row appears under B after the hand-over, as a write of a later
        // build would leave it.
        _ = try await rig.database.connection().run("INSERT INTO show (id, position, payload) VALUES (?, ?, ?)",
                                                    [.text("feed:late"), .integer(10), .blob(Data("a later form".utf8))])
        #expect(try await handOver(to: "account-a"))
        let shelf = try #require(rig.database.restingShelf)
        let restOfB = try #require(try shelf.rest(PodcastSubscriptions.Resting.self, of: PodcastSubscriptions.shelfFamily, owner: "account-b"))
        #expect(restOfB.unread?.shows.map(\.id) == ["feed:late"], "B's unread row did not rest with B: \(String(describing: restOfB.unread))")
    }

    /// An unsubscribe given while a show stood narrows its own write; a save
    /// queued afterwards that is refused empty speaks as a suspicion and
    /// leaves its note.
    @Test("with the subscriptions a devalued permission covers only its own write")
    func aNarrowedUnsubscribeCoversItsOwnWrite() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        try await PodcastRowStore(connection: try rig.database.connection())
            .replaceAll([Self.show("moor", episodes: 1), Self.show("deich", episodes: 1)])
        let subs = await rig.store()
        #expect(subs.shows.count == 2, "the precondition: two shows stand")
        let note = rig.folder.appendingPathComponent("podcast_subscriptions.json").appendingPathExtension("wipe-refused.txt")
        subs.unsubscribe(id: try #require(subs.shows.first).id, notesCloud: false)
        subs._seedForUITest([])
        _ = await RowKeepers.awaitAll()
        #expect(subs.lastWipeRefusal == .narrowedPermission, "\(String(describing: subs.lastWipeRefusal))")
        #expect(!FileManager.default.fileExists(atPath: note.path), "the narrowed refusal left a note")
        subs._testSave()
        _ = await RowKeepers.awaitAll()
        #expect(subs.lastWipeRefusal == .suspected, "a later save rode on the narrowing: \(String(describing: subs.lastWipeRefusal))")
        #expect(FileManager.default.fileExists(atPath: note.path), "the suspicion left no note")
    }

    /// Why both filters stand: the database refuses an episode whose show
    /// is not there (`foreign_keys=ON`, `REFERENCES show(id)`), and the whole
    /// transaction with it, so an unfiltered carry would break the
    /// replacement on every start.
    @Test("an episode without its show in apply(also:) throws, and nothing from the same transaction lands")
    func anEpisodeWithoutItsShowBreaksTheTransaction() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let rows = try await PodcastRowStore(connection: try rig.database.connection())
        try await rows.replaceAll([Self.show("moor", episodes: 2)])
        let before = try await rows.counts()
        // Told the show is kept, the carry inserts the episode as it stands.
        let orphan = PodcastRowStore.RawRows(shows: [], episodes: [
            .init(guid: "under-gone", showId: "feed:gone", position: 0, pubDate: 1, payload: Data("y".utf8))])
        let carried = PodcastRowStore.carriedRows(leaving: .init(), coming: orphan, keptShows: ["feed:gone"], keptEpisodes: [])
        let fresh = PodcastRowStore.RawRows(shows: [.init(id: "feed:fresh", position: 9, payload: Data("x".utf8))], episodes: [])
        let alongside = PodcastRowStore.carriedRows(leaving: .init(), coming: fresh, keptShows: [], keptEpisodes: [])
        #expect(carried.contains { $0.sql.contains("INTO episode") }, "the precondition: the episode is inserted")
        await #expect(throws: (any Error).self, "an episode without its show was written") {
            try await rows.apply(PodcastRowDiff(), also: alongside + carried)
        }
        #expect(try await rows.counts() == before, "a statement of the broken transaction landed")
    }

    @Test("an open replacement of an earlier run and a third account: B's rest carries no show of A, A's stay with A")
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

    @Test("the replacement of the subscriptions lands with its mark, only then the holder settles; a restart before it does not replace again what B subscribed to afterwards")
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

    @Test("a switch with sync off and no holder: A's subscriptions and choices rest under A, B sees none of them")
    func aSwitchWithSyncOffAndNoHolder() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        try await PodcastRowStore(connection: try rig.database.connection()).replaceAll([Self.show("moor", episodes: 2)])
        let subs = await rig.store()
        rig.defaults.set("title", forKey: "librarySortOption")
        let shelf = try #require(rig.database.restingShelf)
        let sync = UserChoiceCloudSync(defaults: rig.defaults, cloud: UserChoiceFakeCloud(), syncEnabled: { false },
                                       identity: { "account-b" }, shelf: shelf, idFormSettled: { true })
        sync.subscriptionsFollow = { subs.follow(owner: $0, previous: $1) }
        sync.sourcesAdopted = {}
        sync.followOwner(previous: "account-a")
        let showsOfA = try shelf.rest(PodcastSubscriptions.Resting.self, of: PodcastSubscriptions.shelfFamily, owner: "account-a")
        let choicesOfA = try shelf.rest(UserChoiceCloudSync.Resting.self, of: "choices", owner: "account-a")
        #expect(showsOfA?.shows.map(\.title) == ["moor"], "A's shows do not rest under A")
        #expect(subs.shows.isEmpty, "B sees A's shows")
        #expect(choicesOfA?.values["librarySortOption"] != nil, "A's choice does not rest under A")
        #expect(rig.defaults.object(forKey: "librarySortOption") == nil, "B sees A's choice")
        await subs.awaitPendingWrites()
    }

    @Test("as long as the stock is not loaded, nothing rests and the round of the choices holds")
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
                                       identity: { scope }, shelf: RestingShelf(directory: rig.folder.appendingPathComponent("choices")), idFormSettled: { true })
        sync.sourcesAdopted = {}
        sync.subscriptionsFollow = { subs.follow(owner: $0, previous: $1) }
        rig.defaults.set("title", forKey: "librarySortOption")
        scope = "account-b"
        sync.noteScalar(key: "librarySortOption", value: "title")
        sync.reconcile()
        #expect(cloud.storage.isEmpty, "the round ran while the subscriptions could not follow")
    }

    @Test("gpodder rests as long as another account holds the subscriptions than the one it ran for", .needsTheSources)
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

    @Test("the single push of a playback to gpodder also rests under another account, silently", .needsTheSources)
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
