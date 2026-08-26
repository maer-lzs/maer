// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// "Everything that can do several things should be able to do them at the
/// same time." The step from one stored answer to two must not cost anyone a
/// single tap. That is the part worth testing.
struct SourceModesTests {

    @Test("der Altbestand liest sich als ein Modus an, der andere aus")
    func legacyReadsAsOneModeOn() {
        // The three states a stock can be in. Including "never touched".
        #expect(SourceModes.fromLegacyContentType("audiobooks")
                == SourceModes(servesMusic: false, servesAudiobooks: true))
        #expect(SourceModes.fromLegacyContentType("music")
                == SourceModes(servesMusic: true, servesAudiobooks: false))
        #expect(SourceModes.fromLegacyContentType(nil)
                == SourceModes(servesMusic: true, servesAudiobooks: false),
                "ein nie angefasster Bestand muss Musik bedeuten, wie bisher")
    }

    @Test("ein Modus verhaelt sich wie heute — nichts zuzuordnen, kein Sprung")
    func oneModeBehavesAsBefore() {
        let musicOnly = SourceModes(servesMusic: true, servesAudiobooks: false)
        let booksOnly = SourceModes(servesMusic: false, servesAudiobooks: true)
        for modes in [musicOnly, booksOnly] {
            #expect(modes.count == 1)
            #expect(!modes.needsLibraryAssignment,
                    "wer nur einen Modus nutzt, darf keine Zuordnungs-Flaeche sehen")
        }
        // Und der Rückweg ist verlustfrei, solange es EIN Modus ist.
        #expect(SourceModes.fromLegacyContentType(musicOnly.legacyContentType) == musicOnly)
        #expect(SourceModes.fromLegacyContentType(booksOnly.legacyContentType) == booksOnly)
    }

    @Test("zwei Modi brauchen die Zuordnung — sichtbar unvollstaendig, nie leer")
    func twoModesNeedTheAssignment() {
        let both = SourceModes(servesMusic: true, servesAudiobooks: true)
        #expect(both.count == 2)
        #expect(both.needsLibraryAssignment,
                "G8: ein zweiter Modus ohne Zuordnung muss sich als unvollstaendig zeigen")
    }

    @Test("kein Modus ist ein eigener Zustand, kein Rueckfall auf Musik")
    func noModeIsItsOwnState() {
        let none = SourceModes(servesMusic: false, servesAudiobooks: false)
        #expect(none.isEmpty)
        #expect(none.count == 0)
        #expect(!none.needsLibraryAssignment, "nichts zugeordnet, nichts zuzuordnen")
    }

    /// Der Alt-Wert kann den Leer-Zustand nicht ausdruecken: wer ihn trotzdem
    /// liest, bekommt einen Modus. Das stille Gegenteil der Eingabe.
    @Test("beide aus heisst: speist nichts, nicht Musik")
    func emptyMeansNothingNotMusic() {
        let none = SourceModes(servesMusic: false, servesAudiobooks: false)
        // Der Alt-Wert LUEGE hier, deshalb wird er fuer diesen Zustand nicht
        // befragt. Die Aktivierung beantwortet ihn.
        #expect(none.legacyContentType == "music")
        #expect(none.isEmpty, "genau daran erkennt die Aktivierung den Fall")

        let suite = UserDefaults(suiteName: "subsonic-modes-\(UUID().uuidString)")!
        suite.set("music", forKey: AppStorageKeys.subsonicContentType)
        // Die Ableitung selbst bleibt unveraendert: ein gespeicherter Wert
        // IST ein Modus. Der Leer-Zustand entsteht nur durch die Eingabe.
        #expect(SourceModes.fromLegacyContentType(
            suite.string(forKey: AppStorageKeys.subsonicContentType)).servesMusic)
    }
}
#endif
