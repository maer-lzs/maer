// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A foreign import meets a show subscribed on Audiobookshelf: the two
/// sources hold a show exclusively, so nothing is subscribed locally and
/// the summary says where the show is.
@MainActor
struct ServerHeldImportTests {
    @MainActor final class Calls {
        var hosts: [String] = []
    }

    static func serverShow(feedURL: String, title: String) -> PodcastShow {
        PodcastShow(id: "abspod:server-\(UUID().uuidString.prefix(6))", title: title,
                    author: nil, artworkURL: nil, description: nil, feedURL: feedURL,
                    episodes: [PodcastEpisode(guid: "abspod:s:e1", title: "\(title) 1",
                                              audioURL: "/api/items/s/file", pubDate: 1, duration: 60)])
    }

    @Test("eine Sendung auf Audiobookshelf wird nicht lokal abonniert und nicht abgerufen, Vorschau und Ergebnis zaehlen sie, ihr Stand ohne Folge steht sichtbar als nicht zugeordnet")
    func aServerShowIsNotSubscribedHere() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let onServer = "https://server-held.example/\(run)/feed.xml"
        let other = "https://other-held.example/\(run)/feed.xml"
        subs.serverShows = { [Self.serverShow(feedURL: onServer, title: "Server Show")] }
        let calls = Calls()
        subs._testFeedFetcher = { url in
            await MainActor.run { calls.hosts.append(url.host ?? "-") }
            return .show(BulkImportTests.show(url, title: "Other Show"))
        }
        let state = ForeignListeningState(feedURL: onServer, showTitle: "Server Show (source)",
                                          episodeGUID: "not-on-the-server-\(run)", enclosureURL: nil,
                                          episodeLink: nil, episodeTitle: nil,
                                          position: 30, finished: false, stampedAt: 1_000)
        let library = ForeignLibrary(feedURLs: [onServer, other], states: [state])

        let preview = ForeignImportPreview.make(
            library, subscribedFeedKeys: Set(subs.shows.map { PodcastIdentity.feedKey($0.feedURL) }),
            serverFeedKeys: Set(subs.serverOnlyShows().keys), feedKeyOf: PodcastIdentity.feedKey)
        #expect(preview.onServer == 1 && preview.alreadySubscribed == 0)

        let result = await subs.importForeignLibrary(library)
        #expect(!calls.hosts.contains("server-held.example"), "the server's show was fetched to subscribe it here")
        #expect(!subs.shows.contains { $0.feedURL == onServer }, "the server's show was subscribed here")
        #expect(result.onServer == 1 && result.onServerTitles == ["Server Show"])
        #expect(result.subscribed == 1 && result.subscribedTitles == ["Other Show"], "the other show is imported as before")
        #expect(result.unmatchedGroups.map(\.show) == ["Server Show (source)"], "the state is named, not dropped")
    }

    /// A server that answers from memory: its progress, the writes it took,
    /// a read that can fail, writes that can fail.
    @MainActor final class FakeServer: ForeignServerSide {
        var episodeHandles: [String: ServerEpisodeHandle] = [:]
        var progress: [String: BookProgress] = [:]
        var readFails = false
        var failing: Set<String> = []
        var writes: [(id: String, time: Double, finished: Bool)] = []
        private var clock = 9_000_000.0
        func freshEpisodeProgress() async -> [String: BookProgress]? { readFails ? nil : progress }
        func writeEpisodeProgress(_ itemId: String, time: Double, duration: Double, finished: Bool) async throws {
            if failing.contains(itemId) { throw URLError(.notConnectedToInternet) }
            writes.append((itemId, time, finished))
            clock += 1_000
            progress[itemId] = BookProgress(fraction: duration > 0 ? min(time / duration, 1) : 0,
                                            isFinished: finished, lastUpdate: clock, currentTime: time)
        }
    }

    /// One show on the server: e1 (guid g1, enclosure), e2 (guid g2), e3
    /// (enclosure only), e4 and e5 sharing the guid "dup", e6 without a
    /// duration (guid g6).
    struct Rig {
        let subs: PodcastSubscriptions
        let server: FakeServer
        let feed: String
        let cleanup: () -> Void
        func id(_ episode: String) -> String { "abspod:sv:\(episode)" }
    }

    func rig() async throws -> Rig {
        let (subs, cleanup) = try await BulkImportTests.store()
        let feed = "https://server-states.example/\(UUID().uuidString.prefix(8))/feed.xml"
        let server = FakeServer()
        let handles: [(String, String?, String?, Double)] = [
            ("e1", "g1", "https://cdn.example/x1.mp3", 600), ("e2", "g2", nil, 600),
            ("e3", nil, "https://cdn.example/x3.mp3", 600), ("e4", "dup", nil, 600),
            ("e5", "dup", nil, 600), ("e6", "g6", nil, 0),
        ]
        var episodes: [PodcastEpisode] = []
        for (name, guid, enclosure, duration) in handles {
            server.episodeHandles["abspod:sv:\(name)"] = ServerEpisodeHandle(guid: guid, enclosure: enclosure)
            episodes.append(PodcastEpisode(guid: "abspod:sv:\(name)", title: "Server \(name)",
                                           audioURL: "/api/items/sv/\(name)", pubDate: 1, duration: duration))
        }
        let show = PodcastShow(id: "abspod:sv", title: "Server Show", author: nil, artworkURL: nil,
                               description: nil, feedURL: feed, episodes: episodes)
        subs.serverShows = { [show] }
        subs.serverSide = { server }
        return Rig(subs: subs, server: server, feed: feed, cleanup: cleanup)
    }

    func state(_ feed: String, guid: String? = nil, enclosure: String? = nil, position: Double = 0,
               finished: Bool = false, at moment: Double? = 2_000) -> ForeignListeningState {
        ForeignListeningState(feedURL: feed, showTitle: "Server Show (source)", episodeGUID: guid,
                              enclosureURL: enclosure, episodeLink: nil, episodeTitle: nil,
                              position: position, finished: finished, stampedAt: moment)
    }

    @Test("Staende einer Sendung auf Audiobookshelf gehen in ihren Fortschritt: ueber guid und Enclosure, nur eindeutig, nur wo der Import nach der Regel gewinnt")
    func statesGoToTheServer() async throws {
        let rig = try await rig()
        defer { rig.cleanup() }
        // The server knows e2 later than the source: it keeps it.
        rig.server.progress[rig.id("e2")] = BookProgress(fraction: 0.05, isFinished: false,
                                                         lastUpdate: 8_000_000, currentTime: 30)
        let states = [
            state(rig.feed, guid: "g1", position: 120),
            state(rig.feed, guid: "g2", finished: true),
            state(rig.feed, enclosure: "http://cdn.example/x3.mp3?token=1", position: 200),
            state(rig.feed, guid: "dup", position: 50),
            state(rig.feed, guid: "not-there", position: 70),
            state(rig.feed, guid: "g6", finished: true),
        ]
        let result = await rig.subs.importForeignLibrary(ForeignLibrary(feedURLs: [rig.feed], states: states))
        let written = Dictionary(uniqueKeysWithValues: rig.server.writes.map { ($0.id, $0) })
        #expect(Set(written.keys) == [rig.id("e1"), rig.id("e3"), rig.id("e6")], "\(written.keys.sorted())")
        #expect(written[rig.id("e1")]?.time == 120 && written[rig.id("e1")]?.finished == false)
        #expect(written[rig.id("e3")]?.time == 200, "the enclosure rung")
        #expect(written[rig.id("e4")] == nil && written[rig.id("e5")] == nil, "a guid two episodes carry placed a state")
        #expect(written[rig.id("e6")]?.time == ProgressMark.playedSentinel && written[rig.id("e6")]?.finished == true,
                "finished without a duration goes as the sentinel, finished")
        #expect(result.sentToServer == 3 && result.sentFinished == 1 && result.keptOnServer == 1)
        #expect(result.unmatchedGroups.map(\.count) == [2], "the shared guid and the unknown one are named")
        #expect(result.notSent.isEmpty)
        #expect(!rig.subs.shows.contains { $0.feedURL == rig.feed }, "nothing subscribed here")
    }

    @Test("was der Server nicht nahm, steht als nicht gesendet und geht im zweiten Lauf, ohne das schon Gesendete noch einmal")
    func aRefusedWriteIsSentAgain() async throws {
        let rig = try await rig()
        defer { rig.cleanup() }
        let library = ForeignLibrary(feedURLs: [rig.feed], states: [
            state(rig.feed, guid: "g1", position: 120),
            state(rig.feed, enclosure: "https://cdn.example/x3.mp3", position: 200),
        ])
        rig.server.failing = [rig.id("e3")]
        let first = await rig.subs.importForeignLibrary(library)
        #expect(first.sentToServer == 1)
        #expect(first.notSent == [.init(show: "Server Show (source)", count: 1)])
        rig.server.failing = []
        let second = await rig.subs.importForeignLibrary(library)
        #expect(second.sentToServer == 1 && second.notSent.isEmpty)
        #expect(rig.server.writes.map(\.id) == [rig.id("e1"), rig.id("e3")], "e1 was written twice")
    }

    @Test("ohne gelesenen Serverstand wird nichts geschrieben, die Staende stehen als nicht gesendet")
    func noReadNoWrite() async throws {
        let rig = try await rig()
        defer { rig.cleanup() }
        rig.server.readFails = true
        let result = await rig.subs.importForeignLibrary(ForeignLibrary(feedURLs: [rig.feed], states: [
            state(rig.feed, guid: "g1", position: 120), state(rig.feed, guid: "g2", position: 90),
        ]))
        #expect(rig.server.writes.isEmpty)
        #expect(result.sentToServer == 0 && result.notSent.map(\.count) == [2])
    }

    @Test("eine Sendung, die hier UND auf Audiobookshelf liegt, zaehlt als schon abonniert")
    func aShowHeldHereCountsAsHeld() async throws {
        let (subs, cleanup) = try await BulkImportTests.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let both = "https://both-held.example/\(run)/feed.xml"
        subs._testFeedFetcher = { url in .show(BulkImportTests.show(url, title: "Both Show")) }
        try #require(await subs.subscribe(urlString: both, notesCloud: false))
        subs.serverShows = { [Self.serverShow(feedURL: both, title: "Both Show")] }
        #expect(subs.serverOnlyShows().isEmpty)
        let result = await subs.importForeignLibrary(ForeignLibrary(feedURLs: [both], states: []))
        #expect(result.alreadySubscribed == 1 && result.onServer == 0)
    }
}
#endif
