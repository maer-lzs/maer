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
}
#endif
