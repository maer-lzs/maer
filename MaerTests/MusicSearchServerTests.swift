// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Which music server: the search can be narrowed under
/// music to one of the two servers, by the source of the hit.
@MainActor
struct MusicSearchServerTests {
    @Test("without a choice every hit stays, with a choice only the hits of this server, by identifier")
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

    @Test("the row exists only with two music servers, in their order and with the name of the capsule")
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

    @Test("No empty row while the search runs; afterwards that of the library or that of the one server")
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

    @Test("the page narrows by identifier, only under music, and the catalog steps in only when the library has nothing", .needsTheSources)
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
    @Test("The catalog view is a list of its own, so that iOS 27 draws it after the tap", .needsTheSources)
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
