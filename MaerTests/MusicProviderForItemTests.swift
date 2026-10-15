// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `musicProvider` beantwortet „welche Musikquelle benutzt dieses Geraet",
/// und mit zwei aktiven Servern gewinnt Subsonic vorerst. Das ist die richtige
/// Antwort fuer eine Bibliotheks-Liste und die falsche fuer einen Titel, der
/// seine Quelle in der Kennung traegt.
///
/// Die Album-Seite wird auch aus dem VOLLPLAYER erreicht (Quellseiten-Sprung).
/// Ein laufendes `jf:`-Album konnte sie also oeffnen, waehrend die
/// eingestellte Antwort Subsonic war, und jede Frage nach dieser Kennung ging
/// an einen Server, der sie nie gesehen hat: keine Titel, kein Stern, keine
/// Album-Angaben.
@MainActor
struct MusicProviderForItemTests {
    @Test("Die Kennung entscheidet, nicht die Einstellung")
    func theIdDecidesNotTheSetting() {
        let session = AppSession.shared
        #expect(session.musicProvider(for: "jf:album:1") as AnyObject === JellyfinProvider.shared,
                "eine jf-Kennung muss zu Jellyfin, egal welche Quelle eingestellt ist")
        #expect(session.musicProvider(for: "sub:album:1") as AnyObject === SubsonicProvider.shared)
        #expect(session.musicProvider(for: "sub:song:7") as AnyObject === SubsonicProvider.shared)
    }

    /// Ohne Musik-Namensraum gibt es nichts zu entscheiden, und dann ist die
    /// eingestellte Quelle die einzige sinnvolle Antwort. Ohne diesen Fall
    /// koennte die Tuer auf einen festen Server zeigen und der obere Fall
    /// waere trotzdem gruen.
    @Test("Ohne Namensraum antwortet die eingestellte Quelle")
    func withoutANamespaceTheConfiguredSourceAnswers() {
        let session = AppSession.shared
        #expect(session.musicProvider(for: "maer-playlist-42") as AnyObject
                === session.musicProvider as AnyObject)
        #expect(session.musicProvider(for: "") as AnyObject === session.musicProvider as AnyObject)
    }

    /// Der Bestand: die Album-Seite fragt die EINGESTELLTE Quelle nicht mehr.
    /// Sechzehn Zeilen taten es, und vier davon banden sie sogar vorher an
    /// ein lokales `music` — die Datei zeigte das Muster selbst und meinte
    /// trotzdem die falsche Quelle.
    @Test("Die Album-Seite fragt die eingestellte Quelle nicht mehr", .needsTheSources)
    func thealbumPageNoLongerAsksTheConfiguredSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/Views/Music/MusicAlbumView.swift"),
                              encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // Die eine erlaubte Nennung ist die Tuer selbst, mit der Kennung.
        let asksTheDevice = code.components(separatedBy: "AppSession.shared.musicProvider").count - 1
        let asksTheItem = code.components(separatedBy: "AppSession.shared.musicProvider(for:").count - 1
        #expect(asksTheDevice == asksTheItem,
                "die Seite fragt die eingestellte Quelle wieder ohne Kennung")
        #expect(asksTheItem == 1, "die Tuer steht nicht mehr genau einmal")
    }
}
#endif
