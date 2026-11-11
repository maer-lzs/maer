// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// A stopped model stays stopped: no player, no claim, no "plays", whatever
/// task comes back after an await. A check before play that was still
/// waiting when the next title opened started the old title beside it.
@MainActor
struct StoppedStaysStoppedTests {
    /// A model that loaded a title from a server that answers its stand.
    private static func loaded(_ file: URL) async throws -> PlayerViewModel {
        let server = ResumeStandTests.SharedServer(file: file.path, position: 5)
        let model = PlayerViewModel(provider: server, localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: try await server.fetchItemDetail(itemId: "stopped-\(UUID().uuidString)"))
        #expect(model.player != nil, "the precondition: the load built a player")
        return model
    }

    @Test("nach stop() ist isPlaying falsch und das Modell gestoppt", .needsAudio)
    func afterStopNothingPlays() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = try await Self.loaded(file)
        model.isPlaying = true
        model.stop()
        #expect(!model.isPlaying, "a stopped model still says it plays")
        #expect(model.isStopped)
        #expect(model.player == nil)
    }

    @Test("die Pruefung vor dem Start, die nach dem Stopp zurueckkommt, startet nichts", .needsAudio)
    func theCheckBeforePlayStartsNothingOnAStoppedModel() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = try await Self.loaded(file)
        var starts = 0
        let counted = model.playbackStarts.sink { starts += 1 }
        defer { counted.cancel() }
        // The check begins and runs to its first wait; the model is stopped
        // while it waits. (`async let` on the main actor began only at its
        // await, after the stop: a question only at the entrance of the
        // check passed it too.)
        let check = Task { await model.playWithServerCheck(caller: "remote play") }
        for _ in 0..<5 { await Task.yield() }
        model.stop()
        await check.value
        #expect(!model.isPlaying, "the stopped model says it plays")
        #expect(model.player == nil, "the stopped model built a player")
        #expect(model.playbackStartedAtMs == 0, "the stopped model claimed its title")
        #expect(starts == 0, "the stopped model counted a start")
    }

    @Test("eine Pause, waehrend die Pruefung vor dem Start wartet, gewinnt: es startet nichts", .needsAudio)
    func aPauseDuringTheCheckWins() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = try await Self.loaded(file)
        var starts = 0
        let counted = model.playbackStarts.sink { starts += 1 }
        defer { counted.cancel() }
        let check = Task { await model.playWithServerCheck(caller: "remote play") }
        for _ in 0..<5 { await Task.yield() }
        model.pause(caller: "the person")
        await check.value
        #expect(!model.isPlaying, "the start played over the pause")
        #expect(starts == 0, "the start counted a play after the pause")
        #expect(!model.isStopped, "a pause is no stop")
    }

    @Test("ein Laden, das keinen Spieler baute, startet nichts: kein spielt, kein Anspruch, kein gezaehlter Start")
    func aFailedLoadStartsNothing() {
        let model = PlayerViewModel(provider: MockProvider())
        var starts = 0
        let counted = model.playbackStarts.sink { starts += 1 }
        defer { counted.cancel() }
        #expect(model.player == nil, "the precondition: no player was built")
        model.play(caller: "remote play")
        #expect(!model.isPlaying, "a title that did not load says it plays")
        #expect(model.playbackStartedAtMs == 0, "a title that did not load claimed")
        #expect(starts == 0, "a title that did not load counted a start")
    }

    @Test("das Fenster: Titel, Spieler und Halte; jede Aenderung bricht es")
    func theWaitWindowRule() {
        let model = PlayerViewModel(provider: MockProvider())
        let before = WaitWindow(itemId: "a", player: ObjectIdentifier(model), holds: 2)
        #expect(WaitWindow.stillStands(before, before))
        #expect(!WaitWindow.stillStands(before, WaitWindow(itemId: "b", player: ObjectIdentifier(model), holds: 2)))
        #expect(!WaitWindow.stillStands(before, WaitWindow(itemId: "a", player: nil, holds: 2)))
        #expect(!WaitWindow.stillStands(before, WaitWindow(itemId: "a", player: ObjectIdentifier(model), holds: 3)))
    }

    @Test("die Grenze vor dem Start ist hart: ein Abgleich, der spaet antwortet, haelt den Start nicht laenger als die Grenze")
    func theLimitBeforeTheStartIsHard() async {
        let slow = Task { _ = try? await Task.sleep(for: .seconds(5)) }
        let started = ContinuousClock.now
        await WaitLimit.wait(for: slow, atMost: .milliseconds(300))
        let waited = ContinuousClock.now - started
        #expect(waited < .seconds(2), "the wait followed the slow task: \(waited)")
        #expect(waited >= .milliseconds(250), "the wait did not wait: \(waited)")
        #expect(!slow.isCancelled, "the wait cancelled the task, which runs on")
        slow.cancel()
        let quick = Task { }
        let quickStarted = ContinuousClock.now
        await WaitLimit.wait(for: quick, atMost: .seconds(5))
        #expect(ContinuousClock.now - quickStarted < .seconds(2), "a task that ended was waited out to the limit")
        #expect(PlayerViewModel.reconcileWaitLimit == .milliseconds(1500))
    }

    @Test("ein Sprung auf einem gestoppten Modell baut keinen Player und bewegt nichts", .needsAudio)
    func aJumpOnAStoppedModelBuildsNothing() async throws {
        let file = try TickWorkTests().tone(seconds: 60)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = try await Self.loaded(file)
        let stood = model.currentTime
        model.stop()
        await model.seek(to: 40)
        #expect(model.player == nil, "a jump rebuilt the queue of a stopped model")
        #expect(model.currentTime == stood, "a jump moved a stopped model: \(model.currentTime)")
        model.play()
        #expect(!model.isPlaying && model.player == nil, "play started a stopped model")
    }
}
#endif
