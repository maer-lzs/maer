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

    @Test("a hanging source costs the budget, not the page")
    func hangingSourceIsBounded() async {
        let started = Date()
        // The stub of the unreachable Tiny: it never answers.
        let value = await SourceBudget.value(default: "leer", budget: Self.budget) {
            try? await Task.sleep(for: .seconds(Self.hanging))
            return "spaet"
        }
        let waited = Date().timeIntervalSince(started)
        #expect(value == "leer")
        // The budget is waited, not the URLSession time limit (60 s+),
        // which on the device held the whole page empty.
        //
        // The limit measures the STATEMENT, not the machine. With
        // `Budget + 4` it hung on the load of the full parallel run and
        // broke repeatedly over five days (measured 8.9 to 11.9 s
        // against 8 s), without anything ever being wrong with the thing. The
        // 60-s class discriminates a wide limit just as sharply: the
        // distance between 12 and 60 carries the sentence, the distance between
        // 8 and 12 carries only the machine.
        #expect(waited < Self.hanging / 2)
    }

    @Test("a LATE result does not lapse: it applies itself")
    func lateResultAppliesItself() async {
        // Measurement: artificially slow source (well over the
        // budget). The surface renders at once without it, and the value
        // arrives afterwards BY ITSELF (no tab change, no user nudge).
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
        // What DISTINGUISHES here is the VALUE one line up, not the
        // time: had the surface waited for the source, there would stand
        // „spaet" instead of „leer". The time limit is only the coarse guard
        // against a real hang, and so it deliberately measures wide
        // enough not to depend on the machine load.
        #expect(Date().timeIntervalSince(started) < 30)
        // Wait until the slow source has delivered (generous. The
        // deadline costs only in the failure case).
        var seen: String?
        for _ in 0..<80 {
            seen = await late.value
            if seen != nil { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        #expect(seen == "spaet")
    }

    @Test("an answering source is NOT cut off")
    func fastSourceIsUntouched() async {
        let value = await SourceBudget.value(default: "leer") { "da" }
        #expect(value == "da")
        // The form without a result also runs through normally.
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

    @Test("the app waits the same budget everywhere, only the witnesses shorten it", .needsTheSources)
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
