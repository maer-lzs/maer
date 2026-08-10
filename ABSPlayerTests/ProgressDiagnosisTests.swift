// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Das Messinstrument zum Befund „gehört kippt zurück": Es muss die beiden
/// Ursachen TRENNEN, nicht eine davon nahelegen.
struct ProgressDiagnosisTests {
    private func entry(position: Double, updatedAt: Double, duration: Double) -> ProgressDiagnosis.Entry {
        .init(title: "Folge 26", guid: "rss:x:26", position: position,
              updatedAt: updatedAt, feedDuration: duration)
    }

    @Test("eine gewachsene Dauer lässt die Marke fallen — genau das Bild aus dem Befund")
    func grownDurationShowsAsInProgress() {
        // Als gehört markiert bei 3.420 s; der Feed meldet heute drei Minuten mehr.
        let e = entry(position: 3_420, updatedAt: 1_000, duration: 3_600)
        #expect(ProgressDiagnosis.verdict(e) == .inProgress(remaining: 180))
        // Und mit der damaligen Dauer wäre es „gehört" gewesen.
        #expect(ProgressDiagnosis.verdict(entry(position: 3_420, updatedAt: 1_000, duration: 3_420)) == .played)
    }

    @Test("der Zeitstempel trennt die beiden Thesen — das ist der ganze Zweck")
    func timestampSeparatesTheCauses() {
        let sync: Double = 10_000
        // Lange vor dem Abgleich geschrieben: niemand hat angefasst.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 5_000, duration: 60),
                                        lastSync: sync) == .olderThanSync)
        // Zum Abgleich geschrieben: etwas hat überschrieben.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 10_030, duration: 60),
                                        lastSync: sync) == .writtenBySync)
        // Danach geschrieben: die eigene Hand.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 20_000, duration: 60),
                                        lastSync: sync) == .newerThanSync)
        // Ohne bekannten Abgleich wird NICHTS behauptet.
        #expect(ProgressDiagnosis.trace(entry(position: 1, updatedAt: 20_000, duration: 60),
                                        lastSync: nil) == .noSyncKnown)
    }

    @Test("der Bericht nennt Position, heutige Dauer, Zeitstempel und seine Deutung")
    func reportCarriesTheDecidingValues() {
        let text = ProgressDiagnosis.report(
            show: "The Rest Is History",
            entries: [entry(position: 3_420, updatedAt: 5_000, duration: 3_600)],
            lastSync: 10_000, now: 20_000,
            format: { String(Int($0)) })
        #expect(text.contains("3420"))
        #expect(text.contains("3600"))
        #expect(text.contains("Dauer-These"), "die Deutung des Zeitstempels muss dastehen")
        #expect(text.contains("rss:x:26"))
    }

    @Test("ohne gespeicherte Positionen sagt der Bericht das, statt leer zu sein")
    func emptyIsStated() {
        let text = ProgressDiagnosis.report(show: "Leer", entries: [], lastSync: nil,
                                            now: 0, format: { String(Int($0)) })
        #expect(text.contains("Keine gespeicherten Positionen"))
    }
}
#endif
