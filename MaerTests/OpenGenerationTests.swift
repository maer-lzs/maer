// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// 🔴 Play-Haemmern unter schlechtem Netz darf nie zwei Tonspuren
/// erzeugen. Jeder open() zieht eine Generation, nur die letzte gewinnt.
struct OpenGateTests {
    @Test("N schnelle Taps auf DENSELBEN Titel ⇒ genau EIN Versuch")
    func repeatedTapsCoalesce() {
        var gate = OpenGate()
        let first = gate.begin(itemId: "A", restart: false)
        #expect(first == 1)
        // Die vier weiteren Taps im Zeitfenster des haengenden Abrufs
        // koaleszieren. Kein zweiter Start.
        for _ in 0..<4 { #expect(gate.begin(itemId: "A", restart: false) == nil) }
        #expect(gate.isCurrent(first ?? 0))
    }

    @Test("ein ausdruecklicher Neustart koalesziert NICHT")
    func restartAlwaysCounts() {
        var gate = OpenGate()
        _ = gate.begin(itemId: "A", restart: false)
        #expect(gate.begin(itemId: "A", restart: true) != nil)
    }

    @Test("bei verschiedenen Titeln gewinnt die LETZTE Generation")
    func lastGenerationWins() {
        var gate = OpenGate()
        let a = gate.begin(itemId: "A", restart: false)!
        let b = gate.begin(itemId: "B", restart: false)!
        let c = gate.begin(itemId: "C", restart: false)!
        // Die alten Rueckkehrer erkennen sich als veraltet und raeumen ab.
        #expect(!gate.isCurrent(a))
        #expect(!gate.isCurrent(b))
        #expect(gate.isCurrent(c))
    }

    @Test("ein veralteter Abschluss nimmt der neuen Generation nichts weg")
    func staleFinishDoesNotClearTheNewer() {
        var gate = OpenGate()
        let a = gate.begin(itemId: "A", restart: false)!
        _ = gate.begin(itemId: "B", restart: false)
        gate.finish(a)                       // A kehrt spaet zurueck
        // B haelt seinen Koaleszenz-Schutz weiterhin.
        #expect(gate.begin(itemId: "B", restart: false) == nil)
    }

    /// The case measured on a cold start: the mirror opens the last title
    /// without playing, the widget's command asks to play the same title
    /// while that open runs. The coalesced call's wish stays with the
    /// running open; a new open starts without it.
    @Test("ein Wunsch zu spielen geht beim Zusammenlegen nicht verloren, eine neue Oeffnung beginnt ohne ihn")
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
    @Test("das Oeffnen gibt seinen Wunsch an das Tor, der Start spielt auch auf einen zusammengelegten", .needsTheSources)
    func theOpenAsksTheGate() throws {
        let code = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(code.contains("openGate.begin(itemId: item.id, restart: restart, autoplay: autoplay)"),
                "the open does not hand its wish to the gate")
        #expect(code.contains("if autoplay || openGate.playWasAsked(generation) {"),
                "the start plays only on its own wish")
    }
}
#endif
