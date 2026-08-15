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

    @Test("eine antwortende Quelle wird NICHT beschnitten")
    func fastSourceIsUntouched() async {
        let value = await SourceBudget.value(default: "leer") { "da" }
        #expect(value == "da")
        // Auch die ergebnislose Form laeuft normal durch.
        await SourceBudget.run { }
    }
}
#endif
