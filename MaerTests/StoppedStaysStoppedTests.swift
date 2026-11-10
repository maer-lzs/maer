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
        // The check begins, the model is stopped while it waits.
        async let check: Void = model.playWithServerCheck(caller: "remote play")
        model.stop()
        await check
        #expect(!model.isPlaying, "the stopped model says it plays")
        #expect(model.player == nil, "the stopped model built a player")
        #expect(model.playbackStartedAtMs == 0, "the stopped model claimed its title")
        #expect(starts == 0, "the stopped model counted a start")
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
