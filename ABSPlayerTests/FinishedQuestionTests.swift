// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Die Fertig-Frage, an EINER Stelle beantwortet.
///
/// Der Fall, der sie erzwungen hat: ein Buch stand mit 18:40:56 von 18:40:56
/// auf dem Server — und das Flag sagte trotzdem „nicht fertig". Es blieb damit
/// an erster Stelle in Weiterhoeren, obwohl es durchgehoert war.
struct FinishedQuestionTests {

    private func progress(_ fraction: Double, flag: Bool) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: flag, lastUpdate: 1.7e12)
    }

    @Test("die Zahlen entscheiden mit — ein Flag darf nicht fehlen duerfen")
    func numbersDecideToo() {
        #expect(progress(1.0, flag: false).countsAsFinished,
                "Position gleich Dauer, Flag verloren — genau the owner's Fall")
        #expect(progress(1.0, flag: true).countsAsFinished)
        #expect(progress(0.5, flag: true).countsAsFinished,
                "ein gesetztes Flag gilt weiter, auch mitten im Buch")
    }

    @Test("die Schwelle heisst VOLLSTAENDIG, nicht fast")
    func thresholdMeansComplete() {
        #expect(!progress(0.99, flag: false).countsAsFinished,
                "ein 20-Stunden-Buch hat bei 99 % noch zwoelf Minuten")
        #expect(!progress(0.998, flag: false).countsAsFinished)
        #expect(progress(0.9999, flag: false).countsAsFinished, "nur Float-Rauschen")
    }

    @Test("fertig heisst nicht mehr begonnen — die Reihe verliert es damit")
    func finishedIsNotStarted() {
        #expect(!progress(1.0, flag: false).isStarted,
                "das ist der Grund, warum es aus Weiterhoeren faellt")
        #expect(progress(0.5, flag: false).isStarted)
        #expect(!progress(0.0, flag: false).isStarted)
    }

    @Test("die Weiterhoeren-Regel fragt dieselbe Antwort")
    func continueRowAsksTheSameAnswer() {
        // `ContinueSources.isStarted` bekommt `serverSaysStarted` aus
        // `BookProgress.isStarted` — die Kette muss also durchschlagen.
        #expect(!ContinueSources.isStarted(
            serverSaysStarted: progress(1.0, flag: false).isStarted,
            flushed: nil))
        // Ein geflushter Zeuge macht daraus KEIN begonnen zurueck, wenn die
        // Zahlen fertig sagen — der Zeuge belegt nur den Start, nicht das Ende.
        #expect(ContinueSources.isStarted(
            serverSaysStarted: progress(0.5, flag: false).isStarted,
            flushed: [120, 1.7e12]))
    }
}
#endif
