// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Welcher Musik-Server: die Suche laesst sich unter
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

    @Test("Keine Leer-Zeile, solange die Suche laeuft; danach die der Bibliothek oder die des einen Servers")
    func noEmptyLineWhileSearching() {
        func line(library: Bool, shown: Bool, narrowed: Bool, searching: Bool, failed: Bool = false) -> SearchEmptyLine? {
            SearchEmptyLine.of(libraryEmpty: library, shownEmpty: shown, narrowed: narrowed,
                               searching: searching, allSourcesFailed: failed)
        }
        // The narrowed server has not answered yet, then answers with nothing.
        #expect(line(library: false, shown: true, narrowed: true, searching: true) == nil,
                "no line while the server may still bring a hit")
        #expect(line(library: false, shown: true, narrowed: true, searching: false) == .server)
        // The whole library, the same transition.
        #expect(line(library: true, shown: true, narrowed: false, searching: true) == nil)
        #expect(line(library: true, shown: true, narrowed: false, searching: false) == .library)
        #expect(line(library: true, shown: true, narrowed: true, searching: false) == .library,
                "an empty library is said as the library's, not as one server's")
        #expect(line(library: false, shown: false, narrowed: false, searching: false) == nil, "hits stand, no line")
        #expect(line(library: false, shown: false, narrowed: true, searching: false) == nil, "the server has hits")
        #expect(line(library: true, shown: true, narrowed: true, searching: false, failed: true) == nil,
                "a failure has its own page")
    }

    @Test("GT-3: die Seite grenzt nach der Kennung ein, nur unter Musik, und der Katalog springt nur ein, wenn die Bibliothek nichts hat", .needsTheSources)
    func theScreenIsWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("Sources/Views/SearchScreen.swift"), encoding: .utf8)
        #expect(screen.contains("section.results.filter { MusicSourceRule.keeps($0.id, chosen: chosen) }"),
                "the hit's id decides, never the query")
        #expect(screen.contains("guard scope == .music, let musicServer,"), "the narrowing holds only under Music")
        #expect(screen.contains("if scope == .music, isQueryActive, servers.count > 1 {"), "the row shows only with two servers")
        #expect(screen.contains("SearchEmptyLine.of(libraryEmpty: unnarrowed.isEmpty, shownEmpty: own.isEmpty,"),
                "one server's silence is not the library's")
        #expect(screen.contains("let autoCatalog = emptyLine == .library"), "the catalog steps in on the rule's word")
        #expect(screen.contains("if emptyLine == .server, let chosen = narrowedServer,"),
                "the server's line stands on the rule's word, so never while the search runs")
        #expect(screen.contains("MusicServerRow(servers: servers, chosen: narrowedServer)"), "the row stands on the page")
        let row = try #require(functionBody(of: "struct MusicServerRow: View {", in: screen))
        let large = try #require(row.range(of: "if typeSize.isAccessibilitySize {"))
        #expect(row[large.upperBound...].prefix(120).contains("VStack(alignment: .leading"),
                "at large text the choices stand one below the other, none past the edge")
    }

    /// The catalog page is never white. Measured on iOS 27: the one lazy
    /// stack switched from the long library results to the short catalog
    /// card drew nothing; the same code on iOS 26.5 drew the card. The
    /// journey `testGlobalSearchFindsAllTypes` holds it on the device; this
    /// holds the construction that cures it.
    @Test("Die Katalog-Ansicht ist eine eigene Liste, damit iOS 27 sie nach dem Tipp zeichnet", .needsTheSources)
    func theCatalogViewIsItsOwnList() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("Sources/Views/SearchScreen.swift"), encoding: .utf8)
        let code = screen.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let stack = try #require(code.range(of: "LazyVStack(alignment: .leading, spacing: 0) {"))
        let identity = try #require(code.range(of: ".id(showCatalog)", range: stack.upperBound..<code.endIndex))
        let clearance = try #require(code.range(of: ".bottomBarClearance()", range: stack.upperBound..<code.endIndex))
        #expect(identity.lowerBound < clearance.lowerBound, "the identity sits on the results stack itself")
    }
}
#endif
