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
/// auf dem Server — und das Flag sagte trotzdem nicht fertig. Es blieb damit
/// an erster Stelle in Weiterhoeren, obwohl es durchgehoert war.
struct FinishedQuestionTests {

    private func progress(_ fraction: Double, flag: Bool) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: flag, lastUpdate: 1.7e12)
    }

    @Test("die Zahlen entscheiden mit — ein Flag darf nicht fehlen duerfen")
    func numbersDecideToo() {
        #expect(progress(1.0, flag: false).countsAsFinished,
                "Position gleich Dauer, Flag verloren")
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
        let done = progress(1.0, flag: false)
        #expect(!ContinueSources.isStarted(serverSaysStarted: done.isStarted,
                                           flushed: nil,
                                           finished: done.countsAsFinished))
        let half = progress(0.5, flag: false)
        #expect(ContinueSources.isStarted(serverSaysStarted: half.isStarted,
                                          flushed: [120, 1.7e12],
                                          finished: half.countsAsFinished))
    }

    /// Der zweite Fall am selben Buch: dieses Geraet hatte den Endstand
    /// einmal gesendet, und dieser Zeuge wurde als begonnen gelesen.
    @Test("der Zeuge belegt den ANFANG und darf das Ende nicht ueberstimmen")
    func theWitnessCannotOutvoteTheEnd() {
        // Die gemessene Lage: Server sagt fertig, und der eigene Push steht
        // mit der vollen Dauer daneben.
        #expect(!ContinueSources.isStarted(serverSaysStarted: false,
                                           flushed: [67256, 1.7e12],
                                           finished: true),
                "ein Push ueber die ganze Dauer ist kein Grund, es weiter anzubieten")
        // Ohne Fertig-Aussage traegt der Zeuge weiterhin — dafuer ist er da.
        #expect(ContinueSources.isStarted(serverSaysStarted: false,
                                          flushed: [67256, 1.7e12],
                                          finished: false))
        // Und die Schwelle bleibt: ein Antippen ist kein begonnenes Buch.
        #expect(!ContinueSources.isStarted(serverSaysStarted: false,
                                           flushed: [5, 1.7e12],
                                           finished: false))
    }
}
#endif
