// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every local subscription asks Audiobookshelf first: a show held there
/// is not subscribed here, and an Audiobookshelf that could not be read is
/// no "not there".
@MainActor
struct LocalSubscribeDoorTests {
    @MainActor final class Calls {
        var hosts: [String] = []
        var reads = 0
    }

    @Test("the answer: held there, not there, or unread; a known show is held, read or not")
    func theThreeAnswers() {
        let titles = ["k": "Show"]
        #expect(ServerHolding.of(feedKey: "k", read: true, serverTitles: titles) == .held(title: "Show"))
        #expect(ServerHolding.of(feedKey: "k", read: false, serverTitles: titles) == .held(title: "Show"))
        #expect(ServerHolding.of(feedKey: "x", read: true, serverTitles: titles) == .notThere)
        #expect(ServerHolding.of(feedKey: "x", read: false, serverTitles: titles) == .unread)
    }

    @Test("the door: a show on Audiobookshelf is not subscribed here and not fetched, another one as before")
    func aShowOnTheServerIsNotSubscribedHere() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let onServer = "https://door-held.example/\(run)/feed.xml"
        let other = "https://door-other.example/\(run)/feed.xml"
        let calls = Calls()
        subs.serverShows = { [ServerHeldImportTests.serverShow(feedURL: onServer, title: "Server Show")] }
        subs.serverShowsRead = { true }
        subs._testFeedFetcher = { url in
            await MainActor.run { calls.hosts.append(url.host ?? "-") }
            return .show(BulkImportTests.show(url, title: "Other Show"))
        }
        let held = await subs.subscribeUnlessOnServer(urlString: onServer)
        #expect(held == .onServer(title: "Server Show"))
        #expect(!calls.hosts.contains("door-held.example"), "the server's show was fetched")
        #expect(!subs.shows.contains { $0.feedURL == onServer }, "the server's show was subscribed here")
        let followed = await subs.subscribeUnlessOnServer(urlString: other)
        #expect(followed == .subscribed, "a show not on the server was not subscribed")
        #expect(subs.shows.contains { $0.feedURL == other })
    }

    @Test("the door with unread Audiobookshelf: read first; if it stays unread, a mechanism subscribes nothing, once read the answer applies")
    func anUnreadServerIsReadFirstAndSetsOut() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let feed = "https://door-unread.example/\(run)/feed.xml"
        let calls = Calls()
        var read = false
        var heldThere: [PodcastShow] = []
        subs.serverShows = { heldThere }
        subs.serverShowsRead = { read }
        subs.readServerShows = { calls.reads += 1 }
        subs._testFeedFetcher = { url in
            await MainActor.run { calls.hosts.append(url.host ?? "-") }
            return .show(BulkImportTests.show(url, title: "Feed Show"))
        }
        let setOut = await subs.subscribeUnlessOnServer(urlString: feed, isSingleUserAct: false)
        #expect(setOut == .setOut, "an unread server was read as not there")
        #expect(calls.reads == 1, "the door did not read the server first")
        #expect(calls.hosts.isEmpty && subs.shows.isEmpty, "a show was subscribed while the server was unread")

        // The read finds the show on the server.
        subs.readServerShows = {
            calls.reads += 1
            read = true
            heldThere = [ServerHeldImportTests.serverShow(feedURL: feed, title: "Server Show")]
        }
        let held = await subs.subscribeUnlessOnServer(urlString: feed)
        #expect(held == .onServer(title: "Server Show"), "the answer after the read was not taken")
        #expect(calls.hosts.isEmpty && subs.shows.isEmpty)
    }

    @Test("the rules with unread Audiobookshelf: the person subscribes with a note, a mechanism pauses; the sync afterwards")
    func theRulesWhileTheServerIsUnread() {
        #expect(ServerHolding.whileUnread(byPerson: true) == .subscribeNoted)
        #expect(ServerHolding.whileUnread(byPerson: false) == .setOut)
        func settle(_ holding: ServerHolding, _ bridged: Bool = true,
                    _ stock: ServerHolding.StockRead = .whole, here: Bool = true) -> ServerHolding.Settle {
            ServerHolding.settle(holding, everyStateBridged: bridged, stock: stock, showHere: here)
        }
        #expect(settle(.notThere) == .noteGoes)
        #expect(settle(.unread) == .waits)
        #expect(settle(.held(title: "S")) == .handOver)
        #expect(settle(.held(title: "S"), false) == .keepsLocal, "a state without an episode there keeps the local subscription")
        #expect(settle(.held(title: "S"), here: false) == .noteGoes, "a show unsubscribed here kept its note")
        // A store not read whole answers nothing: no note goes, nothing is handed over.
        for stock in [ServerHolding.StockRead.unread, .incomplete] {
            for holding in [ServerHolding.notThere, .unread, .held(title: "S")] {
                for here in [true, false] {
                    #expect(settle(holding, true, stock, here: here) == .waits, "\(stock) \(holding) here=\(here)")
                }
            }
        }
    }

    /// The server reads in the start window, before the store has loaded,
    /// or after its start read failed: the show is missing from the memory
    /// only because nobody read it. The note stays, nothing is handed over,
    /// nothing goes; the next run settles.
    @Test("a sync over an unloaded or entirely unread store: the note stays, nothing goes, nothing is handed over")
    func aStoreNotReadAnswersNothing() async throws {
        for failure in ["unloaded", "readFailed"] {
            let (rig, state) = try await settling()
            defer { rig.cleanup() }
            let subs = rig.subs
            #expect(await subs.subscribeUnlessOnServer(urlString: rig.feed) == .subscribedUnchecked)
            let key = PodcastIdentity.feedKey(rig.feed)
            let heard = try #require(subs.shows.first { $0.feedURL == rig.feed }?.episodes.first)
            ListeningStore.store(heard.guid, entry: [600, 5_000_000, 1800], in: rig.defaults)
            let episode = state.hold(rig.feed, guid: PodcastIdentity.originalGuid(heard.guid))
            rig.server.episodeHandles[episode] = ServerEpisodeHandle(guid: PodcastIdentity.originalGuid(heard.guid),
                                                                     enclosure: nil)
            // The memory as an unread store holds it: the show is not there.
            let held = subs.shows
            subs._seedForUITest([])
            if failure == "unloaded" { subs._testSetLoaded(false) } else { subs._testRowsUnread() }
            await subs.settleUnchecked()
            let notes = subs.uncheckedFeedKeys()
            #expect(notes == [key], "\(failure): the note went over a store nobody read: \(notes)")
            #expect(rig.server.writes.isEmpty, "\(failure): a state was handed over")
            // Read again: the show is back and the note settles it.
            subs._seedForUITest(held)
            subs._testSetLoaded(true)
            if failure == "readFailed" { continue }
            await subs.settleUnchecked()
            #expect(rig.server.progress[episode]?.currentTime == 600, "the next run did not settle")
            #expect(!subs.shows.contains { $0.feedURL == rig.feed })
        }
    }

    /// Rows stood that did not decode: a heard state may stand in an episode
    /// the memory does not hold. The show is held there and every state the
    /// memory knows would bridge; still the local subscription stays.
    @Test("a sync over an incompletely read store does not take the local subscription and leaves the note in place")
    func anIncompleteStoreKeepsTheLocalSubscription() async throws {
        let (rig, state) = try await settling()
        defer { rig.cleanup() }
        let subs = rig.subs
        #expect(await subs.subscribeUnlessOnServer(urlString: rig.feed) == .subscribedUnchecked)
        let key = PodcastIdentity.feedKey(rig.feed)
        let heard = try #require(subs.shows.first { $0.feedURL == rig.feed }?.episodes.first)
        ListeningStore.store(heard.guid, entry: [600, 5_000_000, 1800], in: rig.defaults)
        // A state heard in an episode of the show the memory does not hold.
        let unreadEpisode = "\(rig.feed)#unread-\(UUID().uuidString.prefix(6))"
        ListeningStore.store(unreadEpisode, entry: [300, 5_000_000, 1800], in: rig.defaults)
        defer { ListeningStore.clearBackup(unreadEpisode, in: rig.defaults) }
        let episode = state.hold(rig.feed, guid: PodcastIdentity.originalGuid(heard.guid))
        rig.server.episodeHandles[episode] = ServerEpisodeHandle(guid: PodcastIdentity.originalGuid(heard.guid),
                                                                 enclosure: nil)
        subs._testRowsMissed()
        #expect(subs.startIncomplete, "the precondition: the rows hold more than the memory")
        await subs.settleUnchecked()
        #expect(subs.shows.contains { $0.feedURL == rig.feed }, "the local subscription went over rows nobody read")
        #expect(subs.uncheckedFeedKeys() == [key], "the note went")
        #expect(rig.server.writes.isEmpty, "a state was handed over from a store not read whole")
    }

    /// A store whose server is unread, then read and holding the feed with
    /// one episode the bridge can or cannot find.
    struct Settling {
        let subs: PodcastSubscriptions
        let defaults: UserDefaults
        let server: ServerHeldImportTests.FakeServer
        let feed: String
        let cleanup: () -> Void
    }

    func settling() async throws -> (Settling, SettleSwitch) {
        let (subs, defaults, cleanup) = try await BulkImportTests.storeAndDefaults()
        let run = UUID().uuidString.prefix(8)
        let feed = "https://settle-\(run).example/feed.xml"
        let state = SettleSwitch()
        subs.serverShows = { state.heldThere }
        subs.serverShowsRead = { state.read }
        subs.readServerShows = {}
        subs._testFeedFetcher = { url in .show(BulkImportTests.show(url, title: "Feed Show")) }
        let server = ServerHeldImportTests.FakeServer()
        subs.serverSide = { server }
        return (Settling(subs: subs, defaults: defaults, server: server, feed: feed, cleanup: cleanup), state)
    }

    @MainActor final class SettleSwitch {
        var read = false
        var heldThere: [PodcastShow] = []
        /// The server holds the feed with one episode, found by `guid`.
        func hold(_ feed: String, guid: String) -> String {
            let episode = "abspod:st:e0"
            heldThere = [PodcastShow(id: "abspod:st", title: "Feed Show", author: nil, artworkURL: nil,
                                     description: nil, feedURL: feed,
                                     episodes: [PodcastEpisode(guid: episode, title: "e0", audioURL: "/api/items/st/e0",
                                                               pubDate: 1, duration: 1800)])]
            read = true
            return episode
        }
    }

    /// The person's tap while the server is unread subscribes here with a
    /// note, a mechanism sets out; the next read hands the heard state to
    /// the server's episode (600 s against nothing there) and the local
    /// subscription goes, without a tombstone for the cloud.
    @Test("a tap with unread Audiobookshelf subscribes here with a note; the next read hands the played state to the episode there and takes the local subscription")
    func aTapWhileUnreadHandsOverOnTheNextRead() async throws {
        let (rig, state) = try await settling()
        defer { rig.cleanup() }
        let subs = rig.subs
        #expect(await subs.subscribeUnlessOnServer(urlString: rig.feed, isSingleUserAct: false) == .setOut,
                "a mechanism subscribes while the server is unread")
        #expect(subs.shows.isEmpty)
        #expect(await subs.subscribeUnlessOnServer(urlString: rig.feed) == .subscribedUnchecked,
                "the person's tap was refused while the server is unread")
        let key = PodcastIdentity.feedKey(rig.feed)
        #expect(subs.uncheckedFeedKeys() == [key], "the subscription is not noted")
        // The subscription stands in the rows before the server is read.
        await subs.awaitPendingWrites()
        #expect(await subs._testRowCounts()?.shows == 1, "the precondition: the subscription stands in the rows")
        let local = try #require(subs.shows.first { $0.feedURL == rig.feed })
        let heard = try #require(local.episodes.first)
        ListeningStore.store(heard.guid, entry: [600, 5_000_000, 1800], in: rig.defaults)
        let episode = state.hold(rig.feed, guid: PodcastIdentity.originalGuid(heard.guid))
        rig.server.episodeHandles[episode] = ServerEpisodeHandle(guid: PodcastIdentity.originalGuid(heard.guid),
                                                                 enclosure: nil)
        await subs.settleUnchecked()
        #expect(rig.server.progress[episode]?.currentTime == 600, "the heard state did not reach the server's episode")
        #expect(!subs.shows.contains { $0.feedURL == rig.feed }, "the local subscription stays beside the server's")
        // The only subscription here: the hand-over empties the rows on
        // purpose, so a restart does not bring it back beside the server's.
        await subs.awaitPendingWrites()
        #expect(subs.lastWipeRefusal == nil, "the hand-over of the only subscription was refused as a wipe")
        #expect(await subs._testRowCounts() == PodcastRowStore.Counts(shows: 0, episodes: 0),
                "the handed-over subscription stays in the rows and comes back at the next start")
        #expect(subs.uncheckedFeedKeys().isEmpty, "the note stays")
        #expect(ListeningStore.backup(heard.guid, in: rig.defaults)?.first == 600, "the local state was dropped")
    }

    /// The other way round: the server knows the episode later (900 s), so
    /// its state stays; the local subscription still goes, every state was
    /// decided there.
    @Test("the sync when the server played later: its state stays, nothing is written")
    func aNewerServerStateStays() async throws {
        let (rig, state) = try await settling()
        defer { rig.cleanup() }
        let subs = rig.subs
        #expect(await subs.subscribeUnlessOnServer(urlString: rig.feed) == .subscribedUnchecked)
        let heard = try #require(subs.shows.first { $0.feedURL == rig.feed }?.episodes.first)
        ListeningStore.store(heard.guid, entry: [600, 5_000_000, 1800], in: rig.defaults)
        let episode = state.hold(rig.feed, guid: PodcastIdentity.originalGuid(heard.guid))
        rig.server.episodeHandles[episode] = ServerEpisodeHandle(guid: PodcastIdentity.originalGuid(heard.guid),
                                                                 enclosure: nil)
        rig.server.progress[episode] = BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 9_000_000,
                                                    currentTime: 900)
        await subs.settleUnchecked()
        #expect(rig.server.writes.isEmpty, "an older local state was written over the server's")
        #expect(rig.server.progress[episode]?.currentTime == 900)
        #expect(!subs.shows.contains { $0.feedURL == rig.feed })
    }

    /// Without the bridge (the server's episode carries another guid) the
    /// heard state has nowhere to go: the local subscription and its note
    /// stay. Not held there, the note goes and the subscription stays.
    @Test("the sync without a bridge keeps the local subscription; if the show is not there, only the note drops")
    func withoutTheBridgeTheLocalSubscriptionStays() async throws {
        let (rig, state) = try await settling()
        defer { rig.cleanup() }
        let subs = rig.subs
        #expect(await subs.subscribeUnlessOnServer(urlString: rig.feed) == .subscribedUnchecked)
        let heard = try #require(subs.shows.first { $0.feedURL == rig.feed }?.episodes.first)
        ListeningStore.store(heard.guid, entry: [600, 5_000_000, 1800], in: rig.defaults)
        let episode = state.hold(rig.feed, guid: "another-guid")
        rig.server.episodeHandles[episode] = ServerEpisodeHandle(guid: "another-guid", enclosure: nil)
        await subs.settleUnchecked()
        #expect(subs.shows.contains { $0.feedURL == rig.feed }, "the local subscription went without its states")
        #expect(rig.server.writes.isEmpty)
        #expect(subs.uncheckedFeedKeys() == [PodcastIdentity.feedKey(rig.feed)], "the note went")
        // The server read again, and it does not hold the feed.
        state.heldThere = []
        await subs.settleUnchecked()
        #expect(subs.shows.contains { $0.feedURL == rig.feed })
        #expect(subs.uncheckedFeedKeys().isEmpty, "the note stays for a show the server does not hold")
    }

    @Test("the import with unread Audiobookshelf: read first, then pause, nothing subscribed, the result says so")
    func anImportSetsOutWhileTheServerIsUnread() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let feed = "https://import-unread.example/\(run)/feed.xml"
        let calls = Calls()
        subs.serverShows = { [] }
        subs.serverShowsRead = { false }
        subs.readServerShows = { calls.reads += 1 }
        subs._testFeedFetcher = { url in
            await MainActor.run { calls.hosts.append(url.host ?? "-") }
            return .show(BulkImportTests.show(url, title: "Feed Show"))
        }
        let result = await subs.importForeignLibrary(ForeignLibrary(feedURLs: [feed], states: []))
        #expect(result.serverUnread, "the import read an unread server as empty")
        #expect(calls.reads == 1, "the import did not read the server first")
        #expect(calls.hosts.isEmpty && subs.shows.isEmpty && result.subscribed == 0, "a show was subscribed while the server was unread")
    }

    @Test("gpodder: a show on Audiobookshelf is not subscribed locally over three rounds, and gpodder gets no removal from this device")
    func gpodderGetsNoRemovalForAShowOnTheServer() async throws {
        let subs = PodcastSubscriptions.shared
        await subs.ensureLoaded()
        subs._testSetLoaded(true)
        let run = UUID().uuidString.prefix(8)
        let feed = "https://gpodder-held.example/\(run)/feed.xml"
        let keys = [AppStorageKeys.gpodderLastSyncedFeeds, AppStorageKeys.gpodderPendingRemoveLocal,
                    AppStorageKeys.gpodderPendingRemoveServer, AppStorageKeys.gpodderUserRemovedFeeds]
        let kept = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        let shows = subs.serverShows, read = subs.serverShowsRead
        let calls = Calls()
        subs.serverShows = { [ServerHeldImportTests.serverShow(feedURL: feed, title: "Server Show")] }
        subs.serverShowsRead = { true }
        subs._testFeedFetcher = { url in
            await MainActor.run { calls.hosts.append(url.host ?? "-") }
            return .show(BulkImportTests.show(url, title: "Feed Show"))
        }
        defer {
            subs.serverShows = shows
            subs.serverShowsRead = read
            subs._testFeedFetcher = nil
            for (key, value) in kept { UserDefaults.standard.set(value, forKey: key) }
        }
        // Three rounds: a removal derived toward the server waits for a
        // second confirming round, so only the third could send one.
        let gpodder = SubscriptionFamilyServerTests.FakeGPodder([feed])
        for _ in 0..<3 { _ = try await GPodderSync.shared.syncSubscriptions(gpodder) }
        #expect(!subs.shows.contains { $0.feedURL == feed }, "the server's show was subscribed here")
        #expect(calls.hosts.isEmpty, "the server's show was fetched")
        #expect(gpodder.server.contains(feed), "gpodder lost the show")
        #expect(gpodder.uploads.allSatisfy { $0.remove.isEmpty }, "this device sent gpodder a removal: \(gpodder.uploads)")
    }

    @Test("the family: a show on Audiobookshelf is not subscribed, not fetched and not marked as not followed; another one as before")
    func theFamilyFollowsAShowOnTheServerThere() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let onServer = "https://family-held.example/\(run)/feed.xml"
        let other = "https://family-other.example/\(run)/feed.xml"
        let calls = Calls()
        subs.serverShows = { [ServerHeldImportTests.serverShow(feedURL: onServer, title: "Server Show")] }
        subs._testFeedFetcher = { url in
            await MainActor.run { calls.hosts.append(url.host ?? "-") }
            return .show(BulkImportTests.show(url, title: "Other Show"))
        }
        subs.adoptCloudSubscriptions(added: [(feedURL: onServer, t: 1000), (feedURL: other, t: 1000)], removed: [])
        for _ in 0..<200 where !subs.shows.contains(where: { $0.feedURL == other }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(subs.shows.contains { $0.feedURL == other }, "the precondition: the other feed was followed")
        #expect(!subs.shows.contains { $0.feedURL == onServer }, "the server's show was subscribed here")
        #expect(!calls.hosts.contains("family-held.example"), "the server's show was fetched")
        #expect(subs.feedsNotFollowed[PodcastIdentity.feedKey(onServer)] == nil, "the server's show was marked as not followed")
    }

    @Test("Badge and source page read Audiobookshelf before the choice between server and here, and the badge reports a pause", .needsTheSources)
    func theSurfacesReadBeforeTheyChoose() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let badge = try #require(ABSPodcastRefreshTests.body(
            of: "static func subscribe(_ feedURL: String) async {", in: try code("Sources/Views/Podcasts/PodcastComponents.swift")))
        let page = try #require(ABSPodcastRefreshTests.body(
            of: "private func performSubscribe(feedURL: String) async -> Bool {", in: try code("Sources/Views/PodcastSourceView.swift")))
        for (name, body) in [("badge", badge), ("source page", page)] {
            let read = try #require(body.range(of: "readAbsShows()"), "the \(name) does not read the server")
            let choice = try #require(body.range(of: "hasPodcasts"))
            #expect(read.upperBound <= choice.lowerBound, "the \(name) chooses before it reads")
        }
        // The badge hands every answer to `settle`, which says a set out.
        let settle = try #require(ABSPodcastRefreshTests.body(
            of: "static func settle(", in: try code("Sources/Views/Podcasts/PodcastComponents.swift")))
        #expect(badge.contains("settle(tap, feedURL: feedURL)"), "the badge keeps an answer from settle")
        let squeezedSettle = settle.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(squeezedSettle.contains("case .setOut: subs.serverUnreadNotice = true"), "the badge sets out in silence")
        let host = try code("Sources/Views/Podcasts/PodcastSubscribeNoticeHost.swift")
        #expect(host.contains("subs.serverUnreadNotice"), "no host says the set out")
    }

    /// The catalog page's "local only" feed goes through the door too: a show
    /// Audiobookshelf holds is refused with that sentence, an unread server
    /// says so, nothing is subscribed a second time.
    @Test("Subscription as a feed from the catalog page: goes through the door, if the show is on Audiobookshelf, it refuses", .needsTheSources)
    func theCatalogLocalFeedGoesThroughTheDoor() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogDetailExtras.swift"), encoding: .utf8))
        let body = try #require(ABSPodcastRefreshTests.body(of: "private func subscribeLocally() {", in: page))
        #expect(body.contains("subscribeUnlessOnServer(urlString: rss)"), "the local feed passes the door")
        let held = try #require(body.range(of: "case .onServer:"), "a show held on Audiobookshelf is not handled")
        let sentence = try #require(body.range(of: "localRefusal = String(localized: \"Subscribed on Audiobookshelf\")"),
                                    "a show held on Audiobookshelf is not refused with its sentence")
        #expect(held.upperBound < sentence.lowerBound, "the sentence belongs to another case")
        #expect(body.contains("case .setOut:"), "an unread server is not said")
        // The button is the person's own tap: while the server is unread it
        // subscribes here with a note, like every tap (14a).
        #expect(body.contains("case .subscribed, .subscribedUnchecked:"), "a noted subscription is not taken as subscribed")
        #expect(!body.contains("isSingleUserAct: false"), "the button calls the door as a mechanism")
        #expect(page.contains("HintLine(systemImage: \"exclamationmark.triangle.fill\") { Text(localRefusal) }"),
                "the refusal is not shown beside the menu")
    }

    /// Who may still call `subscribe(urlString:` past the door, and why.
    static let stock: [String: (count: Int, reason: String)] = [
        "PodcastSubscriptions.swift": (1, "the door itself"),
    ]

    @Test("only the named places subscribe past the door", .needsTheSources)
    func onlyTheNamedPlacesPassTheDoor() throws {
        var found: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.directSubscribes(in: SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8)))
            if count > 0 { found[file.lastPathComponent] = count }
        }
        #expect(found["PodcastSubscriptions.swift"] != nil, "the fence read the sources")
        #expect(found == Self.stock.mapValues(\.count), "a subscription past the door, or a named one gone: \(found)")
        // Calibration: a call counts, the declaration and the door's name do not.
        #expect(Self.directSubscribes(in: """
            func subscribe(urlString: String) async -> Bool {
            _ = await subs.subscribe(urlString: raw, notesCloud: true)
            _ = await subs.subscribeUnlessOnServer(urlString: raw)
            """) == 1)
    }

    /// Calls of `subscribe(urlString:` in `code`, without its declaration.
    nonisolated static func directSubscribes(in code: String) -> Int {
        code.split(separator: "\n").reduce(0) { total, line in
            guard !line.contains("func subscribe(urlString:") else { return total }
            return total + line.matches(of: #/subscribe\(urlString:/#).count
        }
    }
}
#endif
