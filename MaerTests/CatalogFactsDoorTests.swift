// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A view asks the catalogue's register only through `\.catalogFacts`, and
/// the one route decision five tiles made by hand stands once.
struct CatalogFactsDoorTests {
    @Test("eine Teileliste oeffnet die Liste, alles andere die eigene Seite")
    func theRouteFollowsThePartsList() {
        #expect(CatalogFacts.route(itemId: "lva:a", hasParts: true) == .series(itemId: "lva:a"))
        #expect(CatalogFacts.route(itemId: "lva:a", hasParts: false) == .catalogBook(itemId: "lva:a"))
    }

    @MainActor
    @Test("die lebende Tuer antwortet aus dem Register, die leere antwortet nichts")
    func theLiveDoorReadsTheRegisterTheEmptyOneNothing() throws {
        let provider = FreeCatalogProvider.shared
        let bundle = try #require(provider.remember(popular: ArchivePopularDoc(
            identifier: "facts-otr-\(UUID().uuidString)", title: ArchiveStringList(["T"]),
            creator: nil, downloads: 1, runtime: nil, licenseurl: nil, year: nil, subject: nil,
            collection: ArchiveStringList(["oldtimeradio", "radioprograms"]))))
        // An album (live recordings) is no work, so it has no parts list.
        let album = try #require(provider.remember(popular: ArchivePopularDoc(
            identifier: "facts-album-\(UUID().uuidString)", title: ArchiveStringList(["T"]),
            creator: nil, downloads: 1, runtime: nil, licenseurl: nil, year: nil, subject: nil,
            collection: ArchiveStringList(["etree"]))))
        #expect(CatalogFacts.live.route(bundle.id) == .series(itemId: bundle.id))
        #expect(CatalogFacts.live.route(album.id) == .catalogBook(itemId: album.id))

        #expect(CatalogFacts.empty.route(bundle.id) == .catalogBook(itemId: bundle.id),
                "die leere Tuer kennt keine Teileliste")
        #expect(CatalogFacts.empty.licence(bundle.id) == nil && CatalogFacts.empty.archiveForm(bundle.id) == nil)
    }

    /// Every register question a view asks, counted at its SIGNATURE, whoever
    /// the receiver is: `FreeCatalogProvider.shared`, a name bound to it, or
    /// anything else. Counting the literal `.shared` form let a bound name
    /// through. The door asks without argument labels and does not count.
    nonisolated static func registerReads(in text: String) -> [String: Int] {
        let read = #/\.(?:hasPartsList\(\s*itemId:|licence\(\s*forItemId:|readingVersion\(\s*forItemId:|archiveForm\(\s*itemId:|librivoxBook\(\s*forId:|jamendoTrack\(\s*forId:|sourceURL\(\s*forItemId:|hiresCoverURL\(\s*forItemId:)/#
        return CatalogClientViewFenceTests.viewHits(in: text) { line in line.matches(of: read).count }
    }

    /// Views that still read the register themselves, measured. May only
    /// fall; every slice writes back the value. The one left is a network
    /// question and moves into a loader.
    nonisolated static let stock: [String: Int] = [
        "BookDetailScreen": 1,
    ]

    @Test("Ansichten lesen das Register nur durch die Tuer, der Bestand faellt nur", .needsTheSources)
    func viewsReadTheRegisterOnlyThroughTheDoor() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 300, "der Zeuge hat den Quelltext nicht gelesen")
        var found: [String: Int] = [:]
        for file in files where file.lastPathComponent != "CatalogFactsEnvironment.swift" {
            found.merge(Self.registerReads(in: try String(contentsOf: file, encoding: .utf8))) { $0 + $1 }
        }
        #expect(found == Self.stock, "Registerfragen in Ansichten: \(found.sorted { $0.key < $1.key })")
        #expect(Self.registerReads(in: "struct T: View {\n var x: Bool { FreeCatalogProvider.shared\n  .hasPartsList(itemId: i) }\n}")
                == ["T": 1], "der Zaehler sieht die Frage auch ueber einen Umbruch")
        #expect(Self.registerReads(in: "struct T: View {\n func f() { let provider = FreeCatalogProvider.shared\n  _ = provider.licence(forItemId: i) }\n}")
                == ["T": 1], "der Zaehler sieht die Frage auch ueber eine Bindung")
        #expect(Self.registerReads(in: "struct T: View {\n var l: String? { catalogFacts.licence(item.id) }\n}").isEmpty,
                "die Frage an die Tuer zaehlt nicht")
    }
}
#endif
