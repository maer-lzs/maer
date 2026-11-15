// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// 🔴 Hammering play under a bad network must never produce two audio
/// tracks. Every open() draws a generation, only the last one wins.
struct OpenGateTests {
    @Test("N fast taps on the SAME title ⇒ exactly ONE attempt")
    func repeatedTapsCoalesce() {
        var gate = OpenGate()
        let first = gate.begin(itemId: "A", restart: false)
        #expect(first == 1)
        // The four further taps within the time window of the hanging fetch
        // coalesce. No second start.
        for _ in 0..<4 { #expect(gate.begin(itemId: "A", restart: false) == nil) }
        #expect(gate.isCurrent(first ?? 0))
    }

    @Test("an explicit restart does NOT coalesce")
    func restartAlwaysCounts() {
        var gate = OpenGate()
        _ = gate.begin(itemId: "A", restart: false)
        #expect(gate.begin(itemId: "A", restart: true) != nil)
    }

    @Test("with different titles the LAST generation wins")
    func lastGenerationWins() {
        var gate = OpenGate()
        let a = gate.begin(itemId: "A", restart: false)!
        let b = gate.begin(itemId: "B", restart: false)!
        let c = gate.begin(itemId: "C", restart: false)!
        // The old returners recognise themselves as stale and clean up.
        #expect(!gate.isCurrent(a))
        #expect(!gate.isCurrent(b))
        #expect(gate.isCurrent(c))
    }

    @Test("a stale completion takes nothing away from the new generation")
    func staleFinishDoesNotClearTheNewer() {
        var gate = OpenGate()
        let a = gate.begin(itemId: "A", restart: false)!
        _ = gate.begin(itemId: "B", restart: false)
        gate.finish(a)                       // A kehrt spaet zurueck
        // B still keeps its coalescing protection.
        #expect(gate.begin(itemId: "B", restart: false) == nil)
    }

    /// The case measured on a cold start: the mirror opens the last title
    /// without playing, the widget's command asks to play the same title
    /// while that open runs. The coalesced call's wish stays with the
    /// running open; a new open starts without it.
    @Test("a wish to play is not lost on merging, a new opening starts without it")
    func aCoalescedPlayIsKept() {
        var gate = OpenGate()
        let silent = gate.begin(itemId: "A", restart: false, autoplay: false)!
        #expect(!gate.playWasAsked(silent), "the precondition: the running open does not play")
        #expect(gate.begin(itemId: "A", restart: false, autoplay: true) == nil, "the play coalesces")
        #expect(gate.playWasAsked(silent), "the coalesced play vanished")
        let next = gate.begin(itemId: "B", restart: false, autoplay: false)!
        #expect(!gate.playWasAsked(next), "a new open inherited an old wish")
        #expect(!gate.playWasAsked(silent), "a superseded open still plays")
        #expect(gate.begin(itemId: "B", restart: false, autoplay: false) == nil)
        #expect(!gate.playWasAsked(next), "a coalesced call without play asked to play")
    }

    /// The coordinator's `open` cannot run in a unit test (its provider
    /// comes from the session), so the wiring is read: `open` hands its
    /// wish to the gate, and `start` plays on its own wish or a coalesced one.
    @Test("opening passes its wish to the gate, the start also plays on a merged one", .needsTheSources)
    func theOpenAsksTheGate() throws {
        let code = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(code.contains("openGate.begin(itemId: item.id, restart: restart, autoplay: autoplay)"),
                "the open does not hand its wish to the gate")
        #expect(code.contains("if autoplay || openGate.playWasAsked(generation) {"),
                "the start plays only on its own wish")
    }
}

/// The real open, overtaken while it asks the network: a newer open has
/// drawn its generation and set its player meanwhile. The older open used to
/// stop that player and begin its own session after the question.
@MainActor
struct OvertakenOpenTests {
    @Test("an open overtaken during its network question leaves the newer open's player as it is")
    func anOvertakenOpenTearsNothingDown() async {
        let coordinator = PlayerCoordinator(provider: MockProvider())
        let newer = "overtake-newer-\(UUID().uuidString)"
        let older = "overtake-older-\(UUID().uuidString)"
        let media = LibraryItemMedia(metadata: nil, duration: 100, chapters: nil, tracks: nil)
        var newerPlayer: PlayerViewModel?
        coordinator._testAfterNetworkQuestion = {
            coordinator._testBeginNewerOpen(itemId: newer)
            coordinator._seedActivePlayerForUITest(
                item: LibraryItem(id: newer, media: media, addedAt: nil),
                detail: LibraryItemDetail(id: newer, media: media, userMediaProgress: nil),
                chapters: [], currentChapterIndex: 0, isFallback: false, openedHere: true)
            newerPlayer = coordinator.viewModel
        }
        await Reachability.$assumed.withValue(true) {
            await coordinator.open(item: LibraryItem(id: older, media: media, addedAt: nil))
        }
        #expect(newerPlayer != nil, "the precondition: the newer open set its player")
        #expect(coordinator.viewModel === newerPlayer && coordinator.activeItem?.id == newer,
                "the overtaken open tore down the newer open's player")
        #expect(coordinator.loadError == nil, "the overtaken open said a failure over the newer one")
    }
}
#endif
