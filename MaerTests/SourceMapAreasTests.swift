// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The areas list must be COMPLETE. Free music steered a visible
/// surface for months while its switch existed only under network services
/// (a different question: privacy per service, not presence of an area), so
/// the list looked complete and was not. A source-scan fence instead of a
/// house rule: every `FreeCatalog.Area` has to appear in the areas section,
/// and the section may not carry a switch the enumeration does not know.
struct SourceMapAreasTests {

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Der Rueckweg zur Onboarding-Karte ist kein eigener Weg, sondern
    /// EINE Komponente an zwei Tueren: der Einrichtungsbildschirm und die
    /// Quellen-Uebersicht in den Einstellungen. Wer die Karte einmal
    /// weggetippt hat, findet sie darum ohne eine zweite Route.
    ///
    /// Ohne diesen Fall koennte eine der beiden Seiten sich eine eigene
    /// Fassung bauen, und der Rueckweg fuehrte auf etwas anderes als die
    /// Karte von damals.
    @Test("Einrichtung und Einstellungen erreichen DIESELBE Karte")
    func bothDoorsReachTheSameCard() throws {
        for tuer in ["Sources/Views/SetupView.swift", "Sources/Views/SettingsView.swift"] {
            let text = try sourceText(tuer)
            #expect(text.contains("SourceMapCard("),
                    "\(tuer) zeichnet die Karte nicht mehr")
        }
        // Rot-Probe am Instrument: die Karte gibt es genau EINMAL. Zwei
        // Definitionen waeren zwei Wahrheiten, und der Zaun oben saehe es
        // nicht, weil beide Tueren weiter „SourceMapCard(" enthielten.
        let karte = try sourceText("Sources/Views/SourceMapCard.swift")
        #expect(karte.contains("struct SourceMapCard: View"))
        for andere in ["Sources/Views/SetupView.swift", "Sources/Views/SettingsView.swift"] {
            #expect(!(try sourceText(andere)).contains("struct SourceMapCard"),
                    "\(andere) baut sich eine eigene Karte")
        }
    }

    /// GEWANDERT mit dem Zwei-Fragen-Neubau: die Bereichs-Schalter leben
    /// als REIHEN auf der Reihen-Seite. Die Vollstaendigkeits-Aussage gilt
    /// weiter (Freie Musik steuerte monatelang eine Flaeche ohne Schalter
    /// in der Liste) und haelt jetzt die Bereichs-Aufzaehlung gegen die
    /// Reihen-Aufzaehlung: jeder Katalog-Bereich hat seine abschaltbare
    /// Reihe.
    @Test("every catalog area resolves to a toggleable row")
    func everyAreaHasItsRow() throws {
        for area in FreeCatalog.Area.allCases {
            let row = AppRows.row(key: area.rowKey)
            #expect(row != nil,
                    "area \(area.rawValue) has no row in the rows enumeration")
            #expect(row?.toggleable == true,
                    "area \(area.rawValue) has a row without a switch")
        }
    }

    /// Die Karte traegt KEINEN Bereichs-Schalter mehr — ein einzelner
    /// zurueckgekehrter Schalter schriebe an der Aufraeum-Regel vorbei
    /// (der eine Schreibweg ist `AppRows.setVisible`).
    @Test("the source map card carries no area switch any more")
    func noAreaToggleOnTheCard() throws {
        let text = try sourceText("Sources/Views/SourceMapCard.swift")
        let pattern = try NSRegularExpression(
            pattern: #"accessibilityIdentifier\("((?:books|music)-[a-z-]+-toggle)"\)"#)
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        for match in pattern.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text) { found.insert(String(text[r])) }
        }
        #expect(found.isEmpty, "area switches came back to the card: \(found.sorted())")
    }

    /// The tick means "available", not "has a server": radio, the free
    /// catalogs and podcasts without a sync server are ready the moment
    /// the app starts. Only an area that still needs a server stays empty.
    @Test("Bereit ist abgehakt; nur ein Bereich, der einen Server braucht, bleibt ohne Haken")
    func readyAreasAreTicked() {
        let none = SourceMapFacts()
        #expect(SourceMapCard.isConnected(.radio, facts: none))
        #expect(SourceMapCard.isConnected(.freeCatalogs, facts: none))
        #expect(SourceMapCard.isConnected(.podcasts, facts: none))
        #expect(!SourceMapCard.isConnected(.audiobooks, facts: none))
        #expect(!SourceMapCard.isConnected(.music, facts: none))
        var abs = SourceMapFacts()
        abs.absConnected = true
        abs.absServer = "https://abs.example.net"
        #expect(SourceMapCard.isConnected(.audiobooks, facts: abs))
    }

    @Test("the fence would SEE a missing area row (red probe)")
    func fenceCatchesAMissingArea() {
        // The rows enumeration without the jamendo row: the lookup the
        // fence stands on must come back empty.
        let crippled = AppRows.all.filter { $0.key != "music.jamendo" }
        #expect(!crippled.contains { $0.key == FreeCatalog.Area.freeMusic.rowKey })
    }
}
#endif
