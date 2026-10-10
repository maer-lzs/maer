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

    @Test("die Antwort: dort gehalten, nicht dort, oder ungelesen; eine bekannte Sendung ist gehalten, gelesen oder nicht")
    func theThreeAnswers() {
        let titles = ["k": "Show"]
        #expect(ServerHolding.of(feedKey: "k", read: true, serverTitles: titles) == .held(title: "Show"))
        #expect(ServerHolding.of(feedKey: "k", read: false, serverTitles: titles) == .held(title: "Show"))
        #expect(ServerHolding.of(feedKey: "x", read: true, serverTitles: titles) == .notThere)
        #expect(ServerHolding.of(feedKey: "x", read: false, serverTitles: titles) == .unread)
    }

    @Test("die Tuer: eine Sendung auf Audiobookshelf wird hier nicht abonniert und nicht abgerufen, eine andere wie bisher")
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

    @Test("die Tuer bei ungelesenem Audiobookshelf: erst lesen; bleibt es ungelesen, wird nichts abonniert, gelesen gilt die Antwort")
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
        let setOut = await subs.subscribeUnlessOnServer(urlString: feed)
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

    @Test("der Import bei ungelesenem Audiobookshelf: erst lesen, dann aussetzen, nichts abonniert, das Ergebnis sagt es")
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

    @Test("gpodder: eine Sendung auf Audiobookshelf wird ueber drei Runden nicht lokal abonniert, und gpodder bekommt von diesem Geraet keine Entfernung")
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

    @Test("die Familie: eine Sendung auf Audiobookshelf wird nicht abonniert, nicht abgerufen und nicht als nicht gefolgt markiert; eine andere wie bisher")
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
        #expect(subs.feedsNotFollowed[PodcastSubscriptions.feedKey(onServer)] == nil, "the server's show was marked as not followed")
    }

    @Test("Abzeichen und Quellenseite lesen Audiobookshelf vor der Wahl zwischen Server und hier, und das Abzeichen sagt ein Aussetzen", .needsTheSources)
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
        #expect(badge.contains("== .setOut { subs.serverUnreadNotice = true }"), "the badge sets out in silence")
        let host = try code("Sources/Views/Podcasts/PodcastSubscribeNoticeHost.swift")
        #expect(host.contains("subs.serverUnreadNotice"), "no host says the set out")
    }

    /// The catalog page's "local only" feed goes through the door too: a show
    /// Audiobookshelf holds is refused with that sentence, an unread server
    /// says so, nothing is subscribed a second time.
    @Test("Abo als Feed von der Katalogseite: geht durch die Tuer, liegt die Sendung auf Audiobookshelf, weist es ab", .needsTheSources)
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
        #expect(page.contains("HintLine(systemImage: \"exclamationmark.triangle.fill\") { Text(localRefusal) }"),
                "the refusal is not shown beside the menu")
    }

    /// Who may still call `subscribe(urlString:` past the door, and why.
    static let stock: [String: (count: Int, reason: String)] = [
        "PodcastSubscriptions.swift": (1, "the door itself"),
    ]

    @Test("nur die benannten Stellen abonnieren an der Tuer vorbei", .needsTheSources)
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
