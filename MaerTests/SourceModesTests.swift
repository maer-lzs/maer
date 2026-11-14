// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "Everything that can do several things should be able to do them at the
/// same time." The step from one stored answer to two must not cost anyone a
/// single tap. That is the part worth testing.
struct SourceModesTests {

    @Test("the old stock reads as one mode on, the other off")
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

    @Test("one mode behaves as today: nothing to assign, no jump")
    func oneModeBehavesAsBefore() {
        let musicOnly = SourceModes(servesMusic: true, servesAudiobooks: false)
        let booksOnly = SourceModes(servesMusic: false, servesAudiobooks: true)
        for modes in [musicOnly, booksOnly] {
            #expect(modes.count == 1)
            #expect(!modes.needsLibraryAssignment,
                    "wer nur einen Modus nutzt, darf keine Zuordnungs-Flaeche sehen")
        }
        // And the way back is lossless as long as it is ONE mode.
        #expect(SourceModes.fromLegacyContentType(musicOnly.legacyContentType) == musicOnly)
        #expect(SourceModes.fromLegacyContentType(booksOnly.legacyContentType) == booksOnly)
    }

    @Test("two modes need the assignment: visibly incomplete, never empty")
    func twoModesNeedTheAssignment() {
        let both = SourceModes(servesMusic: true, servesAudiobooks: true)
        #expect(both.count == 2)
        #expect(both.needsLibraryAssignment,
                "G8: ein zweiter Modus ohne Zuordnung muss sich als unvollstaendig zeigen")
    }

    @Test("no mode is a state of its own, no fallback to music")
    func noModeIsItsOwnState() {
        let none = SourceModes(servesMusic: false, servesAudiobooks: false)
        #expect(none.isEmpty)
        #expect(none.count == 0)
        #expect(!none.needsLibraryAssignment, "nichts zugeordnet, nichts zuzuordnen")
    }

    /// The old value cannot express the empty state: whoever reads it anyway
    /// gets a mode. The silent opposite of the input.
    @Test("both off means: feeds nothing, not music")
    func emptyMeansNothingNotMusic() {
        let none = SourceModes(servesMusic: false, servesAudiobooks: false)
        // The old value would LIE here, so it is not asked for this state.
        // The activation answers it.
        #expect(none.legacyContentType == "music")
        #expect(none.isEmpty, "genau daran erkennt die Aktivierung den Fall")

        let suite = UserDefaults(suiteName: "subsonic-modes-\(UUID().uuidString)")!
        suite.set("music", forKey: AppStorageKeys.subsonicContentType)
        // The derivation itself stays unchanged: a stored value IS a mode.
        // The empty state arises only from the input.
        #expect(SourceModes.fromLegacyContentType(
            suite.string(forKey: AppStorageKeys.subsonicContentType)).servesMusic)
    }
}
#endif
