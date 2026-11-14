// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Testing
@testable import Maer

/// The stand of a hold is one value: the device records it before the
/// server write is tried, and the flush of the next start retires a queued
/// stand only when that stand is not newer.
@MainActor
@Suite(.serialized)
struct HaltStandTests {
    /// A server that can be cut off: its writes then fail like a sign-out
    /// or a dead network, and the stand goes into the queue.
    final class Server: AudioProvider {
        let file: String
        var position: Double
        var lastUpdate: Double
        var refuses = false
        var writes = 0
        init(file: String, position: Double) {
            self.file = file
            self.position = position
            self.lastUpdate = Date().timeIntervalSince1970 * 1000 - 600_000
        }
        var providerId: String { "halt" }
        var keepsMarksOnDevice: Bool { false }
        var capabilities: ProviderCapabilities { [.progressSync] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(metadata: nil, duration: 60, chapters: nil, tracks: [
                    ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: file, metadata: nil),
                ]),
                userMediaProgress: MediaProgress(currentTime: position, duration: 60, progress: nil,
                                                 isFinished: false, lastUpdate: lastUpdate))
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { URL(fileURLWithPath: contentPath) }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
            if refuses { throw URLError(.notConnectedToInternet) }
            writes += 1
            position = currentTime
            lastUpdate = max(Date().timeIntervalSince1970 * 1000, lastUpdate + 1)
        }
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    private static func device(_ server: Server, _ id: String) async throws -> PlayerViewModel {
        let model = PlayerViewModel(provider: server, localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: try await server.fetchItemDetail(itemId: id))
        await model.reconcileWithServer()
        return model
    }

    private static func waitForQueued(_ id: String) async throws -> SyncQueue.PendingUpdate? {
        for _ in 0..<100 where SyncQueue.shared.pendingUpdate(itemId: id) == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return SyncQueue.shared.pendingUpdate(itemId: id)
    }

    private static func clean(_ id: String) async {
        await SyncQueue.shared.remove(itemId: id, ifStill: SyncQueue.shared.pendingUpdate(itemId: id))
        ListeningStore.clearBackup(id)
        ListeningStore.forgetUserDeleted(id)
    }

    @Test("the rule: a write retires a queued stand only when that stand is not newer")
    func rule() {
        #expect(SyncRules.writeRetiresQueued(queuedAtMs: 1000, queuedTime: 134, writtenAtMs: 2000, writtenTime: 140),
                "an older queued stand goes")
        #expect(!SyncRules.writeRetiresQueued(queuedAtMs: 3000, queuedTime: 134, writtenAtMs: 2000, writtenTime: 131),
                "a newer queued stand stays")
        #expect(!SyncRules.writeRetiresQueued(queuedAtMs: 3000, queuedTime: 50, writtenAtMs: 2000, writtenTime: 131),
                "newer by time, not by position: a rewind stays")
        #expect(SyncRules.writeRetiresQueued(queuedAtMs: 3000, queuedTime: 134, writtenAtMs: 2000, writtenTime: 134),
                "the same stand queued a moment later is the one written")
        #expect(SyncRules.writeRetiresQueued(queuedAtMs: nil, queuedTime: 1, writtenAtMs: 0, writtenTime: 99),
                "an entry without its moment goes")
    }

    @Test("a stop whose write fails records the same stand on the device, and the next start writes it", .needsAudio)
    func stopWithoutServerThenSignInAgain() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "halt-stop-\(UUID().uuidString)"
        defer { Task { await Self.clean(id) } }
        let server = Server(file: file.path, position: 5)
        let first = try await Self.device(server, id)
        // The last tick, three seconds before the stop.
        ListeningStore.record(id, position: 31, duration: 60, atMs: Date().timeIntervalSince1970 * 1000 - 3000)
        server.refuses = true
        first.isPlaying = true
        first.currentTime = 34
        first.stop(caller: "its server signed out")
        let queued = try await Self.waitForQueued(id)
        #expect(queued?.currentTime == 34, "the precondition: the failed write queued the stand")
        #expect(ListeningStore.backup(id)?.first == 34, "the stop recorded its stand on the device before the write")

        server.refuses = false
        _ = try await Self.device(server, id)
        #expect(server.position == 34, "the next start wrote the stand of the stop, not the last tick: \(server.position)")
        #expect(SyncQueue.shared.pendingUpdate(itemId: id) == nil, "the same stand written retires the queued one")
    }

    @Test("the flush of a restored older stand keeps a newer queued one", .needsAudio)
    func restoreKeepsANewerQueuedStand() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "halt-keep-\(UUID().uuidString)"
        defer { Task { await Self.clean(id) } }
        let server = Server(file: file.path, position: 5)
        let now = Date().timeIntervalSince1970 * 1000
        ListeningStore.record(id, position: 31, duration: 60, atMs: now - 3000)
        await SyncQueue.shared.enqueue(itemId: id, currentTime: 34, duration: 60, isFinished: false)
        _ = try await Self.device(server, id)
        #expect(server.position == 31, "the precondition: the start flushed its restored stand")
        #expect(SyncQueue.shared.pendingUpdate(itemId: id)?.currentTime == 34, "the newer queued stand was retired by an older write")
    }

    @Test("a rewind before the stop: the server gets the smaller, newer stand", .needsAudio)
    func rewindBeforeTheStop() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "halt-rewind-\(UUID().uuidString)"
        defer { Task { await Self.clean(id) } }
        let server = Server(file: file.path, position: 5)
        let first = try await Self.device(server, id)
        first.isPlaying = true
        first.currentTime = 40
        first.pause()
        for _ in 0..<100 where server.position != 40 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.position == 40, "the precondition: the pause wrote 40")
        try await Task.sleep(nanoseconds: 20_000_000)
        server.refuses = true
        first.isPlaying = true
        first.currentTime = 20
        first.stop(caller: "its server signed out")
        #expect(try await Self.waitForQueued(id)?.currentTime == 20, "the precondition: the failed write queued 20")

        server.refuses = false
        _ = try await Self.device(server, id)
        #expect(server.position == 20, "the rewound stand reached the server: \(server.position)")
    }
}
