// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Network
import os
import OSLog
@testable import Maer

/// A host that stops answering ends its downloads instead of holding them
/// for days, while a host that answers slowly keeps all of its downloads,
/// also the ones the session queues behind its six connections.
@MainActor
@Suite(.serialized)
struct DownloadSilenceTests {
    // MARK: - The rule

    @Test("die Regel: still fuer die Grenze, waehrend die App zusah und Netz da war")
    func theRule() {
        let start = Date(timeIntervalSince1970: 1_000)
        var silence = DownloadSilence(limit: 120, maxGap: 45)
        silence.began("a", at: start)
        #expect(silence.tick(at: start + 15, online: true).isEmpty, "the first look only arms the watch")
        var at = start + 15
        while at < start + 135 { at += 15; _ = silence.tick(at: at, online: true) }
        #expect(silence.tick(at: start + 150, online: true) == ["a"], "silent for two minutes while watched")

        // A byte keeps the host alive.
        var heard = DownloadSilence(limit: 120, maxGap: 45)
        heard.began("a", at: start)
        for step in 1...12 {
            if step == 6 { heard.heard("a", at: start + 90) }
            #expect(heard.tick(at: start + Double(step) * 15, online: true).isEmpty, "a byte at 90 s, silent at \(step * 15) s")
        }

        // Offline the clock starts again.
        var offline = DownloadSilence(limit: 120, maxGap: 45)
        offline.began("a", at: start)
        for step in 1...8 { _ = offline.tick(at: start + Double(step) * 15, online: true) }
        _ = offline.tick(at: start + 135, online: false)
        #expect(offline.tick(at: start + 150, online: true).isEmpty, "the network came back 15 s ago")

        // The app was suspended: the session may have loaded meanwhile.
        var suspended = DownloadSilence(limit: 120, maxGap: 45)
        suspended.began("a", at: start)
        _ = suspended.tick(at: start + 15, online: true)
        #expect(suspended.tick(at: start + 615, online: true).isEmpty, "last byte 10 min ago, the app active again for one look")
        #expect(suspended.tick(at: start + 620, online: true).isEmpty, "the app active for 5 s")

        // A watched host keeps its clock when another download to it starts.
        var second = DownloadSilence(limit: 120, maxGap: 45)
        second.began("a", at: start)
        _ = second.tick(at: start + 15, online: true)
        second.began("a", at: start + 100)
        for step in 2...9 { _ = second.tick(at: start + Double(step) * 15, online: true) }
        #expect(second.tick(at: start + 150, online: true) == ["a"])

        // Counted per download: one of two ends, the clock stays; the
        // second ends, it goes; a byte afterwards lays no clock.
        second.ended("a")
        #expect(second.since["a"] != nil && second.watchesAny, "one of two downloads ended and the clock went")
        second.ended("a")
        #expect(second.since["a"] == nil && !second.watchesAny, "the last download ended and the clock stayed")
        second.heard("a", at: start + 160)
        #expect(second.since["a"] == nil, "a byte of a host without a download laid a clock")
        #expect(second.tick(at: start + 165, online: true).isEmpty, "no download, no clock")
    }

    // MARK: - At a host

    /// A host that answers every request the way `reply` decides.
    /// Unchecked because the listener and its connections are only touched
    /// on their queue after start.
    nonisolated final class Host: @unchecked Sendable {
        enum Reply: Sendable {
            case close
            case silent
            /// After `wait` seconds the head, then `chunks` pieces of the
            /// body `every` seconds, then close.
            case dribble(head: String, body: Data, chunks: Int, every: Double, wait: Double)
            /// The head and the first bytes, then nothing, the connection held.
            case startThenSilent(head: String, body: Data)
            /// The head and the body, then close.
            case whole(head: String, body: Data)
        }
        private let listener: NWListener
        private let reply: @Sendable (String) -> Reply
        let ranges = OSAllocatedUnfairLock<[String]>(initialState: [])
        /// When each request arrived, seconds after start.
        let arrivals = OSAllocatedUnfairLock<[Double]>(initialState: [])
        private let started = Date()
        private(set) var port: UInt16 = 0
        init(reply: @escaping @Sendable (String) -> Reply) throws {
            self.reply = reply
            listener = try NWListener(using: .tcp, on: .any)
        }
        func start() async throws {
            listener.newConnectionHandler = { [reply, ranges, arrivals, started] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let head = String(decoding: data ?? Data(), as: UTF8.self)
                    let range = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }
                    ranges.withLock { $0.append(range.map(String.init) ?? "-") }
                    arrivals.withLock { $0.append(Date().timeIntervalSince(started)) }
                    switch reply(head) {
                    case .close:
                        connection.cancel()
                    case .silent:
                        break
                    case .whole(let head, let body):
                        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
                        })
                    case .startThenSilent(let head, let body):
                        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in })
                    case .dribble(let head, let body, let chunks, let every, let wait):
                        DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                        }
                        let size = body.count / chunks
                        for index in 0..<chunks {
                            DispatchQueue.global().asyncAfter(deadline: .now() + wait + every * Double(index + 1)) {
                                let piece = body.subdata(in: (index * size)..<(index == chunks - 1 ? body.count : (index + 1) * size))
                                connection.send(content: piece, completion: .contentProcessed { _ in
                                    if index == chunks - 1 {
                                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
                                    }
                                })
                            }
                        }
                    }
                }
            }
            port = try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { [listener] state in
                    if case .ready = state, once.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                }
                listener.start(queue: .global())
            }
        }
        func stop() { listener.cancel() }
        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
    }

    /// A short limit for the witness, and the app's limit back after it.
    private static func shortSilence() { FileDownloader.shared.testSetSilence(limit: 2, tick: 0.25) }
    private static func appSilence() { FileDownloader.shared.testSetSilence(limit: 120, tick: 15) }

    private static func download(_ url: URL) async -> Error? {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await FileDownloader.shared.download(request: URLRequest(url: url), to: destination, onProgress: { _ in })
            return nil
        } catch {
            return error
        }
    }

    @Test("ein Wirt, der schliesst oder schweigt, beendet seine Downloads nach der Grenze mit einer Zeile")
    func aDeadHostEndsItsDownloads() async throws {
        Self.shortSilence()
        defer { Self.appSilence() }
        for (name, reply) in [("schliesst", Host.Reply.close), ("schweigt", .silent)] {
            let host = try Host { _ in reply }
            try await host.start()
            defer { host.stop() }
            let since = Date()
            let error = await Self.download(host.url("\(name).mp3"))
            let waited = Date().timeIntervalSince(since)
            #expect(error is SilentHostError, "\(name): ends as a silent host: \(String(describing: error))")
            #expect(waited >= 2 && waited < 15, "\(name): ended after \(waited) s")
            let logStore = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try logStore.getEntries(at: logStore.position(date: since)).compactMap { $0 as? OSLogEntryLog }
            let lines: [String] = entries.filter { $0.subsystem == AppLogSubsystem.value && $0.category == "library" }
                .map(\.composedMessage).filter { $0.hasPrefix("DOWNLOAD silent") }
            #expect(lines.contains { $0.contains("host=127.0.0.1") && $0.contains("seconds=2") }, "\(name): the line: \(lines)")
        }
    }

    /// The watch may end a host between a download's entry and its count;
    /// the seam ends it right there. The download ends, and the watch
    /// counts nothing after it: a count without a download kept it looking.
    @Test("die Wacht beendet einen Download gleich nach seinem Eintrag: danach zaehlt sie keinen Download")
    func aDownloadEndedRightAfterItsEntryIsNotCounted() async throws {
        let host = try Host { _ in .silent }
        try await host.start()
        defer { host.stop() }
        Self.shortSilence()
        defer { Self.appSilence() }
        #expect(!FileDownloader.shared.testWatchesAny, "the precondition: no download counted")
        FileDownloader.shared.testEndAfterEntry(true)
        let error = await Self.download(host.url("eintrag.mp3"))
        FileDownloader.shared.testEndAfterEntry(false)
        #expect(error is SilentHostError, "the download did not end at its entry: \(String(describing: error))")
        #expect(!FileDownloader.shared.testWatchesAny, "the watch counts a download that does not run")
    }

    @Test("acht Downloads an einen langsamen, antwortenden Wirt: keiner bricht ab, auch die wartenden nicht")
    func eightDownloadsAtASlowHostAllFinish() async throws {
        let body = Data(repeating: 0x41, count: 6_000)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 6000\r\nConnection: close\r\n\r\n"
        // On the loopback the session asks all eight at once (measured,
        // sixteen within 0.1 s), so the host itself holds four of them
        // without a byte for longer than the limit, as a queue behind the
        // others looks from the app: the task shows nothing either way.
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let host = try Host { _ in
            let order = asked.withLock { $0 += 1; return $0 }
            return .dribble(head: head, body: body, chunks: 12, every: 0.4, wait: order > 4 ? 4 : 0)
        }
        try await host.start()
        defer { host.stop() }
        Self.shortSilence()
        defer { Self.appSilence() }
        let downloads = (0..<8).map { index in
            let url = host.url("\(index).mp3")
            return Task { await Self.download(url) }
        }
        var errors: [Error?] = []
        for download in downloads { errors.append(await download.value) }
        #expect(errors.count == 8)
        #expect(errors.allSatisfy { $0 == nil }, "a download of a living host ended: \(errors.compactMap { $0 })")
        #expect(host.ranges.withLock { $0.count } == 8, "the precondition: every download asked the host once")
        #expect(asked.withLock { $0 } == 8, "the precondition: eight asked, the host held the last four 4 s without a byte")
    }

    @Test("ueber den Download-Weg: ein Wirt verstummt mitten in der Spur, der naechste Versuch fragt Range und die Spur ist ganz")
    func theNextAttemptContinuesWhereTheBytesStopped() async throws {
        let body = TrackFileSizeTests.audioBytes(100_000)
        let host = try Host { head in
            if head.lowercased().contains("range: bytes=") {
                return .whole(head: "HTTP/1.1 206 Partial Content\r\nContent-Type: audio/mpeg\r\nContent-Length: 50000\r\nContent-Range: bytes 50000-99999/100000\r\nETag: \"silence\"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                              body: body.subdata(in: 50_000..<100_000))
            }
            return .startThenSilent(head: "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 100000\r\nETag: \"silence\"\r\nAccept-Ranges: bytes\r\nLast-Modified: Wed, 28 Oct 2026 10:00:00 GMT\r\n\r\n",
                                    body: body.subdata(in: 0..<50_000))
        }
        try await host.start()
        defer { host.stop() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let itemId = "silence-\(UUID().uuidString)"
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        await manager.ensureScanned()
        let book = TrackFileSizeTests.book(itemId, path: host.url("track.mp3").absoluteString, size: 100_000)
        let provider = TrackFileSizeTests.SizedProvider(original: true)

        Self.shortSilence()
        defer { Self.appSilence() }
        await manager.download(item: book, provider: provider, kind: nil)
        let failed = if case .failed = manager.phase[itemId] { true } else { false }
        try #require(failed, "the silent host did not end as a failed download: \(String(describing: manager.phase[itemId]))")
        await manager.download(item: book, provider: provider, kind: nil)
        #expect(host.ranges.withLock { $0 }.last == "Range: bytes=50000-", "the next attempt began again: \(host.ranges.withLock { $0 })")
        let stored = try #require(manager.localTrackMap(forItemId: itemId)[0], "the track lies there")
        #expect(TrackFileSize.bytes(at: stored) == 100_000, "the stated size holds for the joined track")
    }
}
#endif
