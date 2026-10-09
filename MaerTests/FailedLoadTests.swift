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
    }

    /// A source whose every track lives at a loopback port nothing listens
    /// on: the item fails to load at once, as a stream does without network.
    private final class DeadAddressProvider: AudioProvider {
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
}
#endif
