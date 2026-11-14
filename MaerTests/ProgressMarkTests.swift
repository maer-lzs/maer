// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A heard mark must survive a fluctuating duration.
struct ProgressMarkTests {
    /// The five-second tick compares the PHASE before and after
    /// writing. Ten ticks in the middle of an episode are a single
    /// change (unheard to started), not ten; the whole state
    /// carries the position and would be new every time.
    @Test("ten ticks in an episode are one phase change, not ten")
    func tenTicksInProgressChangeThePhaseOnce() {
        var stored: [Double]? = nil
        var phaseChanges = 0
        var stateChanges = 0
        for tick in 1...10 {
            let position = Double(tick) * 5
            let next = ProgressMark.advancing(stored, position: position, duration: 1_800,
                                              nowMs: Double(tick) * 5_000)
            let before = ProgressMark.state(stored: stored, currentDuration: 1_800, tail: 0)
            let after = ProgressMark.state(stored: next, currentDuration: 1_800, tail: 0)
            if after.phase != before.phase { phaseChanges += 1 }
            if after != before { stateChanges += 1 }
            stored = next
        }
        #expect(phaseChanges == 1, "die Phase kippt einmal von ungehoert auf angefangen")
        // Red probe on the instrument: the whole state would have reported
        // every tick, and that was exactly the endless run of the podcast surface.
        #expect(stateChanges == 10)
        // And the heard line is still a change.
        let end = ProgressMark.advancing(stored, position: 1_800, duration: 1_800, nowMs: 60_000)
        #expect(ProgressMark.state(stored: end, currentDuration: 1_800, tail: 0).phase == .played)
    }

    @Test("the grown ad duration no longer flips the mark")
    func grownDurationNoLongerBreaksThePlayedState() {
        // Marked at 3.420 s, when the feed reported 3.420 s.
        let stored = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        // At the next fetch, three more minutes of ads are in it.
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 3_600, tail: 0))
        // And also when it disappears again (randomly, per the docs).
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 3_300, tail: 0))
    }

    @Test("an old entry without a third value behaves unchanged")
    func legacyEntriesKeepTheOldRule() {
        let legacy: [Double] = [3_420, 1_000]
        #expect(ProgressMark.isPlayed(stored: legacy, currentDuration: 3_420, tail: 0))
        #expect(!ProgressMark.isPlayed(stored: legacy, currentDuration: 3_600, tail: 0),
                "das ist der alte Weg — er bleibt für Einträge, die keinen Bezug tragen")
    }

    @Test("a half-heard episode stays half heard")
    func partialStaysPartial() {
        let stored = ProgressMark.entry(position: 600, duration: 3_600, nowMs: 1_000)
        #expect(!ProgressMark.isPlayed(stored: stored, currentDuration: 3_600, tail: 0))
        #expect(!ProgressMark.isPlayed(stored: stored, currentDuration: 3_000, tail: 0))
    }

    @Test("without a known duration the sentinel value still carries")
    func sentinelStillCarriesDurationlessEpisodes() {
        let stored = ProgressMark.entry(position: ProgressMark.playedSentinel, duration: 0, nowMs: 1_000)
        #expect(stored.count == 2, "eine unbekannte Dauer wird NICHT erfunden")
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 0, tail: 0))
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 99_999, tail: 0))
    }




    @Test("the ONE state decision: lists and store judge the same")
    func stateIsTheSameEverywhere() {
        // Marked at 3.420, feed reports 3.600 today. The imitation in
        // the lists showed a remaining time again.
        let healed = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        #expect(ProgressMark.state(stored: healed, currentDuration: 3_600, tail: 0) == .played)
        // Half heard stays half heard, with remaining time against TODAY's duration.
        let half = ProgressMark.entry(position: 600, duration: 3_600, nowMs: 1_000)
        #expect(ProgressMark.state(stored: half, currentDuration: 3_600, tail: 0)
                == .inProgress(fraction: 600.0 / 3_600.0, remaining: 3_000))
        #expect(ProgressMark.state(stored: nil, currentDuration: 3_600, tail: 0) == .unplayed)
        #expect(ProgressMark.state(stored: [0, 1_000], currentDuration: 3_600, tail: 0) == .unplayed,
                "der Grabstein liest sich als ungehoert")
    }

    @Test("the timestamp is read by name, not as the last element")
    func timestampIsReadByName() {
        #expect(ProgressMark.timestamp([3_420, 1_700_000_000_000, 3_420]) == 1_700_000_000_000)
        #expect(ProgressMark.timestamp([3_420, 1_700_000_000_000]) == 1_700_000_000_000)
        #expect(ProgressMark.timestamp([3_420]) == nil)
        #expect(ProgressMark.timestamp(nil) == nil)
    }

    @Test("an entry without a duration does NOT delete the existing reference point")
    func advancingCarriesTheReferencePoint() {
        let good = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        // The gpodder pull without `total`. Before, a
        // two-value mark arose here that overwrote the good one.
        let advanced = ProgressMark.advancing(good, position: 3_420, duration: 0, nowMs: 2_000)
        #expect(ProgressMark.markedDuration(advanced) == 3_420)
        #expect(advanced[1] == 2_000, "Position und Zeitstempel kommen weiterhin von der Quelle")
        #expect(ProgressMark.isPlayed(stored: advanced, currentDuration: 3_600, tail: 0))
        // A KNOWN new duration wins against the old one.
        let fresher = ProgressMark.advancing(good, position: 3_500, duration: 3_500, nowMs: 3_000)
        #expect(ProgressMark.markedDuration(fresher) == 3_500)
        // Without a predecessor the old behavior stays.
        #expect(ProgressMark.advancing(nil, position: 10, duration: 0, nowMs: 1).count == 2)
    }

    @Test("Backfilling adds only the duration, and never invents an entry")
    func supplementingOnlyAddsTheMissingReference() {
        let old: [Double] = [3_420, 1_000]
        let healed = ProgressMark.supplementing(old, duration: 3_420)
        #expect(healed == [3_420, 1_000, 3_420], "Position und Zeitstempel bleiben unangetastet")
        // Nothing to do: already has a reference point …
        #expect(ProgressMark.supplementing([3_420, 1_000, 3_420], duration: 3_600) == nil)
        // … or the other side knows no duration.
        #expect(ProgressMark.supplementing(old, duration: 0) == nil)
    }

    @Test("the duration reported by the server heals an existing entry")
    func serverTotalRepairsOldEntries() {
        // gpodder delivers position AND total; so the reference point is there,
        // without anything being guessed.
        let fromServer = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 9_000)
        #expect(ProgressMark.isPlayed(stored: fromServer, currentDuration: 3_600, tail: 0),
                "nach dem naechsten Abgleich gilt die Folge wieder als gehoert")
        // If the server reports no total, the old behavior stays.
        // An invented duration would be worse than none.
        let withoutTotal = ProgressMark.entry(position: 3_420, duration: 0, nowMs: 9_000)
        #expect(withoutTotal.count == 2)
    }

    @Test("outward, the real end position goes unchanged")
    func outwardValueIsUnchanged() {
        let stored = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        #expect(stored[0] == 3_420, "gpodder und ABS erwarten position = total")
        #expect(stored[1] == 1_000, "der Zeitstempel bleibt an zweiter Stelle — alle Merge-Regeln lesen ihn dort")
        #expect(ProgressMark.markedDuration(stored) == 3_420)
        #expect(ProgressMark.markedDuration([1, 2]) == nil)
    }
}
#endif
