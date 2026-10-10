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
@testable import Maer

/// A play after a load failure plays once the network is back, without a
/// restart of the app: the failed item is built anew at the position the
/// device holds, and the failure itself stops playback with a hint.
@MainActor
struct FailedLoadTests {

    @Test("die Regel: nur das laufende Item der aktuellen Warteschlange haelt an; ein Play oder das Netz baut neu")
    func theRule() {
        #expect(FailedLoad.stopsPlayback(failedIndex: 0, currentIndex: 0, inCurrentQueue: true))
        #expect(!FailedLoad.stopsPlayback(failedIndex: 2, currentIndex: 0, inCurrentQueue: true))
        #expect(!FailedLoad.stopsPlayback(failedIndex: 0, currentIndex: 0, inCurrentQueue: false))
        #expect(FailedLoad.rebuildsBeforePlay(currentItemFailed: true, noted: false))
        #expect(FailedLoad.rebuildsBeforePlay(currentItemFailed: false, noted: true))
        #expect(!FailedLoad.rebuildsBeforePlay(currentItemFailed: false, noted: false))
        #expect(FailedLoad.rebuildsOnPathChange(noted: true, satisfied: true))
        #expect(!FailedLoad.rebuildsOnPathChange(noted: true, satisfied: false))
        #expect(!FailedLoad.rebuildsOnPathChange(noted: false, satisfied: true))
        #expect(FailedLoad.holdsAhead(failedIndex: 2, currentIndex: 0, inCurrentQueue: true, heldAt: nil))
        #expect(FailedLoad.holdsAhead(failedIndex: 1, currentIndex: 0, inCurrentQueue: true, heldAt: 2))
        #expect(!FailedLoad.holdsAhead(failedIndex: 3, currentIndex: 0, inCurrentQueue: true, heldAt: 2))
        #expect(!FailedLoad.holdsAhead(failedIndex: 0, currentIndex: 0, inCurrentQueue: true, heldAt: nil))
        #expect(!FailedLoad.holdsAhead(failedIndex: 2, currentIndex: 0, inCurrentQueue: false, heldAt: nil))
        #expect(FailedLoad.localFallback(fromLocalFile: true, retried: false, online: true) == .stream)
        #expect(FailedLoad.localFallback(fromLocalFile: true, retried: false, online: false) == .unavailable)
        #expect(FailedLoad.localFallback(fromLocalFile: true, retried: true, online: true) == .unavailable)
        #expect(FailedLoad.localFallback(fromLocalFile: false, retried: true, online: true) == .none,
                "a streamed track keeps the network rules after its attempt")
        #expect(FailedLoad.localFallback(fromLocalFile: false, retried: false, online: true) == .none)
        #expect(FailedLoad.localFallback(fromLocalFile: false, retried: false, online: false) == .none)
        #expect(FailedLoad.endHasPassed(position: 1.0026, duration: 1), "waiting at the end of the track before")
        #expect(!FailedLoad.endHasPassed(position: 0.3, duration: 1), "the track before still plays")
        #expect(FailedLoad.endHasPassed(position: nil, duration: nil), "no item left")
        #expect(!FailedLoad.endHasPassed(position: 0.3, duration: .nan), "a duration not known yet is no end")
    }

    /// A source whose every track lives at a loopback port nothing listens
    /// on: the item fails to load at once, as a stream does without network.
    final class DeadAddressProvider: AudioProvider {
        var providerId: String { "dead-address" }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            throw NSError(domain: "dead-address", code: 404)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? {
            URL(string: "http://127.0.0.1:1/\(contentPath)")
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 15) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test("ein Play nach einem Ladefehler baut das Item an der gehaltenen Position neu, der Fehler haelt an mit Hinweis")
    func aPlayAfterALoadFailureBuildsTheItemAnew() async throws {
        let id = "loadfail-\(UUID().uuidString)"
        let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 600, contentUrl: "episode.mp3", metadata: nil)
        let detail = LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(metadata: nil, duration: 600, chapters: nil, tracks: [track]),
            userMediaProgress: MediaProgress(currentTime: 120, duration: 600, progress: 0.2,
                                             isFinished: false, lastUpdate: nil))
        let model = PlayerViewModel(provider: DeadAddressProvider())
        await model.load(item: detail)
        let held = model.currentTime
        #expect(held == 120, "the start is the held position: \(held)")
        // Taken before it fails: the queue drops a failed item, so its
        // status alone cannot say a rebuild is due, the noted mark does.
        let failed = try #require(model.player?.currentItem, "a queue was built")
        model.play()

        await waitFor { model.sourceHint == .loadFailed }
        #expect(failed.status == .failed, "the precondition: the item failed to load")
        #expect(model.sourceHint == .loadFailed, "the failure says so")
        #expect(!model.isPlaying, "the failure stops playback instead of a silent stall")

        model.play()
        let rebuilt = try #require(model.player?.currentItem, "the play left a queue")
        #expect(rebuilt !== failed, "the play built the item anew")
        #expect(model.currentTime == held, "the rebuild keeps the held position: \(model.currentTime)")
        model.player?.pause()
    }

    /// Tracks with an absolute path play from that file, a track that names
    /// an address uses it, every other track sits at the dead loopback port.
    final class MixedProvider: AudioProvider {
        var providerId: String { "mixed-address" }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            throw NSError(domain: "mixed-address", code: 404)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? {
            if contentPath.hasPrefix("/") { return URL(fileURLWithPath: contentPath) }
            if contentPath.hasPrefix("http") { return URL(string: contentPath) }
            return URL(string: "http://127.0.0.1:1/\(contentPath)")
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    /// A host that takes the connection and answers 500 only after a while,
    /// so the track fails late: after the track before it has ended.
    /// Unchecked because the listener and its connections are only touched
    /// on the listener's own queue after start.
    nonisolated final class SlowFailHost: @unchecked Sendable {
        private let listener: NWListener
        private let delay: Double
        private(set) var port: UInt16 = 0

        private init(delay: Double) throws {
            self.delay = delay
            listener = try NWListener(using: .tcp, on: .any)
        }

        static func start(delay: Double) async throws -> SlowFailHost {
            let host = try SlowFailHost(delay: delay)
            host.listener.newConnectionHandler = { [host] connection in host.serve(connection) }
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                host.listener.stateUpdateHandler = { [host] state in
                    let first = once.withLock { done in
                        let was = done
                        if case .ready = state { done = true } else if case .failed = state { done = true }
                        return !was && done
                    }
                    if first, case .ready = state { continuation.resume(returning: host.listener.port?.rawValue ?? 0) }
                    if first, case .failed(let error) = state { continuation.resume(throwing: error) }
                }
                host.listener.start(queue: .global())
            }
            host.port = port
            return host
        }

        func stop() { listener.cancel() }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [delay] _, _, _, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    let answer = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(answer.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    private func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loadfail-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) { data[i] = 0.1 * sinf(Float(i) * 0.05) }
        }
        try file.write(from: buffer)
        return url
    }

    /// The witnesses that play a generated tone stand on a simulator that
    /// plays audio at all. Measured on a gate simulator whose CoreAudio had
    /// no system object: every item failed (-11800 under -12746), a tone
    /// from AVAudioFile and a WAV written byte by byte alike, while the asset
    /// said it was playable. There the witness says so instead of failing on
    /// the rule.
    private func requireAudioHere(_ url: URL) async throws {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(5)
        while item.status == .unknown, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let error = item.error.map { error -> String in
            let outer = error as NSError
            let inner = outer.userInfo[NSUnderlyingErrorKey] as? NSError
            return "\(outer.code) under \(inner?.code ?? 0)"
        } ?? "none"
        try #require(item.status == .readyToPlay,
                     "this simulator plays no local audio file (status \(item.status.rawValue), error \(error)); the witness cannot measure the rule here")
        player.replaceCurrentItem(with: nil)
    }

    @Test("eine spaetere Datei, die nicht laden kann, haelt an ihrem Anfang an, die Position springt nicht ueber sie")
    func aLaterFailedTrackHoldsAtItsStart() async throws {
        let first = try tone(seconds: 1)
        let third = try tone(seconds: 1)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: third)
        }
        try await requireAudioHere(first)
        let tracks = [
            ABSAudioTrack(index: 0, startOffset: 0, duration: 1, contentUrl: first.path, metadata: nil),
            ABSAudioTrack(index: 1, startOffset: 1, duration: 1, contentUrl: "second.mp3", metadata: nil),
            ABSAudioTrack(index: 2, startOffset: 2, duration: 1, contentUrl: third.path, metadata: nil),
        ]
        let detail = LibraryItemDetail(
            id: "loadfail-later-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 3, chapters: nil, tracks: tracks),
            userMediaProgress: MediaProgress(currentTime: 0, duration: 3, progress: 0, isFinished: false, lastUpdate: nil))
        let model = PlayerViewModel(provider: MixedProvider())
        await model.load(item: detail)
        let queued = model.player?.items().count ?? 0
        #expect(queued == 3, "the precondition: all three files are queued")
        model.play()

        var furthest = 0.0
        await waitFor {
            furthest = max(furthest, model.currentTime)
            return model.sourceHint == .loadFailed
        }
        #expect(model.sourceHint == .loadFailed, "the later failure says so")
        #expect(!model.isPlaying, "playback stops at the failed file")
        #expect(abs(model.currentTime - 1) < 0.01, "the position is the start of the failed file: \(model.currentTime)")
        #expect(furthest < 2, "the position never reached the file behind it: \(furthest)")
        let left = model.player?.items().count ?? 0
        #expect(left == 0, "nothing behind the failed file is left to play: \(left)")

        model.play()
        let rebuilt = model.player?.items().count ?? 0
        #expect(rebuilt == 2, "the play builds the queue anew from the failed file: \(rebuilt)")
        #expect(abs(model.currentTime - 1) < 0.01, "the rebuild keeps the held position: \(model.currentTime)")
        model.player?.pause()
    }

    /// Bytes no decoder reads, under an audio name.
    private func brokenFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loadfail-\(UUID().uuidString).mp3")
        try Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        return url
    }

    private func detail(_ tracks: [(path: String, seconds: Double)]) -> LibraryItemDetail {
        var start = 0.0
        var built: [ABSAudioTrack] = []
        for (index, track) in tracks.enumerated() {
            built.append(ABSAudioTrack(index: index, startOffset: start, duration: track.seconds,
                                       contentUrl: track.path, metadata: nil))
            start += track.seconds
        }
        return LibraryItemDetail(
            id: "loadfail-local-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: start, chapters: nil, tracks: built),
            userMediaProgress: MediaProgress(currentTime: 0, duration: start, progress: 0, isFinished: false, lastUpdate: nil))
    }

    /// A downloaded file that is missing or broken fails to load and never
    /// fires FailedToPlayToEndTime. With network the track plays on from the
    /// server, the file goes and the hint says the download could not be
    /// read; without network it stops with that hint, not a network one, and
    /// the file stays.
    @Test("eine fehlende oder kaputte lokale Datei: mit Netz weiter vom Server, ohne Netz Halt, beide Male der Hinweis auf den Download")
    func aBrokenLocalFilePlaysOnFromTheServer() async throws {
        let server = try tone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: server) }
        try await requireAudioHere(server)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("loadfail-missing-\(UUID().uuidString).caf")
        for local in [missing, try brokenFile()] {
            let online = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [0: local] }, isOnline: { true })
            await online.load(item: detail([(server.path, 3)]))
            online.play()
            var seen: PlayerViewModel.SourceHint?
            await waitFor {
                seen = seen ?? online.sourceHint
                return online.currentTime > 0.5 || online.sourceHint == .loadFailed
            }
            #expect(seen == .downloadUnreadable, "\(local.pathExtension): the hint names the download: \(String(describing: seen))")
            #expect(online.isPlaying && online.currentTime > 0.5, "\(local.pathExtension): playback goes on: \(online.currentTime)")
            #expect(!FileManager.default.fileExists(atPath: local.path), "\(local.pathExtension): the failed file is dropped")
            online.stop()
        }
        let broken = try brokenFile()
        defer { try? FileManager.default.removeItem(at: broken) }
        let offline = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [0: broken] }, isOnline: { false })
        await offline.load(item: detail([(server.path, 3)]))
        offline.play()
        await waitFor { offline.sourceHint != nil }
        #expect(offline.sourceHint == .downloadUnreadableOffline,
                "offline the hint names the download, not the network: \(String(describing: offline.sourceHint))")
        #expect(!offline.isPlaying, "offline playback stops")
        #expect(FileManager.default.fileExists(atPath: broken.path), "offline the file stays")
        offline.stop()
    }

    /// A later track that fails only after the track before has ended: the
    /// queue has moved past it by then, and its failure comes too late to
    /// hold ahead. The gap in the playing index holds it all the same.
    @Test("eine spaetere Datei, die erst nach dem Ende der Datei davor scheitert, haelt an ihrem Anfang, nie in der Datei dahinter")
    func aLateFailureHoldsAtItsStart() async throws {
        let first = try tone(seconds: 1)
        let third = try tone(seconds: 3)
        defer {
            for url in [first, third] { try? FileManager.default.removeItem(at: url) }
        }
        try await requireAudioHere(first)
        let host = try await SlowFailHost.start(delay: 2)
        defer { host.stop() }
        let model = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: detail([(first.path, 1), ("http://127.0.0.1:\(host.port)/slow.mp3", 1), (third.path, 3)]))
        let started = Date()
        model.play()
        var furthest = 0.0
        await waitFor({
            furthest = max(furthest, model.currentTime)
            return model.sourceHint == .loadFailed
        }, seconds: 20)
        #expect(Date().timeIntervalSince(started) > 1.5,
                "the precondition: the failure came after the track before had ended")
        #expect(model.sourceHint == .loadFailed, "the late failure says so: \(String(describing: model.sourceHint))")
        #expect(!model.isPlaying, "playback stops at the failed track")
        #expect(abs(model.currentTime - 1) < 0.01, "the position is the start of the failed track: \(model.currentTime)")
        #expect(furthest < 2, "the position never reached the track behind it: \(furthest)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(abs(model.currentTime - 1) < 0.01, "the held position stays: \(model.currentTime)")
        model.stop()
    }

    /// A later downloaded file that cannot load is dropped while the one
    /// before plays; at its start playback goes on from the server, no stop.
    @Test("eine spaetere kaputte lokale Datei: mit Netz laeuft die Wiedergabe an ihrem Anfang vom Server weiter")
    func aLaterBrokenLocalFilePlaysOnFromTheServer() async throws {
        let first = try tone(seconds: 1)
        let server = try tone(seconds: 2)
        let broken = try brokenFile()
        defer {
            for url in [first, server, broken] { try? FileManager.default.removeItem(at: url) }
        }
        try await requireAudioHere(first)
        let model = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [1: broken] }, isOnline: { true })
        await model.load(item: detail([(first.path, 1), (server.path, 2)]))
        model.play()
        var seen: PlayerViewModel.SourceHint?
        await waitFor {
            seen = seen ?? model.sourceHint
            return model.currentTime > 1.5 || model.sourceHint == .loadFailed
        }
        #expect(seen == .downloadUnreadable, "the hint names the download: \(String(describing: seen))")
        #expect(model.isPlaying && model.currentTime > 1.5, "playback went on past its start: \(model.currentTime)")
        #expect(!FileManager.default.fileExists(atPath: broken.path), "the failed file is dropped")
        model.stop()
    }

    /// One attempt per track: the server copy fails too. The track streams
    /// by then, so the network hint stands, and nothing builds it again by
    /// itself.
    @Test("eine lokale Datei und ihr Server scheitern: nach dem einen Versuch der Netz-Hinweis, keine Schleife")
    func oneAttemptThenTheNetworkHint() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("loadfail-missing-\(UUID().uuidString).caf")
        let model = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [0: missing] }, isOnline: { true })
        await model.load(item: detail([("dead.mp3", 3)]))
        model.play()
        await waitFor { model.sourceHint == .loadFailed }
        #expect(model.sourceHint == .loadFailed, "after the one try the stream failure says so: \(String(describing: model.sourceHint))")
        #expect(!model.isPlaying, "playback stops")
        let queue = model.player.map(ObjectIdentifier.init)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(model.player.map(ObjectIdentifier.init) == queue, "nothing builds the track again by itself")
        model.stop()
    }
}
#endif
