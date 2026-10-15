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

/// Whether this simulator plays a local audio file at all, measured once per
/// run. Measured on a gate simulator whose CoreAudio had no system object:
/// every item failed (-11800 under -12746), a tone from AVAudioFile and a WAV
/// written byte by byte alike, while the asset said it was playable. A
/// witness that plays a tone cannot ask its question there and is skipped
/// with that reason, not failed.
actor AudioHereProbe {
    static let shared = AudioHereProbe()
    private var answer: Bool?

    func plays() async -> Bool {
        if let answer { return answer }
        let measured = await Self.measure()
        answer = measured
        return measured
    }

    @MainActor private static func measure() async -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-here-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 22_050
        var samples = Data(capacity: rate * 2)
        for index in 0..<rate {
            let value = Int16(3000 * sin(Double(index) * 0.05))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var file = Data()
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
        func half(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
        file.append(contentsOf: Array("RIFF".utf8)); word(UInt32(36 + samples.count)); file.append(contentsOf: Array("WAVE".utf8))
        file.append(contentsOf: Array("fmt ".utf8)); word(16); half(1); half(1); word(UInt32(rate)); word(UInt32(rate * 2)); half(2); half(16)
        file.append(contentsOf: Array("data".utf8)); word(UInt32(samples.count)); file.append(samples)
        guard (try? file.write(to: url)) != nil else { return false }
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        let deadline = Date().addingTimeInterval(5)
        while item.status == .unknown, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        player.replaceCurrentItem(with: nil)
        return item.status == .readyToPlay
    }
}

extension Trait where Self == ConditionTrait {
    /// The witness plays a generated tone; skipped where the simulator plays
    /// no local audio file at all.
    static var needsAudio: Self {
        .enabled("this simulator plays no local audio file, the witness cannot ask its question here") {
            await AudioHereProbe.shared.plays()
        }
    }
}

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
        #expect(FailedLoad.atFiring(.stream, online: true) == .stream)
        #expect(FailedLoad.atFiring(.stream, online: false) == .unavailable, "the network went before the held point")
        #expect(FailedLoad.atFiring(.unavailable, online: true) == .unavailable)
        #expect(FailedLoad.atFiring(.none, online: false) == .none)
    }

    /// A source whose every track lives at a loopback port nothing listens
    /// on: the item fails to load at once, as a stream does without network.
    final class DeadAddressProvider: AudioProvider {
        var providerId: String { "dead-address" }
        var keepsMarksOnDevice: Bool { true }
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

        await waitFor { model.sourceHint?.kind == .loadFailed }
        #expect(failed.status == .failed, "the precondition: the item failed to load")
        #expect(model.sourceHint?.kind == .loadFailed, "the failure says so")
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
        var keepsMarksOnDevice: Bool { true }
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

    @Test("eine spaetere Datei, die nicht laden kann, haelt an ihrem Anfang an, die Position springt nicht ueber sie", .needsAudio)
    func aLaterFailedTrackHoldsAtItsStart() async throws {
        let first = try tone(seconds: 1)
        let third = try tone(seconds: 1)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: third)
        }
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
            return model.sourceHint?.kind == .loadFailed
        }
        #expect(model.sourceHint?.kind == .loadFailed, "the later failure says so")
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

    /// The other way the same failure is seen: the failed file is already
    /// the playing item, because the book starts at it. Which way a failure
    /// takes in the case above is up to the clock; here it is forced, and
    /// it must leave the same state: nothing behind the failed file waits.
    @Test("die gescheiterte Datei ist schon die laufende: Halt an ihrem Anfang, nichts dahinter bleibt in der Warteschlange", .needsAudio)
    func aFailedPlayingTrackLeavesNothingBehind() async throws {
        let first = try tone(seconds: 1)
        let third = try tone(seconds: 1)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: third)
        }
        let tracks = [
            ABSAudioTrack(index: 0, startOffset: 0, duration: 1, contentUrl: first.path, metadata: nil),
            ABSAudioTrack(index: 1, startOffset: 1, duration: 1, contentUrl: "second.mp3", metadata: nil),
            ABSAudioTrack(index: 2, startOffset: 2, duration: 1, contentUrl: third.path, metadata: nil),
        ]
        let detail = LibraryItemDetail(
            id: "loadfail-playing-\(UUID().uuidString)",
            media: LibraryItemMedia(metadata: nil, duration: 3, chapters: nil, tracks: tracks),
            userMediaProgress: MediaProgress(currentTime: 1, duration: 3, progress: 1.0 / 3, isFinished: false, lastUpdate: nil))
        let model = PlayerViewModel(provider: MixedProvider())
        await model.load(item: detail)
        let queued = model.player?.items().count ?? 0
        #expect(queued == 2, "the precondition: the queue starts at the failed file, the third behind it")
        model.play()

        await waitFor { model.sourceHint?.kind == .loadFailed }
        #expect(model.sourceHint?.kind == .loadFailed, "the failure says so")
        #expect(!model.isPlaying, "playback stops at the failed file")
        #expect(abs(model.currentTime - 1) < 0.01, "the position is the start of the failed file: \(model.currentTime)")
        let left = model.player?.items().count ?? 0
        #expect(left == 0, "nothing behind the failed file is left to play: \(left)")

        model.play()
        let rebuilt = model.player?.items().count ?? 0
        #expect(rebuilt == 2, "the play builds the queue anew from the failed file: \(rebuilt)")
        model.player?.pause()
    }

    /// The third way: a track fails in the middle of playing it
    /// (`AVPlayerItemFailedToPlayToEndTime`), is built anew once, and fails
    /// again. The simulator does not make a file fail in the middle (a cut
    /// download fails at load there, measured), so the case sends the note
    /// the player hears, for the item that plays. The hold it leaves is the
    /// one of the other two ways: the position stays, nothing from the failed
    /// track on waits in the queue, and the next play builds anew at the held
    /// position instead of resuming the item that failed.
    @Test("eine Datei scheitert mitten im Hoeren, nach ihrem einen Versuch erneut: Halt an der Stelle, nichts bleibt in der Warteschlange, das naechste Play baut dort neu", .needsAudio)
    func aTrackFailingMidwayTwiceHoldsLikeTheOthers() async throws {
        let first = try tone(seconds: 3)
        let second = try tone(seconds: 2)
        defer { for url in [first, second] { try? FileManager.default.removeItem(at: url) } }
        let model = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: detail([(first.path, 3), (second.path, 2)]))
        model.play()
        await waitFor({ model.currentTime >= 1 }, seconds: 5)
        let failing = try #require(model.player?.currentItem, "the precondition: the first track plays")

        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: failing)
        await waitFor({ model.player?.currentItem !== failing }, seconds: 3)
        let retried = try #require(model.player?.currentItem, "the one retry built a queue")
        #expect(retried !== failing, "the first failure builds the track anew once")
        #expect(model.isPlaying && model.sourceHint == nil, "the retry plays on without a hint")

        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: retried)
        await waitFor { model.sourceHint?.kind == .trackFailed }
        let held = model.currentTime
        #expect(model.sourceHint?.kind == .trackFailed, "the second failure says so")
        #expect(!model.isPlaying, "the second failure stops playback")
        #expect(held >= 1 && held < 3, "the position stays in the failed track: \(held)")
        let left = model.player?.items().count ?? 0
        #expect(left == 0, "nothing from the failed track on is left to play: \(left)")

        model.play()
        let rebuilt = try #require(model.player?.currentItem, "the play left a queue")
        #expect(rebuilt !== retried, "the play builds the track anew instead of resuming the failed item")
        #expect(model.player?.items().count == 2, "the rebuilt queue holds the failed track and the one behind it")
        #expect(abs(model.currentTime - held) < 0.01, "the rebuild keeps the held position: \(model.currentTime) for \(held)")
        model.stop()
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
    @Test("eine fehlende oder kaputte lokale Datei: mit Netz weiter vom Server, ohne Netz Halt, beide Male der Hinweis auf den Download", .needsAudio)
    func aBrokenLocalFilePlaysOnFromTheServer() async throws {
        let server = try tone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: server) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("loadfail-missing-\(UUID().uuidString).caf")
        for local in [missing, try brokenFile()] {
            let online = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [0: local] }, isOnline: { true })
            await online.load(item: detail([(server.path, 3)]))
            online.play()
            var seen: PlayerViewModel.SourceHint?
            await waitFor {
                seen = seen ?? online.sourceHint
                return online.currentTime > 0.5 || online.sourceHint?.kind == .loadFailed
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
    @Test("eine spaetere Datei, die erst nach dem Ende der Datei davor scheitert, haelt an ihrem Anfang, nie in der Datei dahinter", .needsAudio)
    func aLateFailureHoldsAtItsStart() async throws {
        let first = try tone(seconds: 1)
        let third = try tone(seconds: 3)
        defer {
            for url in [first, third] { try? FileManager.default.removeItem(at: url) }
        }
        let host = try await SlowFailHost.start(delay: 2)
        defer { host.stop() }
        let model = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: detail([(first.path, 1), ("http://127.0.0.1:\(host.port)/slow.mp3", 1), (third.path, 3)]))
        let started = Date()
        model.play()
        var furthest = 0.0
        await waitFor({
            furthest = max(furthest, model.currentTime)
            return model.sourceHint?.kind == .loadFailed
        }, seconds: 20)
        #expect(Date().timeIntervalSince(started) > 1.5,
                "the precondition: the failure came after the track before had ended")
        #expect(model.sourceHint?.kind == .loadFailed, "the late failure says so: \(String(describing: model.sourceHint))")
        #expect(!model.isPlaying, "playback stops at the failed track")
        #expect(abs(model.currentTime - 1) < 0.01, "the position is the start of the failed track: \(model.currentTime)")
        #expect(furthest < 2, "the position never reached the track behind it: \(furthest)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(abs(model.currentTime - 1) < 0.01, "the held position stays: \(model.currentTime)")
        model.stop()
    }

    /// A later downloaded file that cannot load is dropped while the one
    /// before plays; at its start playback goes on from the server, no stop.
    @Test("eine spaetere kaputte lokale Datei: mit Netz laeuft die Wiedergabe an ihrem Anfang vom Server weiter", .needsAudio)
    func aLaterBrokenLocalFilePlaysOnFromTheServer() async throws {
        let first = try tone(seconds: 1)
        let server = try tone(seconds: 2)
        let broken = try brokenFile()
        defer {
            for url in [first, server, broken] { try? FileManager.default.removeItem(at: url) }
        }
        let model = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [1: broken] }, isOnline: { true })
        await model.load(item: detail([(first.path, 1), (server.path, 2)]))
        model.play()
        var seen: PlayerViewModel.SourceHint?
        await waitFor {
            seen = seen ?? model.sourceHint
            return model.currentTime > 1.5 || model.sourceHint?.kind == .loadFailed
        }
        #expect(seen == .downloadUnreadable, "the hint names the download: \(String(describing: seen))")
        #expect(model.isPlaying && model.currentTime > 1.5, "playback went on past its start: \(model.currentTime)")
        #expect(!FileManager.default.fileExists(atPath: broken.path), "the failed file is dropped")
        model.stop()
    }

    /// The network as a switch the witness turns between the failure and
    /// the held point.
    final class NetworkSwitch { var online = true }

    /// The later file fails with network and is dropped for the server, then
    /// the network goes while the track before still plays. At the held
    /// point nothing can take over: playback holds with the offline hint,
    /// it does not claim to play on from the server.
    @Test("eine spaetere kaputte lokale Datei, und das Netz geht vor ihrem Anfang: Halt mit dem Hinweis ohne Netz", .needsAudio)
    func aLaterBrokenLocalFileHoldsWhenTheNetworkLeft() async throws {
        let first = try tone(seconds: 1)
        let server = try tone(seconds: 2)
        let broken = try brokenFile()
        defer {
            for url in [first, server, broken] { try? FileManager.default.removeItem(at: url) }
        }
        let network = NetworkSwitch()
        let model = PlayerViewModel(provider: MixedProvider(), localTracks: { _ in [1: broken] },
                                    isOnline: { network.online })
        await model.load(item: detail([(first.path, 1), (server.path, 2)]))
        model.play()
        await waitFor { !FileManager.default.fileExists(atPath: broken.path) }
        #expect(!FileManager.default.fileExists(atPath: broken.path), "the precondition: the file failed with network and was dropped")
        #expect(model.currentTime < 1, "the precondition: the track before still plays: \(model.currentTime)")
        network.online = false
        await waitFor { model.sourceHint == .downloadUnreadableOffline || model.currentTime > 1.5 }
        #expect(model.sourceHint == .downloadUnreadableOffline,
                "without network the held point says so: \(String(describing: model.sourceHint))")
        #expect(!model.isPlaying, "playback holds")
        #expect(abs(model.currentTime - 1) < 0.01, "at the start of the failed file: \(model.currentTime)")
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
        await waitFor { model.sourceHint?.kind == .loadFailed }
        #expect(model.sourceHint?.kind == .loadFailed, "after the one try the stream failure says so: \(String(describing: model.sourceHint))")
        #expect(!model.isPlaying, "playback stops")
        let queue = model.player.map(ObjectIdentifier.init)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(model.player.map(ObjectIdentifier.init) == queue, "nothing builds the track again by itself")
        model.stop()
    }
}
#endif
