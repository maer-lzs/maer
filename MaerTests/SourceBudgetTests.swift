// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// 🟡 A composing surface waits for its sources, but never without end
/// on ONE of them. The measurement the order asks for runs here: a source
/// that hangs must not decide how long the start page stays empty.
struct SourceBudgetTests {
    /// A short budget for the witnesses. What they tell apart is the value
    /// that arrives (the fallback or the source's), and that holds for any
    /// budget; the app's own four seconds would only make them wait.
    static let budget = 0.3
    /// The stubs stand at fixed multiples of the budget, so the distance
    /// that tells the cases apart grows and shrinks with it: a hanging
    /// source answers far beyond any case, a late one at three budgets.
    static let hanging = budget * 200
    static let late = budget * 3

    @Test("eine haengende Quelle kostet das Budget, nicht die Seite")
    func hangingSourceIsBounded() async {
        let started = Date()
        // Die Attrappe des unerreichbaren Tiny: sie antwortet nie.
        let value = await SourceBudget.value(default: "leer", budget: Self.budget) {
            try? await Task.sleep(for: .seconds(Self.hanging))
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
        #expect(waited < Self.hanging / 2)
    }

    @Test("ein SPAETES Ergebnis verfaellt nicht — es wendet sich selbst an")
    func lateResultAppliesItself() async {
        // Messung: kuenstlich langsame Quelle (deutlich ueber dem
        // Budget). Die Flaeche rendert sofort ohne sie, und der Wert kommt
        // danach VON SELBST an (kein Tab-Wechsel, kein Nutzer-Anstoss).
        actor Late { 
            var value: String?
            func set(_ v: String) { value = v }
        }
        let late = Late()
        let started = Date()
        let immediate = await SourceBudget.value(default: "leer", budget: Self.budget,
                                                 onLate: { await late.set($0) }) {
            // Well past the budget, so the immediate value tells "rendered
            // at budget" from "waited for the source" (red-probe discipline).
            try? await Task.sleep(for: .seconds(Self.late))
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

    /// The forms of `budget:` the seam itself writes: its two declarations
    /// and the one hand-through.
    nonisolated static let seamForms = ["budget: Double = seconds,", "budget: Double = SourceBudget.seconds,",
                                        "budget: budget,"]

    /// Every `budget:` in a file that speaks to the surface budget, apart
    /// from the seam's own forms: a caller that sets its own budget.
    nonisolated static func ownBudgets(in text: String) -> Int {
        let code = SyncContractFenceTests.stripped(text)
        guard code.contains("SourceBudget") || code.contains("ListenAgainFetch") else { return 0 }
        return code.split(separator: "\n").reduce(0) { count, line in
            var rest = String(line)
            for form in seamForms { rest = rest.replacingOccurrences(of: form, with: "") }
            return count + rest.components(separatedBy: "budget:").count - 1
        }
    }

    @Test("die App wartet ueberall dasselbe Budget, nur die Zeugen kuerzen es", .needsTheSources)
    func theAppKeepsOneBudget() {
        let files = ProjectFileIntegrityTests.sourceTexts()
        #expect(files.contains { $0.text.contains("SourceBudget.value(") }, "der Zaun hat keinen Rufer des Budgets gelesen")
        let found = files.filter { Self.ownBudgets(in: $0.text) > 0 }.map(\.name)
        #expect(found.isEmpty, "eine eigene Frist in der App: \(found)")
        #expect(Self.ownBudgets(in: "func f() async { _ = await SourceBudget.value(default: 0,\n  budget: 1) { 2 } }") == 1,
                "der Zaehler sieht eine eigene Frist auch ueber einen Umbruch")
        #expect(Self.ownBudgets(in: "func f() async { await ListenAgainFetch.shared.fetch(ids, budget: 9, onLate: g) { _ in true } }") == 1)
        #expect(Self.ownBudgets(in: "static func value(budget: Double = seconds,\n x: Int) { SourceBudget.run { } }") == 0,
                "die Deklaration der Naht ist keine eigene Frist")
        #expect(Self.ownBudgets(in: "func lookup(uuids: [String], budget: Int) {}") == 0,
                "eine Datei ohne das Budget der Flaechen zaehlt nicht")
    }
}
#endif
