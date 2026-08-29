// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

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

    @Test("every catalog area carries its switch in the areas list")
    func everyAreaHasItsToggle() throws {
        let text = try sourceText("Sources/Views/SourceMapCard.swift")
        for area in FreeCatalog.Area.allCases {
            #expect(text.contains(area.toggleIdentifier),
                    "area \(area.rawValue) has no switch in the areas list")
            #expect(text.contains(area.storageKey),
                    "area \(area.rawValue) does not bind its stored key")
        }
    }

    @Test("the areas list carries no switch outside the enumeration")
    func noStrayAreaToggle() throws {
        let text = try sourceText("Sources/Views/SourceMapCard.swift")
        let known = Set(FreeCatalog.Area.allCases.map(\.toggleIdentifier))
        let pattern = try NSRegularExpression(
            pattern: #"accessibilityIdentifier\("((?:books|music)-[a-z-]+-toggle)"\)"#)
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        for match in pattern.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text) { found.insert(String(text[r])) }
        }
        #expect(found.subtracting(known).isEmpty,
                "switches without an area case: \(found.subtracting(known).sorted())")
    }

    @Test("the fence would SEE a missing area (red probe)")
    func fenceCatchesAMissingArea() {
        // The shipped list without the free-music line: the check must fail.
        let crippled = """
        AppSwitch("Show free audiobooks", isOn: $freeAudiobooks)
            .accessibilityIdentifier("books-free-audiobooks-toggle")
        AppSwitch("Show Netlabels", isOn: $netlabelsRow)
            .accessibilityIdentifier("music-netlabels-toggle")
        """
        #expect(!crippled.contains(FreeCatalog.Area.freeMusic.toggleIdentifier))
    }
}
#endif
