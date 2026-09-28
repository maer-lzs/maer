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

    /// Die drei Stellen, die die Karte zeigen: Einrichtung, Einstellungen
    /// und die naechsten Schritte nach der Einrichtung.
    static let doors = ["Sources/Views/SetupView.swift",
                        "Sources/Views/SettingsView.swift",
                        "Sources/Views/NextStepsView.swift"]

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
        for tuer in Self.doors {
            let text = try sourceText(tuer)
            #expect(text.contains("SourceMapCard("),
                    "\(tuer) zeichnet die Karte nicht mehr")
        }
        // Rot-Probe am Instrument: die Karte gibt es genau EINMAL. Zwei
        // Definitionen waeren zwei Wahrheiten, und der Zaun oben saehe es
        // nicht, weil beide Tueren weiter „SourceMapCard(" enthielten.
        let karte = try sourceText("Sources/Views/SourceMapCard.swift")
        #expect(karte.contains("struct SourceMapCard: View"))
        for andere in Self.doors {
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

    /// Mär Sync ist kein Medienbereich, steht aber auf der Karte: sonst
    /// fehlt dort der Weg, auf dem die Daten zwischen den Geraeten reisen.
    /// Die Zeile sagt jeden Zustand der einen Regel, und nur der tragende
    /// bekommt den Haken.
    @Test("Die Mär-Sync-Zeile sagt jeden Zustand, nur der tragende ist abgehakt")
    func syncLineTable() {
        // Der Testwirt laeuft in der Sprache des Simulators: erwartet wird
        // der uebersetzte Satz, wie in den anderen Zeugen des Katalogs.
        let host = "sync.example.net"
        let erwartet: [(MaerSyncStanding, String, Bool)] = [
            (.carrying, String(localized: "Connected to \(host)"), true),
            (.fromTheNextStart, String(localized: "Connected to \(host) · from the next start"), false),
            (.notInUse, String(localized: "Not set up · tap to set up"), false),
            (.tokenRefused, String(localized: "Sign-in refused · tap to fix"), false),
            (.serviceOlder, String(localized: "The service is older than this app"), false),
            (.stalledUntilRestart, String(localized: "Signed out · restart the app to go on"), false),
            (.switchedOff, String(localized: "Syncing between devices is off"), false),
        ]
        var saetze: Set<String> = []
        for (standing, text, connected) in erwartet {
            let line = SourceMapSyncLine.of(standing, host: host)
            #expect(line.text == text, "\(standing): \(line.text)")
            #expect(line.connected == connected, "\(standing)")
            saetze.insert(line.text)
        }
        // Sieben Zustaende, sieben verschiedene Saetze: keiner spricht fuer
        // einen anderen.
        #expect(saetze.count == erwartet.count)
        #expect(SourceMapSyncLine.of(.carrying, host: host).text.contains(host))
        #expect(SourceMapSyncLine.of(.carrying, host: nil).text.contains("Mär Sync"))
        #expect(SourceMapFacts().syncStanding == .notInUse)
    }

    /// Die Zeile sitzt IN der Komponente (alle drei Tueren zeigen sie
    /// gleich), fuehrt zur Mär-Sync-Seite und liest ihren Zustand ueber den
    /// einen Leser; der liest den Zugang ueber `stored()`, und die Seite des
    /// Dienstes tut dasselbe statt am Token vorbei.
    @Test("Die Karte fuehrt zu Mär Sync und liest den Zustand ueber den einen Leser")
    func syncRowWiring() throws {
        let karte = try sourceText("Sources/Views/SourceMapCard.swift")
        for teil in ["MaerSyncSettingsView()", "SourceMapSyncLine.of(facts.syncStanding",
                     "accessibilityIdentifier(\"source-map-sync\")",
                     "MaerSyncStandingReader.current()", "Text(\"Between your devices\")"] {
            #expect(karte.contains(teil), "Karte ohne \(teil)")
        }
        #expect(!karte.contains("Four of the five"), "der alte Satz zaehlt Mär Sync nicht mit")
        let leser = try sourceText("Sources/Networking/MaerSyncStandingReader.swift")
        #expect(leser.contains("MaerSyncAccess.stored()"))
        #expect(!leser.contains("maerSyncTokenValue"))
        let seite = try sourceText("Sources/Views/MaerSyncSettingsView.swift")
        #expect(seite.contains("signedIn = MaerSyncAccess.stored() != nil"))
        #expect(!seite.contains("signedIn = !AppStorageKeys.maerSyncTokenValue"))
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
