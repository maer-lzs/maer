// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Musik kommt von Subsonic ODER Jellyfin, und WELCHER es ist, beantwortet
/// `AppSession.musicProvider`: Jellyfin, sobald es die einzige aktive
/// Musikquelle ist, sonst Subsonic.
///
/// Eine allgemeine Musik-Flaeche darf deshalb keinen konkreten Server nennen.
/// `MusicAlbumView` tat es an DREI von achtzehn Stellen (beide Album-Downloads
/// und die Zufallswiedergabe fragten fest Subsonic), waehrend die uebrigen
/// fuenfzehn den eingestellten Anbieter fragten. Bei einer Jellyfin-Quelle
/// liefen genau diese drei am Anbieter vorbei: der Download bekam den
/// falschen Anbieter mitgegeben, und die Zufallswiedergabe fragte Subsonic
/// nach den Titeln einer `jf:`-Kennung.
///
/// Der Bestand nennt die Ausnahmen mit Grund. Es sind genau die zwei
/// EINSTELLUNGSSEITEN, und dort ist der konkrete Server die Sache selbst.
struct MusicProviderDoorFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Keine allgemeine Flaeche nennt einen konkreten Musikserver")
    func noGeneralSurfaceNamesAConcreteMusicServer() throws {
        let allowed: [String: String] = [
            "Sources/AppSession.swift":
                "die Tuer selbst: hier wird entschieden, WELCHER Server der Musikanbieter ist",
            "Sources/Providers/SubsonicProvider.swift": "der Anbieter selbst",
            "Sources/Providers/JellyfinProvider.swift": "der Anbieter selbst",
            "Sources/Views/SubsonicSourceView.swift":
                "die EINSTELLUNGSSEITE dieses Servers: Verbindung testen, Bibliotheken lesen, "
                + "jetzt abgleichen. Hier IST der konkrete Server die Sache",
            "Sources/Views/JellyfinSourceView.swift":
                "dieselbe Seite fuer Jellyfin, dieselbe Begruendung",
            "Sources/UITestSeed.swift":
                "die Saat der Journeys setzt einen bestimmten Server, weil sie ihn stellt",
        ]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let relative = "Sources/" + name
            if allowed[relative] != nil { continue }
            let code = try codeOf(relative)
            for needle in ["SubsonicProvider.shared", "JellyfinProvider.shared",
                           "subsonicProvider", "jellyfinProvider"] where code.contains(needle) {
                offenders.append("\(relative) (\(needle))")
            }
        }
        #expect(offenders.isEmpty,
                "eine allgemeine Flaeche nennt einen konkreten Musikserver: \(offenders)")
    }

    /// Gegenprobe, damit der Bestand oben nicht deshalb leer ist, weil die
    /// Tuer verschwunden ist: sie waehlt wirklich zwischen beiden, und die
    /// Bedingung ist die, auf die sich der Bestand beruft.
    @Test("Die Tuer waehlt wirklich zwischen beiden Servern")
    func theDoorReallyChooses() throws {
        let code = try codeOf("Sources/AppSession.swift")
        #expect(code.contains("var musicProvider: any MusicProvider"))
        #expect(code.contains("JellyfinProvider.shared") && code.contains("SubsonicProvider.shared"),
                "die Tuer nennt nicht mehr beide Server, dann waehlt sie nichts")
        #expect(code.contains("jellyfinActive"),
                "die Wahl haengt nicht mehr an der aktiven Quelle")
    }

    /// Und die Frage, an der der Fund haengt, am Protokoll: beide Anbieter
    /// koennen sie beantworten, es gab also nie einen Grund, einen davon zu
    /// nennen.
    @Test("Was die drei Stellen brauchten, steht im Protokoll")
    func whatTheThreeSitesNeededIsInTheProtocol() throws {
        let code = try codeOf("Sources/Providers/MusicProvider.swift")
        #expect(code.contains("func songItems(forItemId itemId: String) async -> [LibraryItem]"),
                "songItems steht nicht mehr im Protokoll, dann braucht die Zufallswiedergabe wieder einen Server")
        for provider in ["Sources/Providers/SubsonicProvider.swift",
                         "Sources/Providers/JellyfinProvider.swift"] {
            #expect(try codeOf(provider).contains("func songItems(forItemId itemId: String)"),
                    "\(provider) erfuellt songItems nicht mehr")
        }
    }
}
#endif
