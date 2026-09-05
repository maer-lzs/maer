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
    @Test("Jede Adresse ist https auf einem Projekt-Host")
    func everyAddressIsHTTPSOnAProjectHost() throws {
        for guide in ServerGuides.all {
            let url = try #require(guide.docsURL, "\(guide.name) has no valid address")
            #expect(url.scheme == "https", "\(guide.name): \(guide.docs)")
            #expect(ServerGuides.projectHosts.contains(url.host ?? ""), "\(guide.name) points off the project hosts: \(url.host ?? "-")")
        }
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

    @Test("Die Anleitungen zeigen nur, solange der Bereich einen Server braucht")
    func guidesFollowTheState() {
        #expect(ServerGuides.showsGuides(for: .music, state: .needsServer))
        #expect(!ServerGuides.showsGuides(for: .music, state: .connected(host: "music.example")))
        #expect(ServerGuides.showsGuides(for: .podcasts, state: .ready))
        #expect(!ServerGuides.showsGuides(for: .podcasts, state: .readySynced(host: "gpodder.example")))
        #expect(!ServerGuides.showsGuides(for: .radio, state: .ready))
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
        for guide in ServerGuides.all {
            let line = guide.oneLiner.lowercased()
            #expect(!line.contains("recommended") && !line.contains("best "), Comment(rawValue: guide.name))
        }
    }
}
#endif
