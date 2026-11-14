// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import AVFoundation
import Foundation
import Testing
@testable import Maer

/// Playing on after a pause: the stand in the local store moves the player
/// only when it is stamped after the player's own stand
/// (`SyncRules.storedStand`, `PlayerViewModel.storedStandTarget`).
struct ResumeStandTests {

    @Test("the rule: a state next to one's own moves nothing, an older one never, a newer one does, before the first listen the freshest")
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

    @Test("through the real player: after the pause an older state in the store leaves the player alone", .needsAudio)
    func anOlderStandKeepsThePlayer() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "rss:resume-\(UUID().uuidString):ep"
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        model.isPlaying = true
        model.currentTime = 9
        model.pause()
        let paused = try #require(model.ownStandMs, "the precondition: the pause is the player's own stand")
        ListeningStore.record(id, position: 3, duration: 12, atMs: paused - 60_000)
        #expect(ListeningStore.mark(id)?.position == 3, "the precondition: the older stand is in the store")
        #expect(model.storedStandTarget() == nil, "an older stand moved the player back")
        model.stop()
    }

    @Test("through the real player: a state that another device wrote after the pause moves the player", .needsAudio)
    func aNewerStandMovesThePlayer() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "rss:resume-\(UUID().uuidString):ep"
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        model.isPlaying = true
        model.currentTime = 9
        model.pause()
        let paused = try #require(model.ownStandMs, "the precondition: the pause is the player's own stand")
        ListeningStore.record(id, position: 3, duration: 12, atMs: paused + 1_000)
        #expect(model.storedStandTarget() == 3, "the other device's later stand did not move the player")
        #expect(model.ownStandMs == paused + 1_000, "the taken stand is the player's stand from now on")
        model.stop()
    }

    @Test("through the real player: a pause on a silent device is no state of its own, the other's state moves it afterwards", .needsAudio)
    func aSilentPauseIsNoOwnStand() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "rss:resume-\(UUID().uuidString):ep"
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        model.currentTime = 9
        #expect(!model.isPlaying, "the precondition: the device only holds the item")
        model.pause()
        #expect(model.ownStandMs == nil, "a pause on a silent device made its stand its own")
        ListeningStore.record(id, position: 3, duration: 12, atMs: Date().timeIntervalSince1970 * 1000 - 60_000)
        #expect(model.storedStandTarget() == 3, "the other device's stand from a minute ago did not move it")
        model.stop()
    }

    @Test("the release after a pause carries only the state of a running piece")
    func aSilentReleaseCarriesNoPosition() {
        #expect(PlaybackClaimRules.releasePosition(wasPlaying: true, currentTime: 42) == 42)
        #expect(PlaybackClaimRules.releasePosition(wasPlaying: false, currentTime: 42) == nil)
    }

    @Test("the pause asks the release rule and sets its own state only if a piece played", .needsTheSources)
    func thePauseAsksTheReleaseRule() throws {
        let text = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel.swift")
        #expect(text.contains("position: PlaybackClaimRules.releasePosition(wasPlaying: wasPlaying, currentTime: currentTime),"),
                "the pause's release carries the position without asking")
        #expect(text.contains("if wasPlaying { recordHaltStand() }"),
                "a pause makes the stand its own without having played")
        #expect(text.contains("ownStandMs = nowMs"), "the hold's stand is the device's own")
    }

    @Test("Playing on asks the rule and not a bare distance of the positions", .needsTheSources)
    func playingOnAsksTheRule() throws {
        let text = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel.swift")
        let start = try #require(text.range(of: "func playWithServerCheck(caller: String = #function) async {"), "playWithServerCheck is gone")
        let rest = text[start.upperBound...]
        let body = String(rest[..<(rest.range(of: " func ")?.lowerBound ?? rest.endIndex)])
        #expect(body.contains("if let target = storedStandTarget() {"), "playing on does not ask the rule")
        #expect(!body.contains("abs(mark.position - currentTime)"), "playing on moves by distance alone")
    }

    /// Every call of the player's `play` in the sources, by file: a call
    /// on a model (`self`, `vm`, `viewModel`) anywhere, and a bare call
    /// inside the player's own files. Comments are stripped first.
    static func playCalls() -> [String: Int] {
        let onModel = try! NSRegularExpression(pattern: #"(?:self|vm|viewModel)\??\.play\("#)
        let bare = try! NSRegularExpression(pattern: #"(?<!func )(?<![A-Za-z0-9_.])play\((?:caller:[^)]*)?\)"#)
        var out: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let text = SyncContractFenceTests.stripped(file.text)
            let range = NSRange(text.startIndex..., in: text)
            var count = onModel.numberOfMatches(in: text, range: range)
            if file.name.hasPrefix("PlayerViewModel") {
                count += bare.numberOfMatches(in: text, range: range)
            }
            if count > 0 { out[file.name] = count }
        }
        return out
    }

    @Test("every path to resuming asks the sync first; only a deliberate jump (chapter, from the start) starts at once", .needsTheSources)
    func everyWayToPlayOnAsksFirst() throws {
        #expect(ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]).count > 100, "the fence did not read the sources")
        #expect(Self.playCalls() == ["PlayerViewModel.swift": 1, "BookDetailScreen.swift": 2],
                "a way to play on starts without the check: \(Self.playCalls())")
        let text = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel.swift")
        #expect(text.contains("play(caller: caller) }"), "the one bare call is not the end of playWithServerCheck")
    }

    @Test("two devices: resuming through the sync starts at the later state of the other device", .needsAudio)
    func playingOnStartsAtTheLaterStand() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "resume-remote-\(UUID().uuidString)"
        let server = SharedServer(file: file.path, position: 5)
        let first = try await Self.device(server, id)
        let second = try await Self.device(server, id)
        try await Self.playAndPause(first, to: 25, server)
        try await Self.playAndPause(second, to: 45, server)
        Self.asOwnStore(first, id)
        await first.playWithServerCheck(caller: "remote play")
        #expect(first.currentTime == 45, "playing on started at the old stand: \(first.currentTime)")
        first.stop()
        second.stop()
    }

    @Test("the plan: pause, stop, background and interruption write only an owed state, own actions always")
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

    @Test("two devices: a silent device goes to the background and is stopped, the playing one does not jump back afterwards", .needsAudio)
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

    @Test("an interruption while listening writes the state the device owes", .needsAudio)
    func anInterruptionWritesTheOwedStand() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "resume-call-\(UUID().uuidString)"
        let server = SharedServer(file: file.path, position: 5)
        let model = try await Self.device(server, id)
        let before = server.writes
        model.isPlaying = true
        model.currentTime = 25
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        for _ in 0..<100 where server.writes == before { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!model.isPlaying, "the precondition: the interruption halted the player")
        #expect(server.writes == before + 1 && server.position == 25, "the interruption lost the stand: \(server.position)")
        model.stop()
    }

    @Test("two devices: if the other really plays on, the first jumps to its state afterwards", .needsAudio)
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
