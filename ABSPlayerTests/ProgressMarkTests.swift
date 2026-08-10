// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Der Befund vom 10.08. in Testform: „gehört" darf eine schwankende Dauer
/// überleben.
struct ProgressMarkTests {
    @Test("die gewachsene Werbe-Dauer kippt die Marke nicht mehr")
    func grownDurationNoLongerBreaksThePlayedState() {
        // Markiert bei 3.420 s, als der Feed 3.420 s meldete.
        let stored = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        // Beim nächsten Abruf steckt drei Minuten Werbung mehr drin.
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 3_600))
        // Und auch, wenn sie wieder verschwindet (zufällig, laut Doku).
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 3_300))
    }

    @Test("ein alter Eintrag ohne dritten Wert verhält sich unverändert")
    func legacyEntriesKeepTheOldRule() {
        let legacy: [Double] = [3_420, 1_000]
        #expect(ProgressMark.isPlayed(stored: legacy, currentDuration: 3_420))
        #expect(!ProgressMark.isPlayed(stored: legacy, currentDuration: 3_600),
                "das ist der alte Weg — er bleibt für Einträge, die keinen Bezug tragen")
    }

    @Test("eine halb gehörte Folge bleibt halb gehört")
    func partialStaysPartial() {
        let stored = ProgressMark.entry(position: 600, duration: 3_600, nowMs: 1_000)
        #expect(!ProgressMark.isPlayed(stored: stored, currentDuration: 3_600))
        #expect(!ProgressMark.isPlayed(stored: stored, currentDuration: 3_000))
    }

    @Test("ohne bekannte Dauer trägt weiterhin der Wächterwert")
    func sentinelStillCarriesDurationlessEpisodes() {
        let stored = ProgressMark.entry(position: ProgressMark.playedSentinel, duration: 0, nowMs: 1_000)
        #expect(stored.count == 2, "eine unbekannte Dauer wird NICHT erfunden")
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 0))
        #expect(ProgressMark.isPlayed(stored: stored, currentDuration: 99_999))
    }


    @Test("die vom Server gemeldete Dauer heilt einen bestehenden Eintrag")
    func serverTotalRepairsOldEntries() {
        // gpodder liefert Position UND total; damit ist der Bezugspunkt da,
        // ohne dass irgendetwas geraten wird.
        let fromServer = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 9_000)
        #expect(ProgressMark.isPlayed(stored: fromServer, currentDuration: 3_600),
                "nach dem naechsten Abgleich gilt die Folge wieder als gehoert")
        // Meldet der Server kein total, bleibt es beim alten Verhalten —
        // eine erfundene Dauer waere schlimmer als keine.
        let withoutTotal = ProgressMark.entry(position: 3_420, duration: 0, nowMs: 9_000)
        #expect(withoutTotal.count == 2)
    }

    @Test("nach aussen geht unveraendert die echte Endposition")
    func outwardValueIsUnchanged() {
        let stored = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        #expect(stored[0] == 3_420, "gpodder und ABS erwarten position = total")
        #expect(stored[1] == 1_000, "der Zeitstempel bleibt an zweiter Stelle — alle Merge-Regeln lesen ihn dort")
        #expect(ProgressMark.markedDuration(stored) == 3_420)
        #expect(ProgressMark.markedDuration([1, 2]) == nil)
    }
}
#endif
