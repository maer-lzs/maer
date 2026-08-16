// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// 🟡 P7: a composing surface waits for its sources — but never without end
/// on ONE of them. The measurement the order asks for runs here: a source
/// that hangs must not decide how long the start page stays empty.
struct SourceBudgetTests {
    @Test("eine haengende Quelle kostet das Budget, nicht die Seite")
    func hangingSourceIsBounded() async {
        let started = Date()
        // Die Attrappe des unerreichbaren Tiny: sie antwortet nie.
        let value = await SourceBudget.value(default: "leer") {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return "spaet"
        }
        let waited = Date().timeIntervalSince(started)
        #expect(value == "leer")
        // Gewartet wird das Budget, nicht die URLSession-Zeitgrenze (60 s+),
        // die im Geraetefall die ganze Seite leer hielt.
        #expect(waited < SourceBudget.seconds + 2)
    }

    @Test("ein SPAETES Ergebnis verfaellt nicht — es wendet sich selbst an")
    func lateResultAppliesItself() async {
        // Q3a-Messung: kuenstlich langsame Quelle (deutlich ueber dem
        // Budget) — die Flaeche rendert sofort ohne sie, und der Wert kommt
        // danach VON SELBST an (kein Tab-Wechsel, kein Nutzer-Anstoss).
        actor Late { 
            var value: String?
            func set(_ v: String) { value = v }
        }
        let late = Late()
        let started = Date()
        let immediate = await SourceBudget.value(default: "leer",
                                                 onLate: { await late.set($0) }) {
            try? await Task.sleep(for: .seconds(SourceBudget.seconds + 2))
            return "spaet"
        }
        #expect(immediate == "leer")
        #expect(Date().timeIntervalSince(started) < SourceBudget.seconds + 1.5)
        // Warten, bis die langsame Quelle geliefert hat.
        var seen: String?
        for _ in 0..<40 {
            seen = await late.value
            if seen != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(seen == "spaet")
    }

    @Test("eine antwortende Quelle wird NICHT beschnitten")
    func fastSourceIsUntouched() async {
        let value = await SourceBudget.value(default: "leer") { "da" }
        #expect(value == "da")
        // Auch die ergebnislose Form laeuft normal durch.
        await SourceBudget.run { }
    }
}
#endif
