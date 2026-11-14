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
        PodcastShow(id: PodcastIdentity.feedKey(url.absoluteString), title: title,
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
        let (subs, _, cleanup) = try await storeAndDefaults()
        return (subs, cleanup)
    }

    /// The same store with its suite: the states and marks it writes land
    /// there, not in the app's domain, so a witness reads them there.
    static func storeAndDefaults() async throws -> (PodcastSubscriptions, UserDefaults, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "bulk-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let subs = PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
        await subs.ensureLoaded()
        // The server's shows count as read, whatever the host's switch says;
        // a witness of the unread server sets its own.
        subs.serverShowsRead = { true }
        return (subs, defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    @Test("dead feeds do not hold up the import, at most four at once, each named and marked for catching up")
    func deadFeedsDoNotHoldTheImport() async throws {
        let (subs, cleanup) = try await Self.store()
        defer { cleanup() }
        let run = UUID().uuidString.prefix(8)
        let dead = (0..<8).map { "https://dead\($0).example/\(run)/feed.xml" }
        let live = "https://live.example/\(run)/feed.xml"
        defer { for feed in dead { FeedAdoptionPending.clear(feedKey: PodcastIdentity.feedKey(feed)) } }
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
            #expect(subs.feedsNotFollowed[PodcastIdentity.feedKey(feed)]?.reason == .timeout,
                    "waits in Not followed yet with its reason")
        }
    }

    @Test("four at the same time, and the twin exit counts at exactly its show")
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

    // MARK: - States per show (slice 2)

    @MainActor final class Gate { var open = false; var progress: [PodcastSubscriptions.ImportProgress] = [] }

    /// Two shows with an episode of the same title. A's state reaches its
    /// episode by the enclosure; B's state carries only the title and a
    /// newer moment. B's feed does not answer.
    static func sameTitle(_ run: Substring) -> (a: String, b: String, aEpisode: String, library: ForeignLibrary) {
        let a = "https://a.example/\(run)/feed.xml"
        let b = "https://b.example/\(run)/feed.xml"
        let stateA = ForeignListeningState(feedURL: a, episodeGUID: nil, enclosureURL: "https://a.example/0.mp3",
                                           episodeLink: nil, episodeTitle: "Same Title", position: 120,
                                           duration: 3600, finished: false, stampedAt: 1_000)
        let stateB = ForeignListeningState(feedURL: b, episodeGUID: nil, enclosureURL: nil,
                                           episodeLink: nil, episodeTitle: "Same Title", position: 300,
                                           duration: 3600, finished: false, stampedAt: 2_000)
        return (a, b, "rss:bulk:\(run)-a", ForeignLibrary(feedURLs: [a, b], states: [stateA, stateB]))
    }

    static func sameTitleShow(_ url: URL, _ run: Substring) -> PodcastShow {
        PodcastShow(id: PodcastIdentity.feedKey(url.absoluteString), title: url.host ?? "-",
                    author: nil, artworkURL: nil, description: nil, feedURL: url.absoluteString,
                    episodes: [PodcastEpisode(guid: "rss:bulk:\(run)-\(url.host == "a.example" ? "a" : "b")", title: "Same Title",
                                              audioURL: "https://\(url.host ?? "x")/0.mp3",
                                              pubDate: 1, duration: 3600)])
    }

    @Test("a state that matches only by title never lands at the wrong show, even if its own is missing")
    func aTitleOnlyStateNeverLandsElsewhere() async throws {
        let (subs, defaults, cleanup) = try await Self.storeAndDefaults()
        let run = UUID().uuidString.prefix(8)
        let fixture = Self.sameTitle(run)
        defer {
            cleanup()
            ListeningStore.clearBackup(fixture.aEpisode, in: defaults)
            ForeignMarks.clear(fixture.aEpisode, in: defaults)
            FeedAdoptionPending.clear(feedKey: PodcastIdentity.feedKey(fixture.b))
        }
        subs._testFeedFetcher = { url in
            url.host == "a.example" ? .show(Self.sameTitleShow(url, run)) : .failed(.timeout)
        }
        let result = await subs.importForeignLibrary(fixture.library)
        let entry = try #require(ListeningStore.backup(fixture.aEpisode, in: defaults), "A's own state was applied")
        #expect(entry.first == 120, "A holds its own state, not B's newer one: \(entry)")
        #expect(result.progressApplied == 1 && result.unmatched == ["Same Title"], "B's state waits unmatched")
    }

    @Test("the state of a show is in place as soon as it is followed, before the next feed answers; a second run does not fetch it again")
    func aShowsStatesLandWhenItIsFollowed() async throws {
        let (subs, defaults, cleanup) = try await Self.storeAndDefaults()
        let run = UUID().uuidString.prefix(8)
        let fixture = Self.sameTitle(run)
        defer {
            cleanup()
            ListeningStore.clearBackup(fixture.aEpisode, in: defaults)
            ForeignMarks.clear(fixture.aEpisode, in: defaults)
            FeedAdoptionPending.clear(feedKey: PodcastIdentity.feedKey(fixture.b))
        }
        let gate = Gate()
        let tally = Tally()
        subs._testFeedFetcher = { url in
            await MainActor.run { tally.calls += 1 }
            if url.host == "a.example" { return .show(Self.sameTitleShow(url, run)) }
            // B stays silent until the witness has looked.
            while await MainActor.run(body: { !gate.open }) { try? await Task.sleep(nanoseconds: 20_000_000) }
            return .failed(.timeout)
        }
        let importing = Task { await subs.importForeignLibrary(fixture.library) { gate.progress.append($0) } }
        var landedWhileWaiting = false
        for _ in 0..<150 where !landedWhileWaiting {
            landedWhileWaiting = ListeningStore.backup(fixture.aEpisode, in: defaults)?.first == 120
            if !landedWhileWaiting { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        gate.open = true
        _ = await importing.value
        #expect(landedWhileWaiting, "A's state stood while B was still unanswered: an abort there keeps it")
        let seen = gate.progress
        #expect(seen.first == .init(done: 0, total: 2), "the run says where it starts: \(seen)")
        #expect(seen.contains(.init(done: 1, total: 2)) && seen.contains(.init(done: 2, total: 2)))
        #expect(seen.last?.matching == true, "and ends matching the rest")

        tally.calls = 0
        gate.open = true
        _ = await subs.importForeignLibrary(fixture.library)
        #expect(tally.calls == 1, "a second run asks only the feed it does not hold: \(tally.calls)")
    }

    @Test("the ladder takes only the allowed rungs and counts titles across the whole source")
    func theLadderTakesOnlyTheRungsItIsGiven() {
        let target = ForeignMatchTarget(id: "e1", rawGUID: "g1", enclosureURL: "https://x.example/1.mp3",
                                        link: nil, title: "Only Title", feedKey: "k")
        let byTitle = ForeignListeningState(feedURL: nil, episodeGUID: nil, enclosureURL: nil, episodeLink: nil,
                                            episodeTitle: "Only Title", position: 10, duration: nil,
                                            finished: false, stampedAt: nil)
        let byGUID = ForeignListeningState(feedURL: nil, episodeGUID: "g1", enclosureURL: nil, episodeLink: nil,
                                           episodeTitle: nil, position: 20, duration: nil,
                                           finished: false, stampedAt: nil)
        let exact: Set<ForeignStateMatcher.Step> = [.guid, .enclosure, .link]
        let key: (String) -> String = { $0 }
        #expect(ForeignStateMatcher.plan(states: [byTitle], targets: [target], feedKeyOf: key).matches.count == 1,
                "all rungs: the title decides")
        #expect(ForeignStateMatcher.plan(states: [byTitle], targets: [target], steps: exact, feedKeyOf: key).matches.isEmpty,
                "the exact rungs leave a title-only state for the end")
        #expect(ForeignStateMatcher.plan(states: [byGUID], targets: [target], steps: exact, feedKeyOf: key).matches.first?.step == .guid)
        // The same title twice in the whole source: a remainder with one of
        // them must not look unique.
        let twice = [byTitle, byTitle]
        #expect(ForeignStateMatcher.plan(states: [byTitle], targets: [target], titleStates: twice, feedKeyOf: key).matches.isEmpty)
    }

    // MARK: - Background (slice 3)

    /// Background time that ends when the witness says so.
    @MainActor final class FakeWork: BackgroundWork {
        var begun = 0
        var ended = 0
        var expire: (@MainActor () -> Void)?
        func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> BackgroundWorkToken {
            begun += 1
            expire = expired
            return BackgroundWorkToken(raw: begun)
        }
        func end(_ token: BackgroundWorkToken) { ended += 1 }
    }

    @Test("if the background time ends, the import stops at the next show boundary, says where, keeps what was done and a second run continues")
    func anExpiredImportStopsAndContinues() async throws {
        let (subs, defaults, cleanup) = try await Self.storeAndDefaults()
        let run = UUID().uuidString.prefix(8)
        let feeds = (0..<8).map { "https://stop\($0)-\(run).example/feed.xml" }
        let episodes = (0..<8).map { "rss:bulk:stop\($0)-\(run).example-0" }
        defer {
            cleanup()
            for id in episodes { ListeningStore.clearBackup(id, in: defaults); ForeignMarks.clear(id, in: defaults) }
        }
        let states = (0..<8).map {
            ForeignListeningState(feedURL: feeds[$0], episodeGUID: nil,
                                  enclosureURL: "https://stop\($0)-\(run).example/0.mp3", episodeLink: nil,
                                  episodeTitle: nil, position: 60, duration: 600, finished: false, stampedAt: 1_000)
        }
        let library = ForeignLibrary(feedURLs: feeds, states: states)
        let work = FakeWork()
        subs.backgroundWork = work
        let tally = Tally()
        subs._testFeedFetcher = { url in
            let call = await MainActor.run { () -> Int in tally.calls += 1; return tally.calls }
            // The system ends the time while the second show is asked.
            if call == 2 { await MainActor.run { work.expire?() } }
            try? await Task.sleep(nanoseconds: 150_000_000)
            return .show(Self.show(url, title: url.host ?? "-", episodes: 1))
        }
        let first = await subs.importForeignLibrary(library)
        let asked = tally.calls
        #expect(asked == FeedFetchPatience.bulkWidth, "the shows in flight finish, no new one starts: \(asked)")
        #expect(first.stoppedAt == asked && first.notAsked == 8 - asked, "it says where it stopped")
        #expect(first.unreached.isEmpty && first.failed == 0, "a show never asked is not a show that failed")
        #expect(first.progressApplied == asked, "what each followed show brought is kept")
        #expect(work.begun == 1 && work.ended == 1, "the time is asked for once and given back")

        tally.calls = 0
        subs.backgroundWork = FakeWork()
        let second = await subs.importForeignLibrary(library)
        #expect(tally.calls == 8 - asked, "the second run asks only the shows it does not hold: \(tally.calls)")
        #expect(second.stoppedAt == nil && second.notAsked == 0)
        #expect(episodes.allSatisfy { ListeningStore.backup($0, in: defaults)?.first == 60 }, "every show's state stands")
    }

    // MARK: - One attempt, a short silence, against a real socket

    /// A plain-HTTP stand on the loopback: silent, 503, or a body that
    /// trickles in a byte at a time. Unchecked, because `port` is written
    /// once in `start` before anyone reads it; everything else is a `let`
    /// or behind the lock.
    ///
    /// An attempt is counted when its CONNECTION is accepted, not when its
    /// bytes are read: the read completes on another queue and, under load,
    /// after the client already gave up, so a count read at once raced it.
    /// Unchecked because the count sits behind a lock and the listener and
    /// its mode are set once.
    nonisolated final class Stand: @unchecked Sendable {
        enum Mode: Sendable {
            case silent, unavailable, trickle(bytes: Int, gapMs: Int)
            /// One whole answer: the status and the body, at once.
            case answer(status: Int, body: Data)
        }
        private let listener: NWListener
        private let mode: Mode
        private let attempts = OSAllocatedUnfairLock(initialState: 0)
        private(set) var port: UInt16 = 0
        var requestCount: Int { attempts.withLock { $0 } }

        /// The count once it has reached `expected` (or three seconds have
        /// passed), after a short grace in which a surplus attempt would still
        /// show. So "exactly one" stays a claim about one, not about timing.
        func settledCount(expected: Int) async -> Int {
            let deadline = ContinuousClock.now + .seconds(3)
            while requestCount < expected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .milliseconds(300))
            return requestCount
        }

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
            attempts.withLock { $0 += 1 }
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] _, _, _, _ in
                switch mode {
                case .silent:
                    break
                case .unavailable:
                    let head = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
                case .answer(let status, let body):
                    let head = "HTTP/1.1 \(status) Answer\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
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

    @Test("one attempt instead of the ladder, against a silent and an overloaded host")
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
        let onceCount = await silent.settledCount(expected: 1)
        #expect(onceCount == 1, "one attempt: \(onceCount)")
        #expect(once < .milliseconds(2_500), "one silence of a second: \(once)")

        let silentLadder = try await Stand.start(.silent)
        defer { silentLadder.stop() }
        started = clock.now
        await #expect(throws: URLError.self) {
            _ = try await RequestRetryPolicy.fetch(try Self.request(silentLadder, silence: 1), session: session)
        }
        let ladder = clock.now - started
        let ladderCount = await silentLadder.settledCount(expected: 3)
        #expect(ladderCount == 3, "the patient ladder asks three times: \(ladderCount)")
        print("BULK silence=1s once=\(once) ladder=\(ladder)")

        let busy = try await Stand.start(.unavailable)
        defer { busy.stop() }
        let (_, answer) = try await RequestRetryPolicy.fetch(try Self.request(busy, silence: 1), session: session, once: true)
        let busyCount = await busy.settledCount(expected: 1)
        #expect(answer?.statusCode == 503 && busyCount == 1, "a 503 is answered once, not retried: \(busyCount)")
    }

    @Test("a large living feed that delivers slowly but steadily gets through the short silence")
    func aSlowSteadyFeedArrives() async throws {
        let stand = try await Stand.start(.trickle(bytes: 12, gapMs: 200))
        defer { stand.stop() }
        let session = URLSession(configuration: .ephemeral)
        // Twelve bytes over 2.4 s, never more than 0.2 s apart, against a
        // silence limit of one second: the whole transfer is longer than the
        // limit, no gap comes near it. A gap of 0.4 s under a loaded machine
        // once reached the limit and measured the load, not the path.
        let (data, answer) = try await RequestRetryPolicy.fetch(try Self.request(stand, silence: 1),
                                                                session: session, once: true)
        #expect(answer?.statusCode == 200)
        #expect(data.count == 12, "the whole body arrived: \(data.count)")
    }

    @Test("every reader names the show as the source names it")
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

    @Test("an Apple state carries its show and is in place as soon as it is followed")
    func appleStatesCarryTheirShow() async throws {
        let run = UUID().uuidString.prefix(8)
        let a = "https://a-\(run).example/feed.xml"
        let b = "https://b-\(run).example/feed.xml"
        let gone = "https://gone-\(run).example/feed.xml"
        let aEpisode = "rss:bulk:a-\(run).example-0"
        // A database of the shape the Mac writes: episodes name their show
        // by row number. Two followed shows, one no longer followed, and
        // one episode without a show.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("apple-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        try #require(sqlite3_open(file.path, &db) == SQLITE_OK)
        let sql = """
        CREATE TABLE ZMTPODCAST (Z_PK INTEGER PRIMARY KEY, ZFEEDURL TEXT, ZSUBSCRIBED INTEGER, ZTITLE TEXT);
        CREATE TABLE ZMTEPISODE (ZENCLOSUREURL TEXT, ZPLAYHEAD REAL, ZDURATION REAL, ZPODCAST INTEGER);
        INSERT INTO ZMTPODCAST VALUES (1, '\(a)', 1, 'Apple A');
        INSERT INTO ZMTPODCAST VALUES (2, '\(b)', 1, 'Apple B');
        INSERT INTO ZMTPODCAST VALUES (3, '\(gone)', 0, 'Apple Gone');
        INSERT INTO ZMTEPISODE VALUES ('https://a-\(run).example/0.mp3', 120, 600, 1);
        INSERT INTO ZMTEPISODE VALUES ('https://b-\(run).example/0.mp3', 200, 600, 2);
        INSERT INTO ZMTEPISODE VALUES ('https://gone-\(run).example/0.mp3', 50, 600, 3);
        INSERT INTO ZMTEPISODE VALUES ('https://orphan-\(run).example/0.mp3', 30, 600, NULL);
        """
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let library = try #require(PodcastImport.readAppleLibrary(at: file))
        #expect(library.feedURLs == [a, b])
        let byEnclosure = Dictionary(uniqueKeysWithValues: library.states.compactMap { state in
            state.enclosureURL.map { ($0, state) }
        })
        try #require(byEnclosure.count == 4, "every played row is a state: \(library.states.count)")
        #expect(byEnclosure["https://a-\(run).example/0.mp3"]?.feedURL == a)
        #expect(byEnclosure["https://a-\(run).example/0.mp3"]?.showTitle == "Apple A")
        #expect(byEnclosure["https://b-\(run).example/0.mp3"]?.feedURL == b)
        #expect(byEnclosure["https://gone-\(run).example/0.mp3"]?.feedURL == gone, "a show no longer followed is still named")
        #expect(byEnclosure["https://orphan-\(run).example/0.mp3"]?.feedURL == nil, "no show, no feed")

        // The import: A answers, B stays silent until the witness has looked.
        let (subs, defaults, cleanup) = try await Self.storeAndDefaults()
        defer {
            cleanup()
            ListeningStore.clearBackup(aEpisode, in: defaults)
            ForeignMarks.clear(aEpisode, in: defaults)
            FeedAdoptionPending.clear(feedKey: PodcastIdentity.feedKey(b))
        }
        let gate = Gate()
        subs._testFeedFetcher = { url in
            if url.host == "a-\(run).example" { return .show(Self.show(url, title: "Apple A", episodes: 1)) }
            while await MainActor.run(body: { !gate.open }) { try? await Task.sleep(nanoseconds: 20_000_000) }
            return .failed(.timeout)
        }
        let importing = Task { await subs.importForeignLibrary(library) }
        var landedWhileWaiting = false
        for _ in 0..<150 where !landedWhileWaiting {
            landedWhileWaiting = ListeningStore.backup(aEpisode, in: defaults)?.first == 120
            if !landedWhileWaiting { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        gate.open = true
        _ = await importing.value
        #expect(landedWhileWaiting, "A's Apple state stood while B was still unanswered: an abort there keeps it")
    }

    @Test("the bulk import asks once and briefly, one place", .needsTheSources)
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

    // MARK: - Size

    @Test("an import writes the marks once per application, not per episode")
    func marksAreWrittenOncePerApply() async throws {
        let (subs, defaults, cleanup) = try await Self.storeAndDefaults()
        let run = UUID().uuidString.prefix(8)
        let feed = "https://marks-\(run).example/feed.xml"
        let ids = (0..<30).map { "rss:bulk:marks-\(run).example-\($0)" }
        defer {
            cleanup()
            for id in ids { ListeningStore.clearBackup(id, in: defaults); ForeignMarks.clear(id, in: defaults) }
        }
        let states = (0..<30).map {
            ForeignListeningState(feedURL: feed, episodeGUID: nil,
                                  enclosureURL: "https://marks-\(run).example/\($0).mp3", episodeLink: nil,
                                  episodeTitle: nil, position: 60, duration: 600, finished: false,
                                  stampedAt: Double(1_000 + $0), archived: $0 < 5)
        }
        subs._testFeedFetcher = { url in .show(Self.show(url, title: "Marks", episodes: 30)) }
        _ = ForeignMarks.importedIDs(in: defaults)
        _ = ForeignMarks.isArchived("", in: defaults)
        let writes = ForeignMarks.listWrites
        let result = await subs.importForeignLibrary(ForeignLibrary(feedURLs: [feed], states: states))
        try #require(result.progressApplied == 30, "every state was applied: \(result.progressApplied)")
        #expect(ForeignMarks.listWrites - writes == 2, "one write for imported, one for archived: \(ForeignMarks.listWrites - writes)")
        #expect(ForeignMarks.importedIDs(in: defaults).isSuperset(of: ids))
        let archived = ids.prefix(5).filter { ForeignMarks.isArchived($0, in: defaults) }
        #expect(archived.count == 5)
    }

    @Test("the ladder keeps the preferred state per episode, even across many states")
    func theLadderKeepsOnePreferredStatePerEpisode() throws {
        let count = 3_000
        let targets = (0..<count).map { e in
            ForeignMatchTarget(id: "t\(e)", rawGUID: "g\(e)", enclosureURL: "https://x.example/\(e).mp3",
                               link: nil, title: "t \(e)", feedKey: "k")
        }
        // Every episode twice in the source: for even ones the second
        // state is newer, for odd ones older.
        let states = (0..<count).flatMap { e -> [ForeignListeningState] in
            let first = ForeignListeningState(feedURL: nil, episodeGUID: nil, enclosureURL: "https://x.example/\(e).mp3",
                                              episodeLink: nil, episodeTitle: nil, position: 10, duration: 600,
                                              finished: false, stampedAt: 10_000)
            var second = first
            second.position = 20
            second.stampedAt = e.isMultiple(of: 2) ? 20_000 : 5_000
            return [first, second]
        }
        let plan = ForeignStateMatcher.plan(states: states, targets: targets, feedKeyOf: { $0 })
        try #require(plan.matches.count == count, "one match per episode: \(plan.matches.count)")
        let byTarget = Dictionary(uniqueKeysWithValues: plan.matches.map { ($0.targetID, $0.state.position) })
        let wrong = (0..<count).filter { byTarget["t\($0)"] != ($0.isMultiple(of: 2) ? 20 : 10) }
        #expect(wrong.isEmpty, "the newer state is kept, whichever came first: \(wrong.prefix(5))")
        #expect(plan.unmatched.isEmpty)
    }
}
#endif
