// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// Die gerechnete Frei-Grenze fuer Tonaufnahmen: aus dem AKTUELLEN Jahr,
/// nie verdrahtet, mit der Staffel im Gesetz.
struct RecordingRightsTests {

    @Test("die Grenze wandert mit dem Kalender, eine harte Jahreszahl wuerde rot")
    func theBoundaryMovesWithTheCalendar() {
        // 2026: bis 1925 gemeinfrei (100-Jahre-Frist als laengste).
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1925, currentYear: 2026))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1926, currentYear: 2026))

        // Rot-Probe, wie der Entscheid sie verlangt: im FOLGEJAHR wandert
        // die Grenze. Eine verdrahtete Jahreszahl bestuende genau diese
        // Zeile nicht.
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1926, currentYear: 2027))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1927, currentYear: 2027))
    }

    @Test("die Staffel steht in der Rechnung, nicht daneben")
    func theStepsAreInTheComputation() {
        // 1946 laeuft 100 Jahre: frei ab 2047.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1946, currentYear: 2046))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1946, currentYear: 2047))
        // 1947 laeuft 110 Jahre: frei erst ab 2058. Ohne die Staffel waere
        // es 2048, und genau dieser Abstand ist die Probe.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1947, currentYear: 2048))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1947, currentYear: 2057))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1947, currentYear: 2058))
        // 1957 bis 1972 enden alle mit 2067, als Datum und nicht als Frist.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1957, currentYear: 2067))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1957, currentYear: 2068))
        #expect(FreeCatalog.recordingIsPublicDomain(year: 1972, currentYear: 2068))
        // Danach wird hier nichts gerechnet und nichts behauptet.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 1973, currentYear: 2100))
    }

    @Test("ohne Jahr wird nie geraten, und Unsinn zaehlt nicht als Jahr")
    func withoutAYearNothingIsGuessed() {
        // Die Intake-Stelle rechnet nur, wenn `Int(prefix(4))` ein Jahr
        // ergibt; hier die Funktions-Seite: ein offensichtlicher Nicht-Wert
        // gibt nie frei.
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 0, currentYear: 2026))
        #expect(!FreeCatalog.recordingIsPublicDomain(year: 19, currentYear: 2026))
    }

    /// Auf einer Flaeche mit EINER einheitlichen Rechte-Antwort steht der
    /// Standard einmal oben; die Kachel wiederholt ihn nicht. Abweichungen
    /// zeigen weiter. Als Aufzaehlung am Bereich, nicht als Heuristik.
    @Test("die Schellack-Bereiche tragen das Einheits-Flag, Netlabels nicht")
    func theUniformFlagIsAnEnumeration() {
        #expect(ArchiveMusicCatalog.shellacAll.statesUniformRights)
        for shelf in ArchiveMusicCatalog.shellacShelves {
            #expect(shelf.statesUniformRights,
                    "\(shelf.key) wiederholt den Flaechen-Standard je Kachel")
        }
        // Rot-Probe: die gemischte Flaeche behaelt ihre Kapseln — dort
        // traegt sie Unterschiede, und ein Flag, das ueberall gilt,
        // unterdrueckte auch die.
        #expect(!ArchiveMusicCatalog.netlabels.statesUniformRights,
                "die gemischte Flaeche verliert ihre Kapseln")
    }
}
