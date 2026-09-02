// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The three stages of the conflict rule, each on its own, with the
/// cases that used to go wrong under "better wins".
struct ForeignStateMergeTests {
    private func foreign(_ position: Double, finished: Bool = false,
                         at stamp: Double? = nil) -> ForeignListeningState {
        ForeignListeningState(feedURL: "https://f.example/rss", episodeGUID: nil,
                              enclosureURL: "https://f.example/1.mp3", episodeLink: nil,
                              episodeTitle: "One", position: position, finished: finished,
                              stampedAt: stamp)
    }

    @Test("(a) beide mit Zeitpunkt: der neuere gewinnt, auch mit kleinerer Position")
    func newerWinsEvenWhenBehind() {
        let local: [Double] = [900, 1_000]           // Mär: weiter, aber aelter
        let entry = ForeignStateMerge.adopt(local: local, foreign: foreign(300, at: 2_000), duration: 3_600)
        #expect(entry?.first == 300)
        #expect(entry?[1] == 2_000)
    }

    @Test("(a) beide mit Zeitpunkt: der aeltere verliert, auch mit groesserer Position")
    func olderLosesEvenWhenAhead() {
        let local: [Double] = [300, 2_000]
        #expect(ForeignStateMerge.adopt(local: local, foreign: foreign(900, at: 1_000), duration: 3_600) == nil)
    }

    @Test("(a) gleicher Zeitpunkt ist ein ehrliches Unentschieden, lokal bleibt")
    func tieKeepsLocal() {
        #expect(ForeignStateMerge.adopt(local: [300, 1_000], foreign: foreign(900, at: 1_000), duration: 3_600) == nil)
    }

    @Test("(b) ohne Zeitpunkt fuellt die Quelle nur eine Luecke")
    func withoutMomentOnlyFills() {
        #expect(ForeignStateMerge.adopt(local: [300, 1_000], foreign: foreign(900), duration: 3_600) == nil)
        let filled = ForeignStateMerge.adopt(local: nil, foreign: foreign(900), duration: 3_600)
        #expect(filled?.first == 900)
        // Und traegt KEIN „jetzt": ein Zeitpunkt von null verliert gegen
        // jeden echten spaeteren.
        #expect(filled?[1] == 0)
    }

    @Test("(c) gehoert wird nie zurueckgenommen, auch nicht von einem neueren ungehoert")
    func finishedIsNeverRetracted() {
        let local: [Double] = [3_600, 1_000]         // fertig
        #expect(ForeignStateMerge.adopt(local: local, foreign: foreign(120, at: 9_000), duration: 3_600) == nil)
        #expect(ForeignStateMerge.adopt(local: local, foreign: foreign(3_600, finished: true, at: 9_000),
                                        duration: 3_600) == nil)
    }

    @Test("gehoert ohne Dauer wird der Sentinel, nicht nichts")
    func finishedWithoutDurationIsTheSentinel() {
        let entry = ForeignStateMerge.adopt(local: nil, foreign: foreign(0, finished: true, at: 5), duration: 0)
        #expect(entry?.first == ProgressMark.playedSentinel)
    }

    @Test("ein alter Eintrag ohne Zeitpunkt zaehlt als Zeitpunkt null")
    func oneValueLocalCountsAsZeroMoment() {
        #expect(ForeignStateMerge.adopt(local: [900], foreign: foreign(300, at: 1), duration: 3_600)?.first == 300)
    }

    @Test("eine Position unter einer Sekunde ist kein Stand")
    func tinyPositionIsNothing() {
        #expect(ForeignStateMerge.adopt(local: nil, foreign: foreign(0.5, at: 1), duration: 3_600) == nil)
    }
}
#endif
