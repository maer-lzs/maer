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

    /// The three places that show the card: setup, settings
    /// and the next steps after setup.
    static let doors = ["Sources/Views/SetupView.swift",
                        "Sources/Views/SettingsView.swift",
                        "Sources/Views/NextStepsView.swift"]

    /// The way back to the onboarding card is no path of its own, but
    /// ONE component at two doors: the setup screen and the
    /// sources overview in settings. Whoever has tapped the card
    /// away once therefore finds it without a second route.
    ///
    /// Without this case one of the two sides could build its own
    /// version, and the way back would lead to something other than the
    /// card from back then.
    @Test("Setup and settings reach the SAME card", .needsTheSources)
    func bothDoorsReachTheSameCard() throws {
        for tuer in Self.doors {
            let text = try sourceText(tuer)
            #expect(text.contains("SourceMapCard("),
                    "\(tuer) zeichnet die Karte nicht mehr")
        }
        // Red probe at the instrument: the card exists exactly ONCE. Two
        // definitions would be two truths, and the fence above would not see it,
        // because both doors would still contain „SourceMapCard(".
        let karte = try sourceText("Sources/Views/SourceMapCard.swift")
        #expect(karte.contains("struct SourceMapCard: View"))
        for andere in Self.doors {
            #expect(!(try sourceText(andere)).contains("struct SourceMapCard"),
                    "\(andere) baut sich eine eigene Karte")
        }
    }

    /// MOVED with the two-questions rebuild: the area switches live
    /// as ROWS on the rows page. The completeness statement still
    /// holds (Free music steered a surface for months without a switch
    /// in the list) and now holds the area enumeration against the
    /// rows enumeration: every catalog area has its switchable
    /// row.
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

    /// The card carries NO area switch any more: a single
    /// returned switch would write past the cleanup rule
    /// (the one write path is `AppRows.setVisible`).
    @Test("the source map card carries no area switch any more", .needsTheSources)
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
    /// At an accessibility size the card had no room: the tick took width,
    /// and "example.invalid" broke as "example.in-valid". The host may break
    /// after a dot, and the tick stays out where the line says it.
    @Test("a host breaks after a dot instead of with a hyphen, and at accessibility sizes no tick stands", .needsTheSources)
    func theHostBreaksAtADot() throws {
        #expect(SourceMapCard.breakableHost("example.invalid") == "example.\u{200B}invalid")
        #expect(SourceMapCard.breakableHost("abs.home.example.net") == "abs.\u{200B}home.\u{200B}example.\u{200B}net")
        #expect(SourceMapCard.showsTick(connected: true, accessibilitySize: false))
        #expect(!SourceMapCard.showsTick(connected: true, accessibilitySize: true))
        #expect(!SourceMapCard.showsTick(connected: false, accessibilitySize: false))
        let card = SyncContractFenceTests.stripped(try sourceText("Sources/Views/SourceMapCard.swift"))
        #expect(card.components(separatedBy: "breakableHost(host)").count - 1 == 2, "an area line names its host unbroken")
        #expect(card.contains("host: facts.syncHost.map(Self.breakableHost)"), "the sync line names its host unbroken")
        #expect(card.components(separatedBy: "Self.showsTick(connected:").count - 1 == 2, "a row draws its tick past the rule")
    }

    @Test("Ready is ticked; only an area that needs a server stays without a tick")
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

    /// The line under a row's title stands at the title's edge at every
    /// size, where the separator starts (seen at AX3: it ran under the
    /// symbol, and at the usual size too): it is part of the label's title.
    /// Both kinds of row on the card, the areas and Mär Sync, go through
    /// the one row label.
    @Test("a card row's subline stands at the title edge at every size, both kinds of row take the same part", .needsTheSources)
    func theLineKeepsTheTitleEdge() throws {
        let card = SyncContractFenceTests.stripped(try sourceText("Sources/Views/SourceMapCard.swift"))
        let uses = card.components(separatedBy: "SourceMapRowLabel(title:").count - 1
        #expect(uses == 2, "rows of the card through the row label: \(uses)")
        #expect(!card.contains("Label(Self.title(area)"), "an area row builds its own label again")
        let row = try #require(ABSPodcastRefreshTests.body(of: "struct SourceMapRowLabel: View {", in: card))
        let title = try #require(row.range(of: "Label {"), "the line is no part of the label's title")
        let line = try #require(row.range(of: "line.font(.caption)"), "the row draws no line")
        let icon = try #require(row.range(of: "} icon: {"), "the label has no symbol of its own")
        #expect(title.lowerBound < line.lowerBound && line.lowerBound < icon.lowerBound,
                "the line stands outside the label's title")
        #expect(!row.contains("dynamicTypeSize"), "the edge depends on the size again")
    }

    /// Mär Sync is no media area, but it stands on the card: otherwise
    /// the way the data travels between the devices is missing there.
    /// The row says every state of the one rule, and only the carrying one
    /// gets the tick.
    @Test("The Mär Sync row says every state, only the carrying one is ticked")
    func syncLineTable() {
        // The test host runs in the simulator's language: the translated
        // sentence is expected, as in the other witnesses of the catalog.
        let host = "sync.example.net"
        let erwartet: [(MaerSyncStanding, String, Bool)] = [
            (.carrying, String(localized: "Connected to \(host)"), true),
            (.notInUse, String(localized: "Not set up · tap to set up"), false),
            (.tokenRefused, String(localized: "Sign-in refused · tap to fix"), false),
            (.serviceOlder, String(localized: "The service is older than this app"), false),
            (.switchedOff, String(localized: "Syncing between devices is off"), false),
        ]
        var saetze: Set<String> = []
        for (standing, text, connected) in erwartet {
            let line = SourceMapSyncLine.of(standing, host: host)
            #expect(line.text == text, "\(standing): \(line.text)")
            #expect(line.connected == connected, "\(standing)")
            saetze.insert(line.text)
        }
        // Seven states, seven different sentences: none speaks for
        // another.
        #expect(saetze.count == erwartet.count)
        #expect(SourceMapSyncLine.of(.carrying, host: host).text.contains(host))
        #expect(SourceMapSyncLine.of(.carrying, host: nil).text.contains("Mär Sync"))
        #expect(SourceMapFacts().syncStanding == .notInUse)
    }

    /// The row sits IN the component (all three doors show it
    /// the same), leads to the Mär Sync page and reads its state through the
    /// one reader; that one reads the access through `stored()`, and the
    /// service's page does the same instead of going past the token.
    @Test("The card leads to Mär Sync and reads the state through the one reader", .needsTheSources)
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

    /// The card reads its facts at every draw and is drawn again when the
    /// sources change or it comes back into view: a sign-in on the page it
    /// led to shows at once, not at the next start.
    @Test("the sources card reads its state at every draw, not once", .needsTheSources)
    func theCardReadsItsStandEachTime() throws {
        let card = FetchAnswerTests.squeezed(try sourceText("Sources/Views/SourceMapCard.swift"))
        #expect(card.contains("let facts: () -> SourceMapFacts"), "the card holds a stand read once")
        #expect(card.contains("@ObservedObject private var session = AppSession.shared"), "a change of the sources does not draw the card")
        #expect(card.contains("let facts = self.facts() let _ = (session.sourcesVersion, shown)"))
        #expect(card.contains(".onAppear { shown &+= 1 }"), "the card does not read anew when it comes back")
        for host in ["Sources/Views/SettingsView.swift", "Sources/Views/SetupView.swift", "Sources/Views/NextStepsView.swift"] {
            #expect(try sourceText(host).contains("SourceMapCard(facts: { .current })"), "\(host) hands the card a stand read once")
        }
    }
}
#endif
