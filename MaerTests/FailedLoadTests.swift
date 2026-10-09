// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import AVFoundation
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

    /// Tracks with an absolute path play from that file; every other track
    /// sits at the dead loopback port.
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
            contentPath.hasPrefix("/") ? URL(fileURLWithPath: contentPath) : URL(string: "http://127.0.0.1:1/\(contentPath)")
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
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

    @Test("eine spaetere Datei, die nicht laden kann, haelt an ihrem Anfang an, die Position springt nicht ueber sie")
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
}
#endif
