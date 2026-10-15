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

/// A stored track holds the whole file its source names, at three gates:
/// storing a download, resuming one, and playing a track already stored.
/// Measured before the rule: a body that ended early reported success when
/// the server sent no length, and when a chunked body lacked its last
/// chunk; the short file stayed as a finished track.
@MainActor
struct TrackFileSizeTests {

    @Test("die Regel: weniger Bytes als die Quelle nennt ist keine fertige Spur, nur wo der Download die Datei selbst ist")
    func theRule() {
        #expect(TrackFileSize.stated(60_000, downloadsTheOriginalFile: true) == 60_000)
        #expect(TrackFileSize.stated(60_000, downloadsTheOriginalFile: false) == nil, "a source that may transcode is held to nothing")
        #expect(TrackFileSize.stated(nil, downloadsTheOriginalFile: true) == nil)
        #expect(TrackFileSize.stated(0, downloadsTheOriginalFile: true) == nil, "a zero size states nothing")
        #expect(TrackFileSize.verdict(bytes: 50_000, stated: 60_000) == .short)
        #expect(TrackFileSize.verdict(bytes: 60_000, stated: 60_000) == .whole)
        #expect(TrackFileSize.verdict(bytes: 70_000, stated: 60_000) == .larger, "more than stated is kept")
        #expect(TrackFileSize.verdict(bytes: 50_000, stated: nil) == .unstated)
        #expect(TrackFileSize.verdict(bytes: nil, stated: 60_000) == .unread, "a size that cannot be read is no verdict, never short")
        #expect(TrackFileSize.verdict(bytes: nil, stated: nil) == .unstated)
    }

    /// The capability is stated by the real sources, not by a test double:
    /// a source that loses it drops the rule in silence, one that gains it
    /// throws away every transcoded download.
    @Test("die Faehigkeit an den echten Anbietern: nur Audiobookshelf laedt die Datei selbst")
    func theRealSourcesStateTheCapability() {
        let abs = APIClient(baseURL: URL(string: "https://abs.example.invalid")!, token: nil)
        #expect(abs.capabilities.contains(.downloadsTheOriginalFile), "Audiobookshelf books")
        #expect(ABSPodcastProvider.shared.capabilities.contains(.downloadsTheOriginalFile), "Audiobookshelf podcasts")
        let others: [(String, ProviderCapabilities)] = [
            ("Subsonic", SubsonicProvider.shared.capabilities),
            ("Jellyfin", JellyfinProvider.shared.capabilities),
            ("RSS", RSSProvider.shared.capabilities),
            ("free catalogue", FreeCatalogProvider.shared.capabilities),
            ("local", LocalProvider.shared.capabilities),
            ("radio", RadioProvider.shared.capabilities),
            ("music union", MusicUnion(sources: [SubsonicProvider.shared, JellyfinProvider.shared]).capabilities),
            ("unknown", UnknownSourceProvider.shared.capabilities),
        ]
        #expect(others.filter { $0.1.contains(.downloadsTheOriginalFile) }.map(\.0) == [],
                "a source whose download may not be the file, or that states no size")
    }

    /// Bytes that read as an MPEG audio file to the download's sniffing.
    static func audioBytes(_ count: Int) -> Data {
        Data((0..<count).map { [0xFF, 0xFB, 0x90, 0x64][$0 % 4] })
    }

    /// A host that sends one fixed answer to every request and closes.
    /// Unchecked because the listener and its connections are only touched
    /// on the listener's own queue after start.
    nonisolated final class FixedAnswerHost: @unchecked Sendable {
        private let listener: NWListener
        private let answer: Data
        private(set) var port: UInt16 = 0

        init(head: String, body: Data) throws {
            answer = Data(head.utf8) + body
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws {
            listener.newConnectionHandler = { [answer] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                    connection.send(content: answer, completion: .contentProcessed { _ in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
                    })
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

        func stop() { listener.cancel() }
        var url: URL { URL(string: "http://127.0.0.1:\(port)/0.mp3")! }
    }

    static let noLength = "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\n"
    static let chunked = "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    static func withLength(_ length: Int) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
    }

    /// One download through the app's session; what it threw and what lies
    /// at the destination afterwards.
    func store(head: String, body: Data, stated: Int64?) async throws -> (error: Error?, bytes: Int64?) {
        let host = try FixedAnswerHost(head: head, body: body)
        try await host.start()
        defer { host.stop() }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("trackfile-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await FileDownloader.shared.download(request: URLRequest(url: host.url), to: destination,
                                                     statedBytes: stated, onProgress: { _ in })
            return (nil, TrackFileSize.bytes(at: destination))
        } catch {
            return (error, TrackFileSize.bytes(at: destination))
        }
    }

    @Test("Ablegen: ein frueh beendeter Koerper ohne Laenge und ein chunked ohne Schlussblock werden nicht abgelegt; ganz und groesser bleiben")
    func storingHoldsTheStatedSize() async throws {
        let half = Self.audioBytes(50_000)
        let noLength = try await store(head: Self.noLength, body: half, stated: 60_000)
        #expect(noLength.error is ShortDownloadError, "no length, closed early: \(String(describing: noLength.error))")
        #expect(noLength.bytes == nil, "nothing lies as a track")
        var chunk = Data("c350\r\n".utf8)
        chunk.append(half)
        chunk.append(Data("\r\n".utf8))
        let chunked = try await store(head: Self.chunked, body: chunk, stated: 60_000)
        #expect(chunked.error is ShortDownloadError, "chunked without its last chunk: \(String(describing: chunked.error))")
        #expect(chunked.bytes == nil)
        let whole = try await store(head: Self.withLength(50_000), body: half, stated: 50_000)
        #expect(whole.error == nil && whole.bytes == 50_000, "the whole file stays")
        let larger = try await store(head: Self.withLength(50_000), body: half, stated: 40_000)
        #expect(larger.error == nil && larger.bytes == 50_000, "more than stated is kept")
    }

    @Test("Ablegen ohne genannte Groesse: der frueh beendete Koerper bleibt, diese Quellen faengt die Regel nicht")
    func storingWithoutAStatedSizeKeepsWhatCame() async throws {
        let stored = try await store(head: Self.noLength, body: Self.audioBytes(50_000), stated: nil)
        #expect(stored.error == nil && stored.bytes == 50_000, "the open case, named in the inventory")
    }

    /// A source whose capability says whether its download is the file.
    final class SizedProvider: AudioProvider {
        let original: Bool
        init(original: Bool) { self.original = original }
        var providerId: String { "sized" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { original ? [.downloadable, .downloadsTheOriginalFile] : [.downloadable] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw NSError(domain: "sized", code: 404) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? {
            contentPath.hasPrefix("/") ? URL(fileURLWithPath: contentPath) : URL(string: contentPath)
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    static func book(_ id: String, path: String, size: Int64, seconds: Double = 1) -> LibraryItemDetail {
        LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(metadata: nil, duration: seconds, chapters: nil, tracks: [
                ABSAudioTrack(index: 0, startOffset: 0, duration: seconds, contentUrl: path, metadata: ABSFileMetadata(size: size)),
            ]),
            userMediaProgress: nil)
    }

    @Test("Fortsetzen: eine liegende Spur mit weniger Bytes als genannt wird nicht uebersprungen, sondern neu geladen")
    func resumingLoadsAShortTrackAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trackfile-resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let itemId = "trackfile-\(UUID().uuidString)"
        let folder = directory.appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(itemId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let short = folder.appendingPathComponent("0.mp3")
        try Self.audioBytes(1_000).write(to: short)
        let host = try FixedAnswerHost(head: Self.withLength(50_000), body: Self.audioBytes(50_000))
        try await host.start()
        defer { host.stop() }
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let manager = DownloadManager(documents: directory, database: database)
        await manager.ensureScanned()

        await manager.download(item: Self.book(itemId, path: host.url.absoluteString, size: 50_000),
                               provider: SizedProvider(original: true), kind: nil)

        let stored = try #require(manager.localTrackMap(forItemId: itemId)[0], "a track lies there")
        #expect(TrackFileSize.bytes(at: stored) == 50_000, "the short track was loaded again: \(String(describing: TrackFileSize.bytes(at: stored)))")
    }

    /// A tone the player plays, as the "server" file of a track.
    func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trackfile-\(UUID().uuidString).caf")
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

    /// The stored file of a track and the one its source names, for the
    /// player: the stored one is a copy cut short, the stated size is the
    /// whole file's.
    func shortCopy(of server: URL) throws -> (local: URL, stated: Int64) {
        let whole = try Data(contentsOf: server)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("trackfile-local-\(UUID().uuidString).caf")
        try whole.prefix(whole.count / 2).write(to: local)
        return (local, Int64(whole.count))
    }

    func playedURL(_ model: PlayerViewModel) -> URL? {
        (model.player?.currentItem?.asset as? AVURLAsset)?.url
    }

    @Test("Abspielen: eine schon liegende Spur mit weniger Bytes als genannt wird nicht abgespielt, sie kommt vom Server und die lokale Datei geht", .needsAudio)
    func playingTakesAShortStoredTrackFromTheServer() async throws {
        let server = try tone(seconds: 2)
        let (local, stated) = try shortCopy(of: server)
        defer { for url in [server, local] { try? FileManager.default.removeItem(at: url) } }
        let model = PlayerViewModel(provider: SizedProvider(original: true), localTracks: { _ in [0: local] }, isOnline: { true })
        await model.load(item: Self.book("trackfile-\(UUID().uuidString)", path: server.path, size: stated, seconds: 2))
        #expect(!FileManager.default.fileExists(atPath: local.path), "the short file is gone")
        #expect(playedURL(model)?.path == server.path, "the track plays from the server: \(String(describing: playedURL(model)))")
        #expect(model.currentTime == 0, "the position did not move")
        model.stop()
    }

    /// Without network a short stored track is what a local file that
    /// cannot load is: it stays, it is not played, and playback holds with
    /// the hint that the download is unavailable offline. The next load
    /// with network drops it and plays from the server.
    @Test("ohne Netz: die kurze Spur bleibt liegen, wird nicht gespielt, Halt mit dem Offline-Hinweis; mit Netz geht sie", .needsAudio)
    func offlineAShortStoredTrackStaysAndHolds() async throws {
        let server = try tone(seconds: 2)
        let (local, stated) = try shortCopy(of: server)
        defer { for url in [server, local] { try? FileManager.default.removeItem(at: url) } }
        let id = "trackfile-\(UUID().uuidString)"
        // Offline the server cannot be reached: its address is dead.
        let offline = PlayerViewModel(provider: SizedProvider(original: true), localTracks: { _ in [0: local] }, isOnline: { false })
        await offline.load(item: Self.book(id, path: "http://127.0.0.1:1/0.caf", size: stated, seconds: 2))
        #expect(playedURL(offline)?.path != local.path, "the short file is not played")
        offline.play()
        await waitFor { offline.sourceHint != nil }
        #expect(offline.sourceHint?.kind == .downloadUnreadableOffline,
                "the hold of a local file that cannot load offline: \(String(describing: offline.sourceHint))")
        #expect(!offline.isPlaying, "playback holds")
        #expect(FileManager.default.fileExists(atPath: local.path), "without network the file stays")
        offline.stop()

        let online = PlayerViewModel(provider: SizedProvider(original: true), localTracks: { _ in [0: local] }, isOnline: { true })
        await online.load(item: Self.book(id, path: server.path, size: stated, seconds: 2))
        #expect(!FileManager.default.fileExists(atPath: local.path), "the next load with network drops it")
        #expect(playedURL(online)?.path == server.path)
        online.stop()
    }

    private func waitFor(_ condition: () -> Bool, seconds: Double = 10) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test("eine Quelle, deren Download umkodiert sein kann: die kleinere Datei bleibt und wird abgespielt", .needsAudio)
    func aSourceThatMayTranscodeKeepsItsFile() async throws {
        let server = try tone(seconds: 2)
        let (local, stated) = try shortCopy(of: server)
        defer { for url in [server, local] { try? FileManager.default.removeItem(at: url) } }
        let model = PlayerViewModel(provider: SizedProvider(original: false), localTracks: { _ in [0: local] }, isOnline: { true })
        await model.load(item: Self.book("trackfile-\(UUID().uuidString)", path: server.path, size: stated, seconds: 2))
        #expect(FileManager.default.fileExists(atPath: local.path), "the smaller file stays")
        #expect(playedURL(model)?.path == local.path, "the stored file plays: \(String(describing: playedURL(model)))")
        model.stop()
    }
}
#endif
