// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What the app says about the rights of the open catalogs: "free" is no
/// claim of ours, LibriVox is public domain in the USA, a missing statement
/// carries no seal, and the Internet Archive's notice has one wording.
struct CatalogRightsWordingFenceTests {
    private func source(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("„frei“ steht in keinem Text der App als Aussage ueber die Kataloge", .needsTheSources)
    func freeIsNoClaim() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        let banned = ["free catalog", "free music (jamendo)", "public-domain readings", "free labels",
                      "freie kataloge", "freien katalog", "freie musik", "gemeinfreie lesungen", "freie labels"]
        var hits: [String] = []
        for (key, entry) in strings {
            let german = ((entry["localizations"] as? [String: Any])?["de"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String ?? ""
            let text = (key + " " + german).lowercased()
            if banned.contains(where: text.contains) { hits.append(key) }
        }
        #expect(hits.isEmpty, "a text says free about the catalogs: \(hits.sorted())")
        // Red probe of the reader.
        #expect(banned.contains(where: "From the Free Catalogs".lowercased().contains))
    }

    @Test("LibriVox und die abgelaufene US-Frist heissen gemeinfrei in den USA", .needsTheSources)
    func publicDomainNamesTheUSA() throws {
        let provider = try source("Sources/Providers/FreeCatalogProvider.swift")
        #expect(!provider.contains("String(localized: \"Public domain\")"), "a catalog label claims public domain everywhere")
        #expect(provider.components(separatedBy: "String(localized: \"Public domain in the USA\")").count - 1 == 2)
    }

    @Test("keine Rechte-Angabe ohne Aussage traegt ein Siegel, der Hinweis des Archivs hat einen Wortlaut", .needsTheSources)
    func noSealWithoutAStatement() throws {
        let detail = try source("Sources/Views/CatalogDetailExtras.swift")
        #expect(detail.contains("if let licence, licence != FreeCatalog.unstatedRights {"))
        // The page that shows the section reads the licence, so it follows
        // the register once the detail has loaded (book page and player agree).
        let page = try source("Sources/Views/BookDetailScreen.swift")
        #expect(page.contains("CatalogRightsSection(item: entry.item, licence: catalogFacts.licence(entry.id))"))
        #expect(!detail.contains("catalogFacts.licence("), "the section reads the register itself again")
        #expect(ExternalSources.internetArchive.rightsNotice == FreeCatalog.archiveRightsNotice)
        let note = try source("Sources/Views/TabContentLayout.swift")
        #expect(note.contains("Text(verbatim: FreeCatalog.archiveRightsNotice)"))
        let settings = try source("Sources/Views/SourcesSettingsView.swift")
        #expect(settings.contains("if let notice = source.rightsNotice {"))
    }

    @Test("der Satz zur Verantwortung steht einmal, im Abschnitt Ueber Maer", .needsTheSources)
    func theResponsibilityStandsOnce() throws {
        var users: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            if SyncContractFenceTests.stripped(text).contains("UserResponsibility.sentence") { users.append(name) }
        }
        #expect(users == ["SettingsView.swift"], "the sentence stands elsewhere: \(users)")
        #expect(try source("Sources/Views/SettingsView.swift").contains("Text(verbatim: UserResponsibility.sentence)"))
        #expect(UserResponsibility.sentence.contains("Mär"))
    }
}
#endif
