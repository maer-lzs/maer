// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Network
import os
import SQLite3
@testable import Maer

/// A bulk import over many feeds: dead feeds do not hold it for minutes,
/// every feed that did not answer is named and can be asked again, and
/// each feed's answer is its own even with several in flight.
@MainActor
struct BulkImportTests {
    @MainActor final class Tally {
        var inFlight = 0
        var most = 0
        var calls = 0
    }

    static func show(_ url: URL, title: String, episodes: Int = 2) -> PodcastShow {
        PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString), title: title,
                    author: nil, artworkURL: nil, description: nil,
                    feedURL: url.absoluteString,
                    episodes: (0..<episodes).map {
                        PodcastEpisode(guid: "rss:bulk:\(url.host ?? "-")-\($0)", title: "\(title) \($0)",
                                       audioURL: "https://\(url.host ?? "x")/\($0).mp3",
                                       pubDate: Double($0 + 1), duration: 60)
                    })
    }

    /// A store of its own, on its own files and suite.
    static func store() async throws -> (PodcastSubscriptions, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "bulk-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let subs = PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
        await subs.ensureLoaded()
        return (subs, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    @Test("TF-9: tote Feeds halten den Import nicht auf, hoechstens vier zugleich, jeder benannt und zum Nachholen markiert")
    func deadFeedsDoNotHoldTheImport() async throws {
        let (subs, cleanup) = try await Self.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let dead = (0..<8).map { "https://dead\($0).example/\(run)/feed.xml" }
        let live = "https://live.example/\(run)/feed.xml"
        defer { for feed in dead { FeedAdoptionPending.clear(feedKey: PodcastSubscriptions.feedKey(feed)) } }
        let tally = Tally()
        let silence: UInt64 = 300_000_000
        subs._testFeedFetcher = { url in
            await MainActor.run { tally.inFlight += 1; tally.most = max(tally.most, tally.inFlight); tally.calls += 1 }
            try? await Task.sleep(nanoseconds: silence)
            await MainActor.run { tally.inFlight -= 1 }
            if url.host == "live.example" { return .show(Self.show(url, title: "Live Show")) }
            return .failed(.timeout)
        }
        var library = ForeignLibrary(feedURLs: dead + [live], states: [])
        for (index, feed) in dead.enumerated() { library.feedTitles[feed] = "Dead Show \(index)" }

        let clock = ContinuousClock()
        let started = clock.now
        let result = await subs.importForeignLibrary(library)
        let elapsed = clock.now - started

        // Nine feeds of 0.3 s each: one after the other 2.7 s, four at a
        // time three rounds, about 0.9 s.
        #expect(tally.calls == 9, "each feed asked exactly once")
        #expect(tally.most == FeedFetchPatience.bulkWidth, "four in flight, never more: \(tally.most)")
        #expect(elapsed < .milliseconds(1_800), "the run did not wait feed after feed: \(elapsed)")
        #expect(result.subscribed == 1 && result.subscribedTitles == ["Live Show"])
        #expect(result.failed == 8)
        #expect(result.unreached.map(\.title) == (0..<8).map { "Dead Show \($0)" }, "named by the source, in its order")
        #expect(result.unreached.allSatisfy { $0.reason == .timeout })
        for feed in dead {
            #expect(subs.feedsNotFollowed[PodcastSubscriptions.feedKey(feed)]?.reason == .timeout,
                    "waits in Not followed yet with its reason")
        }
    }

    @Test("TF-9 Z1: vier gleichzeitig, und der Zwillings-Ausstieg zaehlt bei genau seiner Sendung")
    func eachFeedAnswersForItself() async throws {
        let (subs, cleanup) = try await Self.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        // A premium show of the same name is already held (token address).
        let premium = "https://premium.example/\(run)/feed.xml?token=abc"
        subs._testFeedFetcher = { url in .show(Self.show(url, title: "Twin Show")) }
        try #require(await subs.subscribe(urlString: premium, notesCloud: false))
        let twin = "https://free.example/\(run)/feed.xml"
        let other = "https://other.example/\(run)/feed.xml"
        // The twin answers last, while the other one is already done.
        subs._testFeedFetcher = { url in
            if url.host == "free.example" {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return .show(Self.show(url, title: "Twin Show"))
            }
            return .show(Self.show(url, title: "Other Show"))
        }
        let result = await subs.importForeignLibrary(ForeignLibrary(feedURLs: [twin, other], states: []))
        #expect(result.freeTwinsSkipped == 1, "the twin is counted as a twin")
        #expect(result.subscribed == 1 && result.subscribedTitles == ["Other Show"], "and the other as new: \(result.subscribedTitles)")
        #expect(!subs.shows.contains { $0.feedURL.contains("free.example") }, "the twin is not subscribed")
    }

    // MARK: - One attempt, a short silence, against a real socket

    /// A plain-HTTP stand on the loopback: silent, 503, or a body that
    /// trickles in a byte at a time. Unchecked, because `port` is written
    /// once in `start` before anyone reads it; everything else is a `let`
    /// or behind the lock.
    nonisolated final class Stand: @unchecked Sendable {
        enum Mode: Sendable { case silent, unavailable, trickle(bytes: Int, gapMs: Int) }
        private let listener: NWListener
        private let mode: Mode
        private let requests = OSAllocatedUnfairLock(initialState: 0)
        private(set) var port: UInt16 = 0
        var requestCount: Int { requests.withLock { $0 } }

        private init(mode: Mode) throws {
            self.mode = mode
            listener = try NWListener(using: .tcp, on: .any)
        }

        static func start(_ mode: Mode) async throws -> Stand {
            let stand = try Stand(mode: mode)
            stand.listener.newConnectionHandler = { [stand] connection in stand.serve(connection) }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                stand.listener.stateUpdateHandler = { [stand] state in
                    let first = once.withLock { done in
                        let was = done
                        if case .ready = state { done = true } else if case .failed = state { done = true }
                        return !was && done
                    }
                    if first, case .ready = state { continuation.resume(returning: stand.listener.port?.rawValue ?? 0) }
                    if first, case .failed(let error) = state { continuation.resume(throwing: error) }
                }
                stand.listener.start(queue: .global())
            }
            stand.port = port
            return stand
        }

        func stop() { listener.cancel() }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] _, _, _, _ in
                requests.withLock { $0 += 1 }
                switch mode {
                case .silent:
                    break
                case .unavailable:
                    let head = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
                case .trickle(let bytes, let gapMs):
                    let head = "HTTP/1.1 200 OK\r\nContent-Length: \(bytes)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                    for index in 0..<bytes {
                        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(gapMs * (index + 1))) {
                            connection.send(content: Data("x".utf8), completion: .contentProcessed { _ in
                                if index == bytes - 1 { connection.cancel() }
                            })
                        }
                    }
                }
            }
        }
    }

    static func request(_ stand: Stand, silence: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(stand.port)/feed.xml")))
        request.timeoutInterval = silence
        return request
    }

    @Test("TF-9: ein Versuch statt der Leiter, gegen einen schweigenden und einen ueberlasteten Wirt")
    func onceAsksOnce() async throws {
        let session = URLSession(configuration: .ephemeral)
        let clock = ContinuousClock()

        let silent = try await Stand.start(.silent)
        defer { silent.stop() }
        var started = clock.now
        await #expect(throws: URLError.self) {
            _ = try await RequestRetryPolicy.fetch(try Self.request(silent, silence: 1), session: session, once: true)
        }
        let once = clock.now - started
        #expect(silent.requestCount == 1, "one attempt: \(silent.requestCount)")
        #expect(once < .milliseconds(2_500), "one silence of a second: \(once)")

        let silentLadder = try await Stand.start(.silent)
        defer { silentLadder.stop() }
        started = clock.now
        await #expect(throws: URLError.self) {
            _ = try await RequestRetryPolicy.fetch(try Self.request(silentLadder, silence: 1), session: session)
        }
        let ladder = clock.now - started
        #expect(silentLadder.requestCount == 3, "the patient ladder asks three times: \(silentLadder.requestCount)")
        print("BULK silence=1s once=\(once) ladder=\(ladder)")

        let busy = try await Stand.start(.unavailable)
        defer { busy.stop() }
        let (_, answer) = try await RequestRetryPolicy.fetch(try Self.request(busy, silence: 1), session: session, once: true)
        #expect(answer?.statusCode == 503 && busy.requestCount == 1, "a 503 is answered once, not retried")
    }

    @Test("TF-9: ein grosser lebender Feed, der langsam aber stetig liefert, kommt durch die kurze Stille")
    func aSlowSteadyFeedArrives() async throws {
        let stand = try await Stand.start(.trickle(bytes: 6, gapMs: 400))
        defer { stand.stop() }
        let session = URLSession(configuration: .ephemeral)
        // Six bytes over 2.4 s, never more than 0.4 s apart, against a
        // silence limit of one second.
        let (data, answer) = try await RequestRetryPolicy.fetch(try Self.request(stand, silence: 1),
                                                                session: session, once: true)
        #expect(answer?.statusCode == 200)
        #expect(data.count == 6, "the whole body arrived: \(data.count)")
    }

    @Test("TF-9: jeder Leser nennt die Sendung, wie die Quelle sie nennt")
    func everyReaderNamesItsFeeds() throws {
        let opml = """
        <?xml version="1.0"?><opml version="2.0"><body>\
        <outline type="rss" text="Plain Show" xmlUrl="https://plain.example/feed"/>\
        <outline type="rss" title="Titled Show" xmlUrl="https://titled.example/feed"/>\
        </body></opml>
        """
        let fromOPML = try #require(OvercastOPML.parse(Data(opml.utf8)))
        #expect(fromOPML.feedTitles == ["https://plain.example/feed": "Plain Show",
                                        "https://titled.example/feed": "Titled Show"])

        let antenna = AntennaPodDatabase.library(
            feeds: [.init(id: 1, title: "Antenna Show", downloadURL: "https://antenna.example/rss", state: 0)],
            items: [], media: [])
        #expect(antenna.feedTitles == ["https://antenna.example/rss": "Antenna Show"])

        let pocket = PocketCastsAPI.library(podcasts: [.init(uuid: "p1", title: "Pocket Show")],
                                            feedURLs: ["p1": "https://pocket.example/rss"],
                                            states: [:], episodes: [:])
        #expect(pocket.feedTitles == ["https://pocket.example/rss": "Pocket Show"])

        // Apple: a database of the shape the Mac writes, reduced to the
        // columns the reader asks for.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("apple-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        try #require(sqlite3_open(file.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE ZMTPODCAST (ZFEEDURL TEXT, ZSUBSCRIBED INTEGER, ZTITLE TEXT);
        CREATE TABLE ZMTEPISODE (ZENCLOSUREURL TEXT);
        INSERT INTO ZMTPODCAST VALUES ('https://apple.example/feed', 1, 'Apple Show');
        INSERT INTO ZMTPODCAST VALUES ('https://gone.example/feed', 0, 'Not Followed');
        """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let apple = try #require(PodcastImport.readAppleLibrary(at: file))
        #expect(apple.feedURLs == ["https://apple.example/feed"])
        #expect(apple.feedTitles == ["https://apple.example/feed": "Apple Show"], "only the followed show, by its name")
    }

    @Test("TF-9: der Massen-Import fragt einmal und kurz, eine Stelle", .needsTheSources)
    func theBulkPatience() throws {
        #expect(FeedFetchPatience.bulk.asksOnce && FeedFetchPatience.bulk.silenceLimit == FeedFetchPatience.bulkSilence)
        #expect(!FeedFetchPatience.patient.asksOnce && FeedFetchPatience.patient.silenceLimit == nil)
        #expect(FeedFetchPatience.bulkSilence == 8 && FeedFetchPatience.bulkWidth == 4)
        // The test fetcher stands in for the real fetch above, so the wiring
        // is read at the source: the import asks with `.bulk`, and the one
        // fetch applies both halves of it.
        let store = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"), encoding: .utf8))
        #expect(store.components(separatedBy: "isSingleUserAct: false, patience: .bulk)").count - 1 == 2,
                "both launches of the bulk run ask with .bulk")
        #expect(store.contains("if let silence = patience.silenceLimit { request.timeoutInterval = silence }"))
        #expect(store.contains("RequestRetryPolicy.fetch(request, once: patience.asksOnce)"))
        #expect(!store.contains("lastFreeTwinSkip"), "no shared slot for what one fetch says about itself")
    }
}
#endif
