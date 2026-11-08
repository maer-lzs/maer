// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Playing on after a pause: the stand in the local store moves the player
/// only when it is stamped after the player's own stand
/// (`SyncRules.storedStand`, `PlayerViewModel.storedStandTarget`).
struct ResumeStandTests {

    @Test("die Regel: ein Stand neben dem eigenen bewegt nichts, ein aelterer nie, ein neuerer schon, vor dem ersten Hoeren der frischeste")
    func theRule() {
        let own = 1_000_000.0
        #expect(SyncRules.storedStand(position: 101, atMs: own + 5_000, ownStandMs: own, currentTime: 100) == .same)
        #expect(SyncRules.storedStand(position: 20, atMs: own - 60_000, ownStandMs: own, currentTime: 100) == .older)
        #expect(SyncRules.storedStand(position: 20, atMs: own, ownStandMs: own, currentTime: 100) == .older,
                "a stand stamped at the own moment is the own one")
        #expect(SyncRules.storedStand(position: 20, atMs: own + 1, ownStandMs: own, currentTime: 100) == .newer)
        #expect(SyncRules.storedStand(position: 20, atMs: 1, ownStandMs: nil, currentTime: 100) == .newer,
                "before the player listened, the freshest stand starts it")
    }

    @Test("ueber den echten Player: nach der Pause laesst ein aelterer Stand im Speicher den Player stehen", .needsAudio)
    func anOlderStandKeepsThePlayer() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "rss:resume-\(UUID().uuidString):ep"
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        model.currentTime = 9
        model.pause()
        let paused = try #require(model.ownStandMs, "the precondition: the pause is the player's own stand")
        ListeningStore.record(id, position: 3, duration: 12, atMs: paused - 60_000)
        #expect(ListeningStore.mark(id)?.position == 3, "the precondition: the older stand is in the store")
        #expect(model.storedStandTarget() == nil, "an older stand moved the player back")
        model.stop()
    }

    @Test("ueber den echten Player: ein Stand, den ein anderes Geraet nach der Pause schrieb, bewegt den Player", .needsAudio)
    func aNewerStandMovesThePlayer() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "rss:resume-\(UUID().uuidString):ep"
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        model.currentTime = 9
        model.pause()
        let paused = try #require(model.ownStandMs, "the precondition: the pause is the player's own stand")
        ListeningStore.record(id, position: 3, duration: 12, atMs: paused + 1_000)
        #expect(model.storedStandTarget() == 3, "the other device's later stand did not move the player")
        #expect(model.ownStandMs == paused + 1_000, "the taken stand is the player's stand from now on")
        model.stop()
    }

    @Test("Weiterspielen fragt die Regel und keinen blossen Abstand der Positionen", .needsTheSources)
    func playingOnAsksTheRule() throws {
        let text = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel.swift")
        let start = try #require(text.range(of: "func playWithServerCheck() async {"), "playWithServerCheck is gone")
        let rest = text[start.upperBound...]
        let body = String(rest[..<(rest.range(of: " func ")?.lowerBound ?? rest.endIndex)])
        #expect(body.contains("if let target = storedStandTarget() {"), "playing on does not ask the rule")
        #expect(!body.contains("abs(mark.position - currentTime)"), "playing on moves by distance alone")
    }

    @Test("der Plan: Pause, Stopp, Hintergrund und Unterbrechung schreiben nur einen geschuldeten Stand, eigene Handlungen immer")
    func onlyAnOwedStandIsWritten() {
        let owing = SyncPlanTests.state()
        var idle = owing
        idle.owesStand = false
        #expect(owing.owesStand, "the precondition: a state owes its stand unless told otherwise")
        for origin in SyncOrigin.allCases {
            let held = SyncRules.plan(origin: origin, state: idle).gate == .noOwnStand
            #expect(held == origin.needsOwnStand, "\(origin) on a device that owes no stand")
            #expect(SyncRules.plan(origin: origin, state: owing).gate != .noOwnStand, "\(origin) on a device that owes its stand")
        }
        #expect(Set(SyncOrigin.allCases.filter(\.needsOwnStand)) == [.pause, .stop, .background, .interruption])
    }

    /// A progress server two players share, as two devices share one.
    final class SharedServer: AudioProvider {
        let file: String
        var position: Double
        var lastUpdate: Double
        var writes = 0
        init(file: String, position: Double) {
            self.file = file
            self.position = position
            self.lastUpdate = Date().timeIntervalSince1970 * 1000 - 600_000
        }
        var providerId: String { "shared" }
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
            writes += 1
            position = currentTime
            lastUpdate = max(Date().timeIntervalSince1970 * 1000, lastUpdate + 1)
        }
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    /// A device that opened the title from the shared server and asked it.
    private static func device(_ server: SharedServer, _ id: String) async throws -> PlayerViewModel {
        let model = PlayerViewModel(provider: server, localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: try await server.fetchItemDetail(itemId: id))
        await model.reconcileWithServer()
        #expect(model.startSourceResolved, "the precondition: the server answered the start")
        return model
    }

    /// The device plays to `position` and pauses; returns once the pause is written.
    private static func playAndPause(_ model: PlayerViewModel, to position: Double, _ server: SharedServer) async throws {
        let before = server.writes
        model.isPlaying = true
        model.currentTime = position
        model.pause()
        for _ in 0..<100 where server.writes == before { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(server.writes == before + 1, "the precondition: the pause wrote its stand")
    }

    /// Both players share this process's one store, where each device has
    /// its own: before a device asks the server, the store holds the stand
    /// that device last pushed, or the echo guard reads the other one's.
    private static func asOwnStore(_ model: PlayerViewModel, _ id: String) {
        ListeningStore.noteFlushed(id, position: model.lastSyncedTime, atMs: Date().timeIntervalSince1970 * 1000)
    }

    @Test("zwei Geraete: ein stilles Geraet geht in den Hintergrund und wird gestoppt, das spielende springt danach nicht zurueck", .needsAudio)
    func aSilentDeviceDoesNotPullThePlayingOneBack() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "resume-two-\(UUID().uuidString)"
        let server = SharedServer(file: file.path, position: 5)
        let playing = try await Self.device(server, id)
        let silent = try await Self.device(server, id)
        try await Self.playAndPause(playing, to: 25, server)
        let writes = server.writes
        await silent.syncProgress(.background)
        silent.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(server.writes == writes && server.position == 25, "the silent device wrote its old stand: \(server.position)")
        Self.asOwnStore(playing, id)
        await playing.reconcileWithServer()
        #expect(playing.currentTime == 25, "the playing device jumped back to \(playing.currentTime)")
        playing.stop()
    }

    @Test("zwei Geraete: spielt das andere wirklich weiter, springt das erste danach auf dessen Stand", .needsAudio)
    func aRealSwitchStillMoves() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "resume-switch-\(UUID().uuidString)"
        let server = SharedServer(file: file.path, position: 5)
        let first = try await Self.device(server, id)
        let second = try await Self.device(server, id)
        try await Self.playAndPause(first, to: 25, server)
        try await Self.playAndPause(second, to: 45, server)
        Self.asOwnStore(first, id)
        await first.reconcileWithServer()
        #expect(first.currentTime == 45, "the device did not take the other one's later stand: \(first.currentTime)")
        first.stop()
        second.stop()
    }
}
#endif
