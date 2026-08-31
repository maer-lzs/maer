// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Eine Gehört-Marke muss eine schwankende Dauer überleben.
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




    @Test("die EINE Zustands-Entscheidung — Listen und Store urteilen gleich")
    func stateIsTheSameEverywhere() {
        // Markiert bei 3.420, Feed meldet heute 3.600. Die Nachbildung in
        // den Listen zeigte wieder eine Restzeit.
        let healed = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        #expect(ProgressMark.state(stored: healed, currentDuration: 3_600) == .played)
        // Halb gehoert bleibt halb gehoert, mit Restzeit gegen die HEUTIGE Dauer.
        let half = ProgressMark.entry(position: 600, duration: 3_600, nowMs: 1_000)
        #expect(ProgressMark.state(stored: half, currentDuration: 3_600)
                == .inProgress(fraction: 600.0 / 3_600.0, remaining: 3_000))
        #expect(ProgressMark.state(stored: nil, currentDuration: 3_600) == .unplayed)
        #expect(ProgressMark.state(stored: [0, 1_000], currentDuration: 3_600) == .unplayed,
                "der Grabstein liest sich als ungehoert")
    }

    @Test("der Zeitstempel wird benannt gelesen, nicht als letztes Element")
    func timestampIsReadByName() {
        #expect(ProgressMark.timestamp([3_420, 1_700_000_000_000, 3_420]) == 1_700_000_000_000)
        #expect(ProgressMark.timestamp([3_420, 1_700_000_000_000]) == 1_700_000_000_000)
        #expect(ProgressMark.timestamp([3_420]) == nil)
        #expect(ProgressMark.timestamp(nil) == nil)
    }

    @Test("ein Eintrag ohne Dauer loescht den vorhandenen Bezugspunkt NICHT")
    func advancingCarriesTheReferencePoint() {
        let good = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 1_000)
        // Der gpodder-Pull ohne `total`. Vorher entstand hier eine
        // Zwei-Werte-Marke, die die gute ueberschrieb.
        let advanced = ProgressMark.advancing(good, position: 3_420, duration: 0, nowMs: 2_000)
        #expect(ProgressMark.markedDuration(advanced) == 3_420)
        #expect(advanced[1] == 2_000, "Position und Zeitstempel kommen weiterhin von der Quelle")
        #expect(ProgressMark.isPlayed(stored: advanced, currentDuration: 3_600))
        // Eine BEKANNTE neue Dauer gewinnt gegen die alte.
        let fresher = ProgressMark.advancing(good, position: 3_500, duration: 3_500, nowMs: 3_000)
        #expect(ProgressMark.markedDuration(fresher) == 3_500)
        // Ohne Vorgaenger bleibt es beim alten Verhalten.
        #expect(ProgressMark.advancing(nil, position: 10, duration: 0, nowMs: 1).count == 2)
    }

    @Test("Nachtragen ergaenzt nur die Dauer — und erfindet nie einen Eintrag")
    func supplementingOnlyAddsTheMissingReference() {
        let old: [Double] = [3_420, 1_000]
        let healed = ProgressMark.supplementing(old, duration: 3_420)
        #expect(healed == [3_420, 1_000, 3_420], "Position und Zeitstempel bleiben unangetastet")
        // Nichts zu tun: hat schon einen Bezugspunkt …
        #expect(ProgressMark.supplementing([3_420, 1_000, 3_420], duration: 3_600) == nil)
        // … oder die Gegenseite kennt keine Dauer.
        #expect(ProgressMark.supplementing(old, duration: 0) == nil)
    }

    @Test("die vom Server gemeldete Dauer heilt einen bestehenden Eintrag")
    func serverTotalRepairsOldEntries() {
        // gpodder liefert Position UND total; damit ist der Bezugspunkt da,
        // ohne dass irgendetwas geraten wird.
        let fromServer = ProgressMark.entry(position: 3_420, duration: 3_420, nowMs: 9_000)
        #expect(ProgressMark.isPlayed(stored: fromServer, currentDuration: 3_600),
                "nach dem naechsten Abgleich gilt die Folge wieder als gehoert")
        // Meldet der Server kein total, bleibt es beim alten Verhalten.
        // Eine erfundene Dauer waere schlimmer als keine.
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
