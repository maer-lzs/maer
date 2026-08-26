// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// 🔴 Play-Haemmern unter schlechtem Netz darf nie zwei Tonspuren
/// erzeugen — jeder open() zieht eine Generation, nur die letzte gewinnt.
struct OpenGateTests {
    @Test("N schnelle Taps auf DENSELBEN Titel ⇒ genau EIN Versuch")
    func repeatedTapsCoalesce() {
        var gate = OpenGate()
        let first = gate.begin(itemId: "A", restart: false)
        #expect(first == 1)
        // Die vier weiteren Taps im Zeitfenster des haengenden Abrufs
        // koaleszieren — kein zweiter Start.
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
}
#endif
