// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// An order leaves Up Next only when its title plays: at the first progress,
/// not when it opens. A title whose stream fails stays and the advance
/// passes it for the rest of the process, until the person opens it or the
/// network changes; for the advance, started means the first progress.
@MainActor
struct OrdersWaitForProgressTests {
    /// Titles whose id starts with "dead" name a file that is not there;
    /// every other title is 60 s of silence.
    @MainActor
    final class DeadOrAliveProvider: AudioProvider {
        let file: URL
        init(file: URL) { self.file = file }
        var providerId: String { "dead-or-alive" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        var isAvailable: Bool { true }
        var accessUnknown: Bool { false }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: itemId, metadata: nil)
            let media = LibraryItemMedia(metadata: LibraryItemMetadata(title: itemId, authorName: nil, narratorName: nil,
                                                                       seriesName: nil, genres: nil, publishedYear: nil,
                                                                       description: nil),
                                         duration: 60, chapters: nil, tracks: [track])
            return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? {
            contentPath.hasPrefix("dead") ? file.deletingLastPathComponent().appendingPathComponent("gone-\(UUID().uuidString).wav") : file
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    private static func title(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(metadata: nil, duration: 60, chapters: nil, tracks: nil), addedAt: nil)
    }

    private static func silence() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("orders-\(UUID().uuidString).wav")
        try SilentAudio.wav(seconds: 60).write(to: file)
        return file
    }

    /// A coordinator whose opens ask the witness's source and whose advance
    /// knows the witness's titles.
    private static func coordinator(_ file: URL) -> PlayerCoordinator {
        let source = DeadOrAliveProvider(file: file)
        let coordinator = PlayerCoordinator(provider: source)
        coordinator.route = { _ in source }
        coordinator.known = { title($0) }
        return coordinator
    }

    @Test("an order opened stays in Up Next until its title progresses, then it leaves")
    func anOrderLeavesAtTheFirstProgress() async throws {
        let file = try Self.silence()
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = Self.coordinator(file)
        let id = "order-\(UUID().uuidString)"
        PlayQueue.shared.playLast(id)
        defer { PlayQueue.shared.remove(id); coordinator.viewModel?.stop() }
        await Reachability.$assumed.withValue(true) {
            await coordinator.open(item: Self.title(id), autoplay: false)
        }
        #expect(coordinator.activeItem?.id == id, "the precondition: the open stands")
        #expect(PlayQueue.shared.contains(id), "the order left before its title played")
        coordinator.viewModel?.firstProgress.send(id)
        #expect(!PlayQueue.shared.contains(id), "the order stays after its title played")
    }

    @Test("a stream that fails before it progresses stays in Up Next, the advance passes it and opens the next order")
    func aDeadStreamStaysAndIsPassed() async throws {
        let file = try Self.silence()
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = Self.coordinator(file)
        let first = "first-\(UUID().uuidString)"
        let dead = "dead-\(UUID().uuidString)"
        let next = "next-\(UUID().uuidString)"
        PlayQueue.shared.playLast(dead)
        PlayQueue.shared.playLast(next)
        defer {
            for id in [dead, next] { PlayQueue.shared.remove(id) }
            coordinator.viewModel?.stop()
        }
        await Reachability.$assumed.withValue(true) {
            await coordinator.open(item: Self.title(first), autoplay: false)
            coordinator.markPlayedAndAdvance(itemId: first)
            var waited = 0
            while coordinator.activeItem?.id != next && waited < 100 {
                try? await Task.sleep(for: .milliseconds(100)); waited += 1
            }
        }
        #expect(coordinator.activeItem?.id == next, "the advance stopped at the dead stream: \(coordinator.activeItem?.id ?? "-")")
        #expect(PlayQueue.shared.contains(dead), "the dead stream left Up Next")
        #expect(coordinator.unstartable.contains(dead))
        #expect(coordinator.resolveAdvance(after: next)?.id != dead, "the advance offers the dead stream again")
        coordinator.networkChanged()
        #expect(coordinator.unstartable.isEmpty, "a change of the network asks the dead stream again")
    }

    @Test("Fence: the model says the first progress and a failure before it, the coordinator hears both and the network", .needsTheSources)
    func theWayIsWired() throws {
        let model = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        #expect(model.contains("firstProgress.send("), "the model never says its first progress")
        #expect(model.contains("failedBeforeProgress.send("), "the model never says a failure before it")
        let coordinator = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        #expect(coordinator.contains("viewModel?.firstProgress.sink"))
        #expect(coordinator.contains("viewModel?.failedBeforeProgress.sink"))
        #expect(coordinator.contains("!self.unstartable.contains("), "the advance does not pass a dead stream")
        #expect(coordinator.contains("self?.networkChanged()"), "a change of the network does not clear the skips")
    }
}
#endif
