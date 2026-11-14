// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The finished question, answered in ONE place.
///
/// The case that forced it: a book stood at 18:40:56 of 18:40:56
/// on the server. And the flag still did not say finished. So it stayed
/// in first place in Continue Listening, although it had been heard through.
struct FinishedQuestionTests {

    private func progress(_ fraction: Double, flag: Bool) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: flag, lastUpdate: 1.7e12)
    }

    @Test("the numbers decide too: a flag must not be allowed to be absent")
    func numbersDecideToo() {
        #expect(progress(1.0, flag: false).countsAsFinished,
                "Position gleich Dauer, Flag verloren")
        #expect(progress(1.0, flag: true).countsAsFinished)
        #expect(progress(0.5, flag: true).countsAsFinished,
                "ein gesetztes Flag gilt weiter, auch mitten im Buch")
    }

    @Test("the threshold is called COMPLETE, not almost")
    func thresholdMeansComplete() {
        #expect(!progress(0.99, flag: false).countsAsFinished,
                "ein 20-Stunden-Buch hat bei 99 % noch zwoelf Minuten")
        #expect(!progress(0.998, flag: false).countsAsFinished)
        #expect(progress(0.9999, flag: false).countsAsFinished, "nur Float-Rauschen")
    }

    @Test("finished no longer means begun: the row loses it as a result")
    func finishedIsNotStarted() {
        #expect(!progress(1.0, flag: false).isStarted,
                "das ist der Grund, warum es aus Weiterhoeren faellt")
        #expect(progress(0.5, flag: false).isStarted)
        #expect(!progress(0.0, flag: false).isStarted)
    }

    @Test("the Continue Listening rule asks the same answer")
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

    /// The second case on the same book: this device had sent the final
    /// state once, and this witness was read as begun.
    @Test("the witness proves the BEGINNING and must not overrule the end")
    func theWitnessCannotOutvoteTheEnd() {
        // The measured situation: the server says finished, and the own push stands
        // beside it with the full duration.
        #expect(!ContinueSources.isStarted(serverSaysStarted: false,
                                           flushed: [67256, 1.7e12],
                                           finished: true),
                "ein Push ueber die ganze Dauer ist kein Grund, es weiter anzubieten")
        // Without a finished statement the witness still carries. That is what it is there for.
        #expect(ContinueSources.isStarted(serverSaysStarted: false,
                                          flushed: [67256, 1.7e12],
                                          finished: false))
        // And the threshold stays: a tap is not a begun book.
        #expect(!ContinueSources.isStarted(serverSaysStarted: false,
                                           flushed: [5, 1.7e12],
                                           finished: false))
    }
}
#endif
