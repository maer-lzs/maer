// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
import Network
import os
import Synchronization
@testable import Maer

/// Which request carries a server's headers, without the network.
struct ServerHeaderRuleTests {
    static func entry(_ base: String, _ name: String) -> ServerHeaderRule.Entry {
        ServerHeaderRule.Entry(base: URL(string: base)!, headers: [.init(name: name, value: "v-\(name)")])
    }

    static let entries = [entry("https://h.example/abs", "X-Abs"), entry("https://h.example", "X-Root")]

    func header(_ url: String) -> String? {
        ServerHeaderRule.entry(for: URL(string: url)!, in: Self.entries)?.headers.first?.name
    }

    @Test("Herkunft: zwei Server auf einem Host, der laengere Pfad gewinnt; ein anderer Port bekommt nichts")
    func twoServersOnOneHost() {
        #expect(header("https://h.example/abs/api/items") == "X-Abs")
        #expect(header("https://h.example/abs") == "X-Abs")
        #expect(header("https://h.example/other") == "X-Root")
        #expect(header("https://h.example/absx/api") == "X-Root", "a path is a whole segment, not a prefix of letters")
        #expect(header("https://h.example:8443/abs/api") == nil, "another port is another server")
        #expect(header("http://h.example/abs/api") == nil, "another scheme is another server")
        #expect(header("https://other.example/abs/api") == nil)
        #expect(header("https://h.example:443/abs/api") == "X-Abs", "the default port written out is the same server")
    }

    @Test("Namen: was die App selbst setzt und was kein HTTP-Token ist, wird abgewiesen")
    func namesTheAppSetsAreRefused() {
        for name in ["Authorization", "user-agent", "Content-Type", "Content-Length", "Cookie", "Host", "", "Bad Name", "X-ä"] {
            #expect(!ServerHeaderRule.isAllowed(name: name), "\(name)")
        }
        for name in ["CF-Access-Client-Id", "CF-Access-Client-Secret", "X-Authentik-Token", "Remote-User"] {
            #expect(ServerHeaderRule.isAllowed(name: name), "\(name)")
        }
    }

    @Test("genau einmal: ein Header, den die Anfrage schon traegt, wird ersetzt, nicht verdoppelt")
    func exactlyOnce() throws {
        var request = URLRequest(url: try #require(URL(string: "https://h.example/abs/api")))
        request.setValue("old", forHTTPHeaderField: "x-abs")
        let out = ServerHeaderRule.applied(request, entries: Self.entries)
        let fields = out.allHTTPHeaderFields ?? [:]
        #expect(fields.keys.filter { $0.lowercased() == "x-abs" }.count == 1)
        #expect(out.value(forHTTPHeaderField: "X-Abs") == "v-X-Abs")
    }

    @Test("Umleitung: wer den Server verlaesst, laesst seine Header dort; wer einen anderen erreicht, bekommt dessen")
    func aRedirectLeavesTheHeadersBehind() throws {
        let start = try #require(URL(string: "https://h.example/abs/a"))
        let sent = ServerHeaderRule.applied(URLRequest(url: start), entries: Self.entries)
        let away = ServerHeaderRule.redirected(URLRequest(url: try #require(URL(string: "https://cdn.example/f"))),
                                               from: start, entries: Self.entries)
        #expect(away.value(forHTTPHeaderField: "X-Abs") == nil)
        var carried = sent
        carried.url = URL(string: "https://cdn.example/f")
        let stripped = ServerHeaderRule.redirected(carried, from: start, entries: Self.entries)
        #expect(stripped.value(forHTTPHeaderField: "X-Abs") == nil, "the header the session carried along is taken off")
        var toRoot = sent
        toRoot.url = URL(string: "https://h.example/other")
        let root = ServerHeaderRule.redirected(toRoot, from: start, entries: Self.entries)
        #expect(root.value(forHTTPHeaderField: "X-Abs") == nil)
        #expect(root.value(forHTTPHeaderField: "X-Root") == "v-X-Root")
        var within = sent
        within.url = URL(string: "https://h.example/abs/b")
        #expect(ServerHeaderRule.redirected(within, from: start, entries: Self.entries)
            .value(forHTTPHeaderField: "X-Abs") == "v-X-Abs")
    }
}

/// The four ways out of the app against a host on the loopback that records
/// every request head: each way carries a server's headers to that server,
/// once, and to no other host, over 301, 302, 307 and 308.
@Suite(.serialized)
@MainActor
struct ServerHeadersWayTests {
    typealias Host = HeaderRedirectMeasureTests.RecordingHost

    /// A keychain and a register of a witness's own; `keys(items:)` lets
    /// two devices read the same items, as the iCloud keychain does.
    nonisolated final class MemoryKeys: Sendable {
        struct State {
            var items: [String: String] = [:]
            var bases: [String] = []
            var readable = true
            /// False: the keychain takes no write.
            var takes = true
        }
        let state: Mutex<State>
        init(_ state: State = State()) { self.state = Mutex(state) }

        func keys(items from: MemoryKeys? = nil) -> ServerHeaders.Keys {
            let source = from ?? self
            return ServerHeaders.Keys(
                list: { source.state.withLock { $0.readable ? $0.items : nil } },
                write: { account, value in
                    source.state.withLock { state in
                        guard state.takes else { return false }
                        state.items[account] = value
                        return true
                    }
                },
                bases: { [self] in state.withLock { $0.bases } },
                setBases: { [self] bases in state.withLock { $0.bases = bases } }
            )
        }
    }

    static let name = "X-Maer-Gate"
    static let value = "gate-\(UUID().uuidString.prefix(8))"
    static let needle = "\(name.lowercased()): \(value.lowercased())"

    static func carried(_ head: String) -> Int { head.components(separatedBy: "\r\n\(needle)").count - 1 }

    enum Way: String, CaseIterable, Sendable { case door, retryingFetch, backgroundDownload, stream }

    func started() async throws -> (origin: Host, other: Host) {
        let body = try HeaderRedirectMeasureTests.tone()
        let origin = try Host(body: body, contentType: "audio/x-caf")
        let other = try Host(body: body, contentType: "audio/x-caf")
        try await origin.start()
        try await other.start()
        return (origin, other)
    }

    func headers(for origin: Host) -> MemoryKeys {
        let keys = MemoryKeys()
        ServerHeaders.$witness.withValue(keys.keys()) {
            _ = ServerHeaders.set([.init(name: Self.name, value: Self.value)],
                                  for: URL(string: "http://127.0.0.1:\(origin.port)")!)
        }
        return keys
    }

    /// One request to `start` on `way`, with the witness's keys.
    func ask(_ way: Way, _ start: URL, keys: ServerHeaders.Keys) async {
        await ServerHeaders.$witness.withValue(keys) {
            switch way {
            case .door:
                // bearable, because the witness reads the heads the host recorded
                _ = try? await HTTP.data(for: URLRequest(url: start), lane: .api, retry: false)
            case .retryingFetch:
                // bearable, because the witness reads the heads the host recorded
                _ = try? await RequestRetryPolicy.fetch(URLRequest(url: start), once: true)
            case .backgroundDownload:
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sh-\(UUID().uuidString).caf")
                defer { try? FileManager.default.removeItem(at: destination) }
                // bearable, because the witness reads the heads the host recorded
                try? await FileDownloader.shared.download(request: URLRequest(url: start), to: destination, onProgress: { _ in })
            case .stream:
                // The player's way: the plan first, then the asset as it builds it.
                let plan = await ServerHeaders.stream(for: start, sourceHeaders: [:])
                guard case .resolved(let end, let headers) = plan else {
                    Issue.record("the stream of a server with headers was not resolved: \(plan)")
                    return
                }
                let asset = AVURLAsset(url: end, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                // bearable, because the witness reads the heads the host recorded
                _ = try? await asset.load(.duration)
            }
        }
    }

    @Test("jeder Ausgang traegt die Header genau einmal zu seinem Server und zu keinem fremden Host, je Umleitung",
          arguments: Way.allCases, [301, 302, 307, 308])
    func eachWayCarriesThemToItsServerOnly(way: Way, status: Int) async throws {
        let (origin, other) = try await started()
        defer { origin.stop(); other.stop() }
        let keys = headers(for: origin)
        for foreign in [false, true] {
            // Lowercase: the host keeps every head lowercased.
            let tag = "\(way.rawValue)-\(status)-\(foreign ? "away" : "home")".lowercased()
            let finalURL = try #require(URL(string: foreign
                ? "http://localhost:\(other.port)/final-\(tag)"
                : "http://127.0.0.1:\(origin.port)/final-\(tag)"))
            origin.redirect(to: finalURL, status: status)
            await ask(way, try #require(URL(string: "http://127.0.0.1:\(origin.port)/start-\(tag)")), keys: keys.keys())
            let starts = origin.recorded.filter { $0.contains("/start-\(tag)") }
            let finals = (foreign ? other : origin).recorded.filter { $0.contains("/final-\(tag)") }
            try #require(!starts.isEmpty && !finals.isEmpty, "the witness reached both addresses: \(tag)")
            #expect(starts.allSatisfy { Self.carried($0) == 1 } == true, "the first request carries the header once: \(tag)")
            let atFinal = finals.map(Self.carried)
            if foreign {
                #expect(atFinal.allSatisfy { $0 == 0 } == true, "a foreign host got the header: \(tag) \(atFinal)")
            } else {
                #expect(atFinal.allSatisfy { $0 == 1 } == true, "the server lost or doubled its header: \(tag) \(atFinal)")
            }
        }
    }

    @Test("ein Host ohne Header bekommt keine, und der Stream bleibt der alte Weg ohne Vorab-Anfrage")
    func aServerWithoutHeadersStaysAsItWas() async throws {
        let (origin, other) = try await started()
        defer { origin.stop(); other.stop() }
        let keys = headers(for: other)
        let start = try #require(URL(string: "http://127.0.0.1:\(origin.port)/plain"))
        let plan = await ServerHeaders.$witness.withValue(keys.keys()) {
            await ServerHeaders.stream(for: start, sourceHeaders: ["Authorization": "Bearer t"])
        }
        #expect(plan == .plain)
        #expect(origin.recorded.isEmpty, "the stream of a server without headers was asked ahead")
        await ask(.door, start, keys: keys.keys())
        #expect(origin.recorded.allSatisfy { Self.carried($0) == 0 } == true)
        let anyServer = ServerHeaders.$witness.withValue(MemoryKeys().keys()) { ServerHeaders.anyServer() }
        #expect(!anyServer, "with no server with headers the player does not wait for a plan")
    }

    @Test("unlesbar ist unbekannt: an einen Server mit Headern geht nichts ohne sie, an andere schon, lesbar wieder mit")
    func unreadableHoldsTheRequest() async throws {
        let (origin, other) = try await started()
        defer { origin.stop(); other.stop() }
        let keys = headers(for: origin)
        #expect(keys.state.withLock { $0.bases } == ["http://127.0.0.1:\(origin.port)"])
        keys.state.withLock { $0.readable = false }
        let held = try #require(URL(string: "http://127.0.0.1:\(origin.port)/held"))
        let thrown = await ServerHeaders.$witness.withValue(keys.keys()) { () async -> Error? in
            do {
                _ = try await HTTP.data(for: URLRequest(url: held), lane: .api, retry: false)
                return nil
            } catch {
                return error
            }
        }
        #expect(thrown as? ServerHeaders.Unreadable == ServerHeaders.Unreadable(host: "127.0.0.1"))
        #expect(origin.recorded.isEmpty, "a request went out without its headers")
        let plan = await ServerHeaders.$witness.withValue(keys.keys()) {
            await ServerHeaders.stream(for: held, sourceHeaders: [:])
        }
        #expect(plan == .waiting)
        await ask(.door, try #require(URL(string: "http://127.0.0.1:\(other.port)/free")), keys: keys.keys())
        #expect(other.recorded.count == 1, "a server without headers is asked as before")
        keys.state.withLock { $0.readable = true }
        await ask(.door, held, keys: keys.keys())
        #expect(origin.recorded.map(Self.carried) == [1], "read again, the request goes with its headers")
    }

    @Test("ein zweites Geraet erreicht den Server mit den Headern, die das erste abgelegt hat, ohne Eingabe")
    func aSecondDeviceReachesTheServer() async throws {
        let (origin, other) = try await started()
        defer { origin.stop(); other.stop() }
        let first = headers(for: origin)
        let second = MemoryKeys()
        #expect(second.state.withLock { $0.bases }.isEmpty, "the second device entered nothing")
        await ask(.door, try #require(URL(string: "http://127.0.0.1:\(origin.port)/second")), keys: second.keys(items: first))
        #expect(origin.recorded.map(Self.carried) == [1])
    }

    @Test("einen Server von Hand entfernen nimmt seine Header ueberall mit, abmelden laesst sie stehen")
    func removingTheServerRemovesTheHeaders() async throws {
        let keys = MemoryKeys()
        let base = try #require(URL(string: "https://forget-\(UUID().uuidString.prefix(6)).example/abs"))
        let defaults = try #require(UserDefaults(suiteName: "server-headers-\(UUID().uuidString)"))
        ServerHeaders.$witness.withValue(keys.keys()) {
            _ = ServerHeaders.set([.init(name: Self.name, value: Self.value)], for: base)
        }
        #expect(keys.state.withLock { $0.items.count } == 1)
        ServerHeaders.$witness.withValue(keys.keys()) {
            ServerHeaders.forget(KnownServer(url: base.absoluteString, service: .audiobookshelf, lastSuccessAt: 0),
                                 defaults: defaults)
        }
        #expect(keys.state.withLock { $0.items }.isEmpty, "the headers stayed after the server was removed")
        #expect(keys.state.withLock { $0.bases }.isEmpty)
        // An item still under an old spelling of the server goes with it.
        let old = ServerHeaders.accountPrefix + base.absoluteString.uppercased().replacingOccurrences(of: "/ABS", with: "/abs/")
        keys.state.withLock {
            $0.items = [ServerHeaders.accountPrefix + "https://" + base.host! + "/abs": "[]", old: "[]"]
        }
        ServerHeaders.$witness.withValue(keys.keys()) {
            ServerHeaders.forget(KnownServer(url: base.absoluteString, service: .audiobookshelf, lastSuccessAt: 0),
                                 defaults: defaults)
        }
        #expect(keys.state.withLock { $0.items }.isEmpty, "an item under an old spelling stayed after the server was removed")
    }

    @Test("ein fortgesetzter Download eines Servers mit Headern beginnt neu, mit den Headern von heute")
    func aResumedDownloadStartsAnew() async throws {
        let (origin, other) = try await started()
        defer { origin.stop(); other.stop() }
        let keys = headers(for: origin)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sh-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: destination) }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/resumed.caf"))
        await ServerHeaders.$witness.withValue(keys.keys()) {
            // bearable, because the witness reads the heads the host recorded
            try? await FileDownloader.shared.download(request: URLRequest(url: url), to: destination,
                                                      resumeData: Data("paused with yesterday's headers".utf8),
                                                      onProgress: { _ in })
        }
        // The ask for the end of the redirects goes first; the download is
        // the request without its range.
        let downloads = origin.recorded.filter { !$0.contains("range: bytes=0-0") }
        #expect(downloads.map(Self.carried) == [1], "the download was not started anew with its headers")
    }

    @Test("benannte Grenze: leitet der eigene Server seine Endadresse spaeter um, traegt der Stream die Header mit (gemessen)")
    func aLaterRedirectOfTheServerCarriesTheHeaders() async throws {
        let (origin, other) = try await started()
        defer { origin.stop(); other.stop() }
        let keys = headers(for: origin)
        let track = try #require(URL(string: "http://127.0.0.1:\(origin.port)/late-track"))
        origin.redirecting.withLock { $0 = "/nothing" }
        let plan = await ServerHeaders.$witness.withValue(keys.keys()) {
            await ServerHeaders.stream(for: track, sourceHeaders: [:])
        }
        guard case .resolved(let end, let headers) = plan else {
            Issue.record("the end at the server was not resolved: \(plan)")
            return
        }
        #expect(end == track)
        origin.redirecting.withLock { $0 = "/late" }
        origin.redirect(to: try #require(URL(string: "http://localhost:\(other.port)/late-away")))
        let asset = AVURLAsset(url: end, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        // bearable, because the witness reads the heads the host recorded
        _ = try? await asset.load(.duration)
        let away = other.recorded.filter { $0.contains("/late-away") }
        try #require(!away.isEmpty, "the later redirect was followed")
        #expect(away.map(Self.carried).max() == 1,
                "the boundary moved: a later redirect of the server no longer carries the headers, write it down")
    }

    /// A host that ignores the range and sends without end, as a
    /// transcoded stream does; it counts what it sent and notes when the
    /// other side closed. Unchecked because the listener and its
    /// connections are only touched on the listener's own queue after
    /// start; the counts sit behind a lock.
    nonisolated final class EndlessHost: @unchecked Sendable {
        private let listener: NWListener
        let sent = OSAllocatedUnfairLock(initialState: 0)
        let closed = OSAllocatedUnfairLock(initialState: false)
        private(set) var port: UInt16 = 0

        init() throws { listener = try NWListener(using: .tcp, on: .any) }

        func start() async throws {
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] _, _, _, _ in
                    let head = Data("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\n".utf8)
                    connection.send(content: head, completion: .contentProcessed { [self] _ in pour(connection) })
                }
            }
            port = try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { [listener] state in
                    let first = once.withLock { done in
                        let was = done
                        if case .ready = state { done = true } else if case .failed = state { done = true }
                        return !was && done
                    }
                    if first, case .ready = state { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    if first, case .failed(let error) = state { continuation.resume(throwing: error) }
                }
                listener.start(queue: .global())
            }
        }

        private func pour(_ connection: NWConnection) {
            let chunk = Data(repeating: 0xFF, count: 65_536)
            connection.send(content: chunk, completion: .contentProcessed { [self] error in
                if error != nil {
                    closed.withLock { $0 = true }
                    connection.cancel()
                    return
                }
                sent.withLock { $0 += chunk.count }
                pour(connection)
            })
        }

        func stop() { listener.cancel() }
    }

    @Test("die Vorab-Anfrage liest nur den Kopf: ein Server, der Range nicht beachtet und ohne Ende sendet, haelt sie nicht auf")
    func theAskAheadReadsTheHeadOnly() async throws {
        let host = try EndlessHost()
        try await host.start()
        defer { host.stop() }
        let keys = MemoryKeys()
        let url = try #require(URL(string: "http://127.0.0.1:\(host.port)/transcoded"))
        let base = try #require(URL(string: "http://127.0.0.1:\(host.port)"))
        ServerHeaders.$witness.withValue(keys.keys()) {
            _ = ServerHeaders.set([.init(name: Self.name, value: Self.value)], for: base)
        }
        let started = Date()
        let ask = Task { await ServerHeaders.$witness.withValue(keys.keys()) { await ServerHeaders.stream(for: url, sourceHeaders: [:]) } }
        let deadline = Task {
            try await Task.sleep(for: .seconds(8))
            ask.cancel()
        }
        let plan = await ask.value
        deadline.cancel()
        let seconds = Date().timeIntervalSince(started)
        #expect(seconds < 5, "the ask ahead read the endless body: \(seconds) s")
        #expect(plan == .resolved(url, headers: [Self.name: Self.value]))
        try await Task.sleep(for: .seconds(1))
        let after = host.sent.withLock { $0 }
        try await Task.sleep(for: .seconds(1))
        #expect(host.sent.withLock { $0 } == after, "the host still sends after the ask ended")
        #expect(host.closed.withLock { $0 }, "the ask did not close its connection")
    }

    /// A title of fifty tracks of `seconds` each on a server with headers,
    /// the model that loads it, and the tracks the server was asked ahead
    /// for (`Range: bytes=0-0`), by number.
    func fiftyTracks(seconds: Int = 1) async throws -> (origin: Host, other: Host, keys: MemoryKeys, book: LibraryItemDetail) {
        let body = seconds == 1 ? try HeaderRedirectMeasureTests.tone() : try Data(contentsOf: try TickWorkTests().tone(seconds: Double(seconds)))
        let origin = try Host(body: body, contentType: "audio/x-caf")
        let other = try Host(body: body, contentType: "audio/x-caf")
        try await origin.start()
        try await other.start()
        let keys = headers(for: origin)
        let tracks = (0..<50).map { index in
            ABSAudioTrack(index: index, startOffset: Double(index * seconds), duration: Double(seconds),
                          contentUrl: "http://127.0.0.1:\(origin.port)/track-\(index).caf", metadata: nil)
        }
        let book = LibraryItemDetail(
            id: "headers-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: Double(50 * seconds), chapters: nil, tracks: tracks),
            userMediaProgress: nil)
        return (origin, other, keys, book)
    }

    static func askedAhead(_ host: Host) -> [Int] {
        host.recorded.filter { $0.contains("range: bytes=0-0") }.compactMap { head in
            guard let range = head.range(of: "/track-"), let end = head[range.upperBound...].firstIndex(of: ".") else { return nil }
            return Int(head[range.upperBound..<end])
        }.sorted()
    }

    @Test("ein Titel mit 50 Spuren fragt beim Start nur die Spur, mit der er beginnt, und die naechsten zwei; die Warteschlange haelt sie")
    func aStartAsksOnlyTheTracksItNeedsSoon() async throws {
        let (origin, other, keys, book) = try await fiftyTracks()
        defer { origin.stop(); other.stop() }
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: true),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await ServerHeaders.$witness.withValue(keys.keys()) { await model.load(item: book) }
        #expect(Self.askedAhead(origin) == [0], "the start waited for more than the track it begins with: \(Self.askedAhead(origin))")
        #expect(model.player?.items().count == 1, "the queue holds only the planned track at the start")
        // Long enough for every ask the start makes to land.
        try await Task.sleep(for: .seconds(2))
        #expect(Self.askedAhead(origin) == [0, 1, 2], "the start asked ahead for tracks it does not need soon: \(Self.askedAhead(origin))")
        #expect(model.player?.items().count == 3, "the queue does not hold the planned tracks: \(model.player?.items().count ?? 0)")
        model.stop()
    }

    @Test("nach dem Wechsel auf die naechste Spur wird genau eine Spur mehr gefragt", .needsAudio)
    func theNextTrackAsksExactlyOneMore() async throws {
        // A source with a sign-in, not server headers: the tick that notes
        // the switch runs in a task of its own, outside the test's keychain
        // seam, and would see a server without headers.
        let (origin, other, _, book) = try await fiftyTracks(seconds: 3)
        defer { origin.stop(); other.stop() }
        let model = PlayerViewModel(provider: HostBoundProvider(host: "127.0.0.1"),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(MemoryKeys().keys()) {
            await model.load(item: book)
            try await Task.sleep(for: .seconds(1))
            try #require(Self.askedAhead(origin) == [0, 1, 2], "the precondition: the start asked the first three: \(Self.askedAhead(origin))")
            model.player?.volume = 0
            model.play()
            // The first track lasts three seconds; the tick notes the second.
            let deadline = Date().addingTimeInterval(8)
            while Self.askedAhead(origin).count < 4, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(Self.askedAhead(origin) == [0, 1, 2, 3], "the switch to the second track asked \(Self.askedAhead(origin))")
            model.stop()
        }
    }

    @Test("ein Sprung auf Spur 40 fragt Spur 40 und ihre zwei Nachbarn, nicht die Spuren davor")
    func aJumpAsksItsTrackAndItsNeighbours() async throws {
        let (origin, other, keys, book) = try await fiftyTracks()
        defer { origin.stop(); other.stop() }
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: true),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(keys.keys()) {
            await model.load(item: book)
            try await Task.sleep(for: .seconds(1))
            await model.seek(to: 40.5, userInitiated: false)
            try await Task.sleep(for: .seconds(2))
            #expect(Self.askedAhead(origin) == [0, 1, 2, 40, 41, 42], "the jump asked \(Self.askedAhead(origin))")
            let built = (model.player?.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent
            #expect(built == "track-40.caf", "the jump built \(String(describing: built))")
            model.stop()
        }
    }

    /// A title of ten tracks with headers: the first five on a host that
    /// answers at once, the others on one that answers after two seconds,
    /// so a jump to one of them waits for its plan.
    func splitTitle() async throws -> (quick: Host, slow: Host, keys: MemoryKeys, book: LibraryItemDetail) {
        let body = try HeaderRedirectMeasureTests.tone()
        let quick = try Host(body: body, contentType: "audio/x-caf")
        let slow = try Host(body: body, contentType: "audio/x-caf", delay: 2)
        try await quick.start()
        try await slow.start()
        let keys = MemoryKeys()
        let bases = try [quick.port, slow.port].map { try #require(URL(string: "http://127.0.0.1:\($0)")) }
        ServerHeaders.$witness.withValue(keys.keys()) {
            for base in bases { _ = ServerHeaders.set([.init(name: Self.name, value: Self.value)], for: base) }
        }
        let tracks = (0..<10).map { index in
            ABSAudioTrack(index: index, startOffset: Double(index), duration: 1,
                          contentUrl: "http://127.0.0.1:\(index < 5 ? quick.port : slow.port)/track-\(index).caf", metadata: nil)
        }
        let book = LibraryItemDetail(
            id: "jump-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 10, chapters: nil, tracks: tracks),
            userMediaProgress: nil)
        return (quick, slow, keys, book)
    }

    static func playing(_ model: PlayerViewModel) -> String? {
        (model.player?.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent
    }

    @Test("ein Sprung, der auf den Plan seiner Spur wartet, baut nicht in einen inzwischen geoeffneten Titel")
    func aWaitingJumpYieldsToANewTitle() async throws {
        let (quick, slow, keys, book) = try await splitTitle()
        defer { quick.stop(); slow.stop() }
        let other = LibraryItemDetail(
            id: "other-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 1, chapters: nil, tracks: [
                ABSAudioTrack(index: 0, startOffset: 0, duration: 1,
                              contentUrl: "http://localhost:\(quick.port)/other-0.caf", metadata: nil),
            ]),
            userMediaProgress: nil)
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: true),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(keys.keys()) {
            await model.load(item: book)
            let jump = Task { await model.seek(to: 7.5, userInitiated: false) }
            try await Task.sleep(for: .milliseconds(300))
            await model.load(item: other)
            await jump.value
        }
        #expect(model.item?.id == other.id)
        #expect(Self.playing(model) == "other-0.caf", "the old jump built its track: \(String(describing: Self.playing(model)))")
        #expect(model.currentTime < 1, "the old jump set its time on the new title: \(model.currentTime)")
    }

    @Test("ein aelterer Sprung, der auf den Plan seiner Spur wartet, baut nicht ueber einen juengeren")
    func aWaitingJumpYieldsToALaterOne() async throws {
        let (quick, slow, keys, book) = try await splitTitle()
        defer { quick.stop(); slow.stop() }
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: true),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(keys.keys()) {
            await model.load(item: book)
            let first = Task { await model.seek(to: 7.5, userInitiated: false) }
            try await Task.sleep(for: .milliseconds(300))
            await model.seek(to: 1.6, userInitiated: false)
            await first.value
        }
        #expect(Self.playing(model) == "track-1.caf", "the older jump built over the later one: \(String(describing: Self.playing(model)))")
        // 0.6 s into track 1, past the half second from which `buildQueue`
        // seeks into a track: the later jump's own time arrived, not the
        // start of its track and not the older jump's 7.5.
        #expect((1.5..<2.0).contains(model.currentTime), "the later jump did not set its time: \(model.currentTime)")
    }

    @Test("ein Sprung, der auf den Plan seiner Spur wartet, bewegt ein inzwischen gestopptes Modell nicht")
    func aWaitingJumpLeavesAStoppedModel() async throws {
        let (quick, slow, keys, book) = try await splitTitle()
        defer { quick.stop(); slow.stop() }
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: true),
                                    localTracks: { _ in [:] }, isOnline: { true })
        try await ServerHeaders.$witness.withValue(keys.keys()) {
            await model.load(item: book)
            let stood = model.currentTime
            let jump = Task { await model.seek(to: 7.5, userInitiated: false) }
            try await Task.sleep(for: .milliseconds(300))
            model.stop()
            await jump.value
            #expect(model.isStopped)
            #expect(model.currentTime == stood, "the jump moved the stopped model to \(model.currentTime)")
            #expect(Self.playing(model) != "track-7.caf", "the jump built its track on the stopped model")
        }
    }

    /// A source whose sign-in is bound to one host name: it answers the
    /// form with the address, and the form without it only says readable.
    /// Every other host gets `elsewhere`: none, or nil for a sign-in that
    /// cannot be read there now.
    final class HostBoundProvider: AudioProvider {
        let host: String
        let elsewhere: [String: String]?
        init(host: String, elsewhere: [String: String]? = [:]) {
            self.host = host
            self.elsewhere = elsewhere
        }
        var providerId: String { "host-bound" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func streamAuthHeaders(forItemId itemId: String, to url: URL) -> [String: String]? {
            url.host == host ? ["Authorization": "Basic cGxhbjpwbGFu"] : elsewhere
        }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw NSError(domain: "host-bound", code: 404) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { URL(string: contentPath) }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("der Plan einer Spur fragt die Anmeldung der Quelle fuer die Adresse der Spur: am Host der Quelle mit ihr, an einem anderen Namen ohne")
    func thePlanAsksTheSignInForTheTracksAddress() async throws {
        let (origin, other) = try await started()
        defer { origin.stop(); other.stop() }
        let keys = MemoryKeys()
        // Both addresses are servers with headers, so both tracks are planned.
        try ServerHeaders.$witness.withValue(keys.keys()) {
            for base in ["http://127.0.0.1:\(origin.port)", "http://localhost:\(other.port)"] {
                _ = ServerHeaders.set([.init(name: Self.name, value: Self.value)], for: try #require(URL(string: base)))
            }
        }
        func book(_ address: String) -> LibraryItemDetail {
            LibraryItemDetail(
                id: "plan-\(UUID().uuidString)",
                media: LibraryItemMedia(metadata: nil, duration: 1, chapters: nil, tracks: [
                    ABSAudioTrack(index: 0, startOffset: 0, duration: 1, contentUrl: address, metadata: nil),
                ]),
                userMediaProgress: nil)
        }
        let model = PlayerViewModel(provider: HostBoundProvider(host: "127.0.0.1"), localTracks: { _ in [:] }, isOnline: { true })
        await ServerHeaders.$witness.withValue(keys.keys()) {
            await model.load(item: book("http://127.0.0.1:\(origin.port)/own.caf"))
        }
        let own = origin.recorded.filter { $0.contains("/own.caf") && $0.contains("range: bytes=0-0") }
        try #require(own.count == 1, "the own track was asked ahead \(own.count) times")
        #expect(own[0].contains("authorization: basic cgxhbjpwbgfu"), "the plan asked the source's host without its sign-in")
        await ServerHeaders.$witness.withValue(keys.keys()) {
            await model.load(item: book("http://localhost:\(other.port)/foreign.caf"))
        }
        let foreign = other.recorded.filter { $0.contains("/foreign.caf") && $0.contains("range: bytes=0-0") }
        try #require(foreign.count == 1, "the foreign track was asked ahead \(foreign.count) times")
        #expect(!foreign[0].contains("authorization:"), "the plan carried the source's sign-in to another host name")
        #expect(other.recorded.allSatisfy { !$0.contains("authorization:") } == true)
    }
}

/// The plans of a title's tracks: one before the start, the rest after it,
/// at most a few at a time and in the order handed in.
@MainActor
struct StreamPlannerTests {
    /// Counts the asks running at once and the order they started in.
    actor Counter {
        var running = 0
        var most = 0
        var order: [URL] = []
        func begin(_ url: URL) { running += 1; most = max(most, running); order.append(url) }
        func end() { running -= 1 }
    }

    /// How many plans landed, counted on the main actor.
    final class Tally { var count = 0 }

    @Test("Planer: das Fenster ist die Spur und die naechsten zwei, nie hinter der letzten")
    func theWindow() {
        #expect(StreamPlanner.tracksAhead == 2)
        #expect(StreamPlanner.window(from: 0, count: 212) == [0, 1, 2])
        #expect(StreamPlanner.window(from: 40, count: 50) == [40, 41, 42])
        #expect(StreamPlanner.window(from: 48, count: 50) == [48, 49])
        #expect(StreamPlanner.window(from: 0, count: 1) == [0])
        #expect(StreamPlanner.window(from: 50, count: 50) == [])
        #expect(StreamPlanner.window(from: -1, count: 50) == [])
    }

    @Test("Planer: zwei Fenster, die sich ueberlappen, fragen jede Adresse einmal")
    func overlappingWindowsAskEachOnce() async throws {
        let counter = Counter()
        let planner = StreamPlanner(limit: 4) { url in
            await counter.begin(url)
            try? await Task.sleep(for: .milliseconds(100))
            await counter.end()
            return .resolved(url, headers: [:])
        }
        let urls = try (0..<6).map { try #require(URL(string: "https://h.example/t\($0)")) }
        let landed = Tally()
        planner.planAhead(Array(urls[0...2])) { landed.count += 1 }
        // The second window comes while the first is on its way.
        planner.planAhead(Array(urls[1...3])) { landed.count += 1 }
        let deadline = Date().addingTimeInterval(5)
        while landed.count < 4, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        let order = await counter.order
        #expect(order.count == 4, "an address was asked twice: \(order.map(\.lastPathComponent))")
        #expect(Set(order) == Set(urls[0...3]))
    }

    @Test("Planer: ein Plan, der gewollt wird, waehrend seine Adresse im Voraus gefragt wird, wartet auf diese Frage")
    func aPlanWantedWhileAskedAheadWaitsForThatAsk() async throws {
        let counter = Counter()
        let planner = StreamPlanner(limit: 4) { url in
            await counter.begin(url)
            try? await Task.sleep(for: .milliseconds(200))
            await counter.end()
            return .resolved(url, headers: [:])
        }
        let url = try #require(URL(string: "https://h.example/t0"))
        planner.planAhead([url]) {}
        // A jump into the window wants the plan while the ask is on its way.
        let plan = await planner.plan(url)
        #expect(plan == .resolved(url, headers: [:]))
        let order = await counter.order
        #expect(order.count == 1, "the address was asked again: \(order.count)")
    }

    @Test("Planer: stop() beendet die Fragen im Voraus, kein Plan landet danach und keine Frage beginnt")
    func stopEndsTheAsksAhead() async throws {
        let counter = Counter()
        let planner = StreamPlanner(limit: 2) { url in
            await counter.begin(url)
            try? await Task.sleep(for: .milliseconds(300))
            await counter.end()
            return .resolved(url, headers: [:])
        }
        let urls = try (0..<6).map { try #require(URL(string: "https://h.example/t\($0)")) }
        let landed = Tally()
        planner.planAhead(urls) { landed.count += 1 }
        try await Task.sleep(for: .milliseconds(50))
        planner.stop()
        try await Task.sleep(for: .seconds(1))
        let order = await counter.order
        #expect(order.count == 2, "asks began after stop: \(order.count)")
        #expect(landed.count == 0, "a plan landed after stop")
        #expect(planner.plans.isEmpty)
    }

    @Test("Planer: im Voraus hoechstens vier zugleich, in der gegebenen Reihenfolge")
    func oneAheadTheRestBounded() async throws {
        let counter = Counter()
        let planner = StreamPlanner(limit: 4) { url in
            await counter.begin(url)
            try? await Task.sleep(for: .milliseconds(20))
            await counter.end()
            return .resolved(url, headers: [:])
        }
        let urls = try (0..<50).map { try #require(URL(string: "https://h.example/t\($0)")) }
        _ = await planner.plan(urls[0])
        #expect(await counter.order == [urls[0]])
        let landed = Tally()
        planner.planAhead(Array(urls.dropFirst())) { landed.count += 1 }
        let deadline = Date().addingTimeInterval(10)
        while landed.count < 49, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(landed.count == 49)
        #expect(planner.plans.count == 50)
        let most = await counter.most
        let order = await counter.order
        #expect(most <= 4, "more than four asks ran at once: \(most)")
        #expect(most > 1, "the rest was asked one by one")
        // The four first asks start side by side in no fixed order; only the
        // first four of the rest can have started before one of them ended.
        #expect(order.first == urls[0])
        #expect(Set(order.dropFirst().prefix(4)) == Set(urls[1...4]), "the rest was not asked in order")
    }
}

/// The three ways and the stream are the only places that set a server's
/// headers; the door and the fetch pass the rule on at a redirect, the
/// downloader and the stream ask the end of the redirects first.
struct ServerHeadersFenceTests {
    private static func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("Header: genau die drei Wege setzen sie, jeder vor dem Fragen, und lassen sie bei einer Umleitung zurueck",
          .needsTheSources)
    func theThreeWaysSetThemAndLeaveThemBehind() throws {
        var setters: Set<String> = []
        var read = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            read += 1
            if text.contains("ServerHeaders.apply(") { setters.insert(file.lastPathComponent) }
        }
        #expect(read > 100, "the fence read no sources: \(read)")
        #expect(setters == UserAgentFenceTests.ways, "the ways that set the server headers: \(setters.sorted())")

        let http = try Self.code("Sources/Networking/HTTP.swift")
        let prepare = try #require(http.range(of: "static func prepare("))
        let applied = try #require(http.range(of: "ServerHeaders.apply(to: &out)"))
        #expect(prepare.upperBound < applied.lowerBound)
        #expect(http.components(separatedBy: "try ServerHeaders.admit(").count - 1 == 5,
                "webSocket, data, bytes, download and upload each hold a request whose headers cannot be read")
        #expect(http.components(separatedBy: "delegate: RedirectGuard.following()").count - 1 == 4,
                "data, bytes, download and upload each ask with the redirect rule")
        #expect(http.contains("task.delegate = RedirectGuard.following()"), "the socket asks with the redirect rule")

        let retry = try Self.code("Sources/Networking/Retry.swift")
        let set = try #require(retry.range(of: "ServerHeaders.apply(to: &request)"))
        let asked = try #require(retry.range(of: "session.data(for: request, delegate: redirects)"))
        #expect(set.lowerBound < asked.lowerBound)
        #expect(retry.contains("redirects ?? RedirectGuard.following()"))
        #expect(retry.contains("completionHandler(ServerHeaders.redirected("), "the guard passes the rule on")

        let downloader = try Self.code("Sources/Networking/FileDownloader.swift")
        let setHere = try #require(downloader.range(of: "ServerHeaders.apply(to: &identified)"))
        let task = try #require(downloader.range(of: "session.downloadTask(with: request)"))
        #expect(setHere.lowerBound < task.lowerBound)
        // The background session never asks its delegate at a redirect
        // (measured), so the downloader asks the end first, like the stream.
        let end = try #require(downloader.range(of: "identified = await ServerHeaders.end(of: identified, server: server)"))
        #expect(end.lowerBound < task.lowerBound)
        let table = try Self.code("Sources/Networking/ServerHeaders.swift")
        #expect(table.contains("let end = await self.end(of: ServerHeaderRule.applied(request, entries: entries), server: server)"),
                "the stream asks the end the same way")
    }

    @Test("Neubau nach einem Ladefehler: eine Stelle laesst den Plan der Spur gehen, und jeder Weg baut durch sie", .needsTheSources)
    func everyRebuildAfterALoadFailureAsksThePlanAnew() throws {
        let player = try Self.code("Sources/ViewModels/PlayerViewModel.swift")
        #expect(player.components(separatedBy: ".forget(").count - 1 == 1, "a plan is let go in another place")
        let place = try #require(functionBody(of: "private func rebuildAfterLoadFailure(", in: player))
        #expect(place.contains("planner.forget(url)"), "the one place does not let the plan go")
        for way in ["private func handleTrackFailure(", "private func stopAtHeldFailure(", "private func rebuildAtHeldPosition("] {
            let body = try #require(functionBody(of: way, in: player), "\(way) is gone")
            #expect(body.contains("rebuildAfterLoadFailure(from:"), "\(way) builds anew past the one place")
            #expect(!body.contains("buildQueue("), "\(way) builds the queue itself")
        }
        // The load, a jump and the one place.
        #expect(player.components(separatedBy: "buildQueue(startingAtTrackIndex:").count - 1 == 3,
                "the queue is built in another place")
    }

    @Test("Header: der Stream einer Spur fragt den Plan, kein Asset mit Kopfzeilen entsteht am Planer vorbei", .needsTheSources)
    func theStreamAsksThePlan() throws {
        let player = try Self.code("Sources/ViewModels/PlayerViewModel.swift")
        // A stream that needs a plan is built from its plan and not at all
        // without one; only a stream that needs none is plain.
        #expect(player.contains("let plan: ServerHeaders.Stream = needsPlan(url) ? (streamPlanner?.plans[url] ?? .waiting) : .plain"),
                "a stream that needs a plan is built without one")
        #expect(player.contains("case .plain:\n                target = (url, streamHeaders)"),
                "a plain stream is built from the address and the source's headers alone")
        #expect(player.components(separatedBy: "AVURLAsset(url: target.url").count - 1 == 1)
        // In all of the sources one place gives an asset headers: the one
        // behind the plan.
        var givers: [String: Int] = [:]
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let count = SyncContractFenceTests.stripped(text).components(separatedBy: "AVURLAssetHTTPHeaderFieldsKey").count - 1
            if count > 0 { givers[file] = count }
        }
        #expect(givers == ["PlayerViewModel.swift": 1], "an asset is given headers in another place than the one behind the plan: \(givers)")
        // A plan is needed for a server with headers and for a source that
        // attaches a sign-in to the address.
        #expect(player.contains("if ServerHeaders.needsPlan(url) { return true }\n        return provider.streamAuthHeaders(forItemId: self.item?.id ?? \"\", to: url)?.isEmpty == false"))
        // The start asks one track ahead and the rest after the queue is built.
        let load = try #require(player.range(of: "func load(item: LibraryItemDetail"))
        let gate = try #require(player.range(of: "let planner = StreamPlanner { url in", range: load.upperBound..<player.endIndex))
        // The plan asks the source's sign-in for the address it plans, waits
        // while it cannot be read, and plans a stream with a sign-in by the
        // end of its redirects.
        #expect(player.contains("await MainActor.run { provider.streamAuthHeaders(forItemId: itemId, to: address) }"))
        #expect(player.contains("guard let sourceHeaders = await signIn(url) else { return .waiting }"))
        #expect(player.contains("guard byServer == .plain, !sourceHeaders.isEmpty else { return byServer }\n            return await SignInStream.plan(for: url, sourceHeaders: sourceHeaders, signIn: signIn)"))
        let ahead = try #require(player.range(of: "await Self.awaitPlan(first, of: planner, for: \"the start\")", range: gate.upperBound..<player.endIndex))
        let built = try #require(player.range(of: "guard buildQueue(startingAtTrackIndex: startIndex", range: ahead.upperBound..<player.endIndex))
        // The tracks after the first are asked by a window, never all at once:
        // the queue asks it when it is built and when playback reaches the
        // next track, and no other place asks ahead.
        #expect(player.contains("currentTrackIndex = startIndex\n        planWindow(from: startIndex)"),
                "the built queue does not ask the tracks it needs soon")
        #expect(player.contains("self.currentTrackIndex = idx\n                    self.planWindow(from: idx)"),
                "playback reaching a track does not move the window")
        #expect(player.components(separatedBy: ".planAhead(").count - 1 == 1, "the tracks are asked ahead in another place")
        #expect(player.contains("let urls = StreamPlanner.window(from: index, count: tracks.count)"))
        // One track ahead, waited for at the one place.
        #expect(player[gate.lowerBound..<built.lowerBound].components(separatedBy: "await Self.awaitPlan(").count - 1 == 1,
                "the start asks more than the one track ahead")
        // Every plan a stream needs now (a start, a jump, a rebuild, a queue
        // that ran out) is waited for at one place, until the ask answers:
        // no deadline after which a stream with a sign-in is built at an
        // address whose end was not asked.
        let wait = try #require(functionBody(of: "private static func awaitPlan(", in: player))
        #expect(wait.contains("if await planner.plan(url) == .plain {"), "the one wait does not wait for the ask")
        #expect(player.components(separatedBy: "planner.plan(").count - 1 == 1, "a plan is waited for past the one place")
        #expect(!player.contains("within:"), "a wait for a plan has a deadline")
        for (way, need) in [("func load(item: LibraryItemDetail", "the start"), ("func seek(to time: Double", "a jump"),
                            ("private func rebuildAfterLoadFailure(", "a rebuild"), ("private func awaitPlanOfDryQueue(", "the next track")] {
            let body = try #require(functionBody(of: way, in: player), "\(way) is gone")
            #expect((body.contains("await Self.awaitPlan(") || body.contains("awaitPlanShowingTheWait(")) && body.contains("for: \"\(need)\")"),
                    "\(way) does not wait at the one place")
        }
        let shown = try #require(functionBody(of: "private func awaitPlanShowingTheWait(", in: player))
        #expect(shown.contains("await Self.awaitPlan(url, of: planner, for: need)"), "the visible wait waits past the one place")
        let planner = try Self.code("Sources/ViewModels/StreamPlanner.swift")
        #expect(!planner.contains("within"), "the planner has a deadline for a plan")
        #expect(player.contains("if let url = resolveTrackURL(index: index), awaitsPlan(url) {\n                queueAppendIndex = index\n                break"),
                "a queue stops at the first track without its plan")
    }

    @Test("Anmeldung der Quellen im Stream: jede Quelle setzt nur Authorization",
          .needsTheSources)
    func theSourcesSignInIsAuthorizationOnly() throws {
        var bodies = 0
        var names: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            var rest = Substring(text)
            while let start = rest.range(of: "var streamAuthHeaders: [String: String] {") {
                let after = rest[start.upperBound...]
                let end = after.range(of: "\n    }")?.lowerBound ?? after.endIndex
                let body = after[..<end]
                bodies += 1
                for match in body.matches(of: #/"([A-Za-z-]+)":/#) { names.insert(String(match.output.1)) }
                rest = after[end...]
            }
        }
        #expect(bodies >= 10, "the fence found the sources' stream headers: \(bodies)")
        #expect(names.isSubset(of: ["Authorization"]), "a source names a header of its own: \(names.sorted())")
        let feed = PodcastFeedAuth.headers(for: .present(user: "u", password: "p")) ?? [:]
        #expect(Array(feed.keys) == ["Authorization"], "a paid feed's stream names: \(feed.keys.sorted())")
    }
}
#endif
