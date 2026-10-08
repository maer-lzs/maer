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

    /// Who may still call `subscribe(urlString:` past the door, and why.
    static let stock: [String: (count: Int, reason: String)] = [
        "PodcastSubscriptions.swift": (4, "the door itself, and the account's adoption, the retry and the new link, which go through it in the next step"),
        "GPodderSync.swift": (2, "the gpodder round and the resolved conflict, through the door in the next step"),
        "PinchflatClient.swift": (1, "the Pinchflat mirror, through the door in the next step"),
        "CatalogDetailExtras.swift": (1, "waits for the owner's word: the person chose a local-only feed in so many words"),
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
