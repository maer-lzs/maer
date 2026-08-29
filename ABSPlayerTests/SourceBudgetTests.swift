// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// 🟡 A composing surface waits for its sources, but never without end
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
        //
        // Die Grenze misst die AUSSAGE, nicht die Maschine. Mit
        // `Budget + 4` hing sie an der Last des vollen Parallel-Laufs und
        // ist an fuenf Tagen wiederholt gerissen (gemessen 8,9 bis 11,9 s
        // gegen 8 s), ohne dass je etwas an der Sache falsch war. Die
        // 60-s-Klasse diskriminiert eine weite Grenze genauso scharf: der
        // Abstand zwischen 12 und 60 traegt den Satz, der Abstand zwischen
        // 8 und 12 traegt nur die Maschine.
        #expect(waited < 30)
    }

    @Test("ein SPAETES Ergebnis verfaellt nicht — es wendet sich selbst an")
    func lateResultAppliesItself() async {
        // Q3a-Messung: kuenstlich langsame Quelle (deutlich ueber dem
        // Budget). Die Flaeche rendert sofort ohne sie, und der Wert kommt
        // danach VON SELBST an (kein Tab-Wechsel, kein Nutzer-Anstoss).
        actor Late { 
            var value: String?
            func set(_ v: String) { value = v }
        }
        let late = Late()
        let started = Date()
        let immediate = await SourceBudget.value(default: "leer",
                                                 onLate: { await late.set($0) }) {
            // Slower than the widened ceiling below. Otherwise the case
            // could no longer tell "rendered at budget" from "waited for
            // the source" (red-probe discipline).
            try? await Task.sleep(for: .seconds(SourceBudget.seconds + 6))
            return "spaet"
        }
        #expect(immediate == "leer")
        // Was hier UNTERSCHEIDET, ist der WERT eine Zeile hoeher, nicht die
        // Zeit: haette die Flaeche auf die Quelle gewartet, stuende dort
        // „spaet" statt „leer". Die Zeitgrenze ist nur noch die grobe Wache
        // gegen ein echtes Haengen, und sie misst deshalb bewusst weit
        // genug, um nicht an der Maschinenlast zu haengen.
        #expect(Date().timeIntervalSince(started) < 30)
        // Warten, bis die langsame Quelle geliefert hat (grosszuegig. Die
        // Frist kostet nur im Fehlerfall).
        var seen: String?
        for _ in 0..<80 {
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
