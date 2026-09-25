// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Welcher Musik-Server (GT-3, ENTSCHEID F9): die Suche laesst sich unter
/// Musik auf einen der zwei Server eingrenzen, nach der Quelle des Treffers.
@MainActor
struct MusicSearchServerTests {
    @Test("GT-3: ohne Wahl bleibt jeder Treffer, mit Wahl nur die Treffer dieses Servers, nach der Kennung")
    func narrowingByTheHitsServer() {
        for id in ["sub:song:1", "jf:song:1", "freecatalog:jamendo:1"] {
            #expect(MusicSourceRule.keeps(id, chosen: nil), "\(id)")
        }
        #expect(MusicSourceRule.keeps("jf:song:1", chosen: .jellyfin))
        #expect(!MusicSourceRule.keeps("sub:song:1", chosen: .jellyfin))
        #expect(MusicSourceRule.keeps("sub:song:1", chosen: .subsonic))
        #expect(!MusicSourceRule.keeps("freecatalog:jamendo:1", chosen: .subsonic),
                "a hit no music server holds is not that server's")
    }

    @Test("GT-3: die Reihe gibt es nur mit zwei Musik-Servern, in ihrer Ordnung und mit dem Namen der Kapsel")
    func choicesOnlyWithTwoServers() {
        let names = ["sub": "Navidrome", "jf": "Jellyfin"]
        #expect(MusicSourceRule.searchChoices(serving: .one(.jellyfin), active: [.jellyfin], names: names).isEmpty)
        #expect(MusicSourceRule.searchChoices(serving: .both, active: [.subsonic, .jellyfin], names: names)
                == [MusicServerChoice(server: .subsonic, name: "Navidrome"),
                    MusicServerChoice(server: .jellyfin, name: "Jellyfin")])
        #expect(MusicSourceRule.searchChoices(serving: .both, active: [.subsonic, .jellyfin], names: ["jf": "Jellyfin"])
                == [MusicServerChoice(server: .jellyfin, name: "Jellyfin")],
                "a server without a name is not offered under a guess")
        #expect(MusicSourceRule.Server.subsonic.providerId == "sub")
        #expect(MusicSourceRule.Server.jellyfin.providerId == "jf")
    }

    @Test("GT-3: die Seite grenzt nach der Kennung ein, nur unter Musik, und der Katalog springt nur ein, wenn die Bibliothek nichts hat", .needsTheSources)
    func theScreenIsWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("Sources/Views/SearchScreen.swift"), encoding: .utf8)
        #expect(screen.contains("section.results.filter { MusicSourceRule.keeps($0.id, chosen: chosen) }"),
                "the hit's id decides, never the query")
        #expect(screen.contains("guard scope == .music, let musicServer,"), "the narrowing holds only under Music")
        #expect(screen.contains("if scope == .music, isQueryActive, servers.count > 1 {"), "the row shows only with two servers")
        #expect(screen.contains("let autoCatalog = unnarrowed.isEmpty"), "one server's silence is not the library's")
        #expect(screen.contains("MusicServerRow(servers: servers, chosen: narrowedServer)"), "the row stands on the page")
        let row = try #require(functionBody(of: "struct MusicServerRow: View {", in: screen))
        let large = try #require(row.range(of: "if typeSize.isAccessibilitySize {"))
        #expect(row[large.upperBound...].prefix(120).contains("VStack(alignment: .leading"),
                "at large text the choices stand one below the other, none past the edge")
    }
}
#endif
