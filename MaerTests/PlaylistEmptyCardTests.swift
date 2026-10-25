// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Haelfte, die ohne Bildschirm entscheidbar ist: eine
/// Playlist ohne einen einzigen Titel bot Zufallswiedergabe an, an der
/// Ecke der Karte und im Kontextmenue. Ein Tipp darauf mischte nichts und
/// sagte nichts; das Bauteil war da, die Handlung konnte nicht handeln,
/// und „hat nicht funktioniert" war von „hat nichts getan" nicht zu
/// unterscheiden.
struct PlaylistEmptyCardTests {
    @Test("Eine leere Liste bietet keine Zufallswiedergabe an")
    func anEmptyListOffersNoShuffle() {
        #expect(!PlaylistPresentation.offersShuffle(trackCount: 0))
        // Der Gegenfall, damit die Regel nicht einfach alles verbietet:
        // schon ein einziger Titel laesst sich mischen (das Ergebnis ist
        // derselbe Titel, aber die Handlung HANDELT).
        #expect(PlaylistPresentation.offersShuffle(trackCount: 1))
        #expect(PlaylistPresentation.offersShuffle(trackCount: 42))
    }

    @Test("Die Karte rendert die Regel, statt eine zweite zu erfinden", .needsTheSources)
    func theCardRendersTheRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(
            contentsOf: root.appendingPathComponent("Sources/Views/Music/PlaylistCard.swift"),
            encoding: .utf8)
        let code = card.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // Beide Zufalls-Wege haengen am selben Tor: die Ecke der Karte und
        // der Eintrag im Kontextmenue. Zwei Tore waeren zwei Wahrheiten.
        #expect(code.contains("PlaylistPresentation.offersShuffle(trackCount:"))
        #expect(code.components(separatedBy: "if offersShuffle {").count - 1 == 1,
                "die Ecke haengt nicht am Tor")
        #expect(code.components(separatedBy: "isPlayable: offersShuffle,").count - 1 == 1,
                "das Menue (Abspielen, Als Naechstes, Zufaellig) haengt nicht am selben Tor wie die Ecke")
        // Der Weg HINEIN bleibt: eine leere Liste ist keine Sackgasse.
        #expect(code.contains("CardDetailPill(value: source.detailRoute)"))
    }
}
#endif
