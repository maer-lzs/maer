// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

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

    /// Keine Kachel traegt eine Rechte-Kapsel, auch nicht bei Netlabels:
    /// der Hinweis des Archivs steht einmal oben auf jeder archive.org-Flaeche,
    /// die Angabe je Titel auf der Detailseite.
    @Test("keine Kachel traegt eine Rechte-Kapsel, jede archive.org-Flaeche den einen Hinweis", .needsTheSources)
    func noTileCarriesARightsCapsule() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let tile = try source("Sources/Views/FeedArtwork.swift")
        #expect(!tile.contains("badgeText"), "the catalog tile carries a capsule again")
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            #expect(!code.contains("badgeText: entry.ccLicense") && !code.contains("hidesUnstatedRights"),
                    "\(name) puts a rights capsule on a tile")
        }
        // The notice tops every archive.org surface: the area page (netlabels
        // and shellac), the shellac surface, Old Time Radio and the archive books.
        #expect(try source("Sources/Views/Music/ArchiveMusicPages.swift")
            .components(separatedBy: "ArchiveRightsNote()").count - 1 == 2)
        #expect(try source("Sources/Views/CatalogSourcePage.swift")
            .contains("if source == .oldTimeRadio || source == .archiveBooks {\n                ArchiveRightsNote()"))
    }
}
