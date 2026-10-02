// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The server guides are data with a contract: every address is https on
/// a project host, no guide twice, and every area that needs a server has
/// somewhere to send the person.
struct ServerGuidesTests {
    @Test("Jeder Server hat Doku und Quellcode, beide https auf einem Projekt-Host")
    func everyAddressIsHTTPSOnAProjectHost() throws {
        for guide in ServerGuides.all {
            for url in [try #require(guide.docsURL, "\(guide.name) has no documentation"),
                        try #require(guide.repoURL, "\(guide.name) has no source code")] {
                #expect(url.scheme == "https", "\(guide.name): \(url)")
                #expect(ServerGuides.projectHosts.contains(url.host ?? ""), "\(guide.name) points off the project hosts: \(url.host ?? "-")")
            }
            #expect(guide.docs != guide.repo, "\(guide.name): two links, not one twice")
        }
    }

    @Test("Jede Seite sagt, was der Server kann, was er braucht und was man in Mär eintraegt; Mär Sync ist dabei")
    func everyPageSaysItsThreeThings() {
        for guide in ServerGuides.all {
            #expect(!guide.oneLiner.isEmpty && !guide.signIn.sentence.isEmpty, Comment(rawValue: guide.name))
            #expect(guide.signIn.sentence.hasPrefix("In Mär: "), Comment(rawValue: guide.name))
        }
        #expect(!ServerGuides.needs.isEmpty)
        let sync = ServerGuides.all.filter { $0.area == nil }
        #expect(sync.map(\.name) == ["Mär Sync"] && sync.first?.repo == "https://codeberg.org/LzS/maer-sync")
        #expect(Set(ServerGuides.all.map(\.signIn)) == Set(ServerGuide.SignIn.allCases), "no sign-in sentence without a server")
    }

    @Test("Kein Eintrag zweimal je Bereich, jeder Server-Bereich hat Anleitungen")
    func noDoublesAndEveryServerAreaIsCovered() {
        let ids = ServerGuides.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for area in SourceMapArea.allCases where area.requiresServer {
            #expect(!ServerGuides.guides(for: area).isEmpty, "\(area) has no guide")
        }
        #expect(!ServerGuides.guides(for: .podcasts).isEmpty)
        #expect(ServerGuides.guides(for: .radio).isEmpty)
        #expect(ServerGuides.guides(for: .freeCatalogs).isEmpty)
    }

    @Test("Die Liste erster Ebene nennt jeden Server einmal, die Bereichsseite die des Bereichs")
    func theListsNameEveryServer() {
        let first = ServerGuides.listed(in: nil)
        #expect(first.map(\.name) == ["Audiobookshelf", "Booksonic", "Navidrome", "Jellyfin", "gonic",
                                      "Airsonic Advanced", "Funkwhale", "oPodSync", "Pinchflat", "Mär Sync"])
        #expect(Set(first.map(\.name)) == Set(ServerGuides.all.map(\.name)), "no server is left out")
        #expect(ServerGuides.listed(in: .podcasts).map(\.name) == ["oPodSync", "Pinchflat", "Audiobookshelf"])
    }

    /// The guides stay once a server is connected, for when something
    /// changes later: no state decides whether they show, on either
    /// surface of the first level or on an area's page.
    @Test("Die Anleitungen stehen in jedem Zustand auf erster Ebene der Einrichtung und der naechsten Schritte", .needsTheSources)
    func theGuidesStandInEveryState() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        #expect(try code("Sources/Views/SetupView.swift").contains("ServerGuidesSection()"))
        #expect(try code("Sources/Views/NextStepsView.swift").contains("ServerGuidesSection()"))
        #expect(try code("Sources/Views/SourceMapCard.swift").contains("ServerGuidesSection(area: area)"))
        let section = try code("Sources/Views/ServerGuidesSection.swift")
        #expect(section.contains("let guides = ServerGuides.listed(in: area)"))
        #expect(!section.contains("state(of:") && !section.contains("SourceMapFacts"), "a state decides whether the guides show")
    }

    /// The addresses are for the browser. No client of the app may name a
    /// project host: the external-sources fence lets these hosts pass
    /// because of THIS test.
    @Test("Kein Client nennt einen Projekt-Host: die Adressen sind fuer den Browser")
    func clientsNeverCallProjectHosts() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles()
        where file.path.contains("/Sources/Networking/") || file.path.contains("/Sources/Providers/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for host in ServerGuides.projectHosts where text.contains("https://" + host) {
                offenders.append("\(file.lastPathComponent): \(host)")
            }
        }
        #expect(offenders.isEmpty, "a client names a guide host: \(offenders)")
    }

    @Test("Kein Werbe-Ton: kein Eintrag sagt empfohlen oder best")
    func noRanking() {
        #expect(ServerGuides.localizedKeys.count == 21, "the precondition: every guide text was read")
        for text in ServerGuides.localizedKeys {
            let line = text.lowercased()
            #expect(!line.contains("recommended") && !line.contains("best "), Comment(rawValue: text))
            // Installation is the projects' own guides' job: commands age
            // with each of their releases.
            #expect(!line.contains("docker") && !line.contains("install"), Comment(rawValue: text))
            #expect(!text.contains("\u{2014}") && !text.contains("\u{2013}"), Comment(rawValue: text))
        }
    }
}
#endif
