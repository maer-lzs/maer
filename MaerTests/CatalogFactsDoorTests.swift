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
    @Test("a parts list opens the list, everything else the page of its own")
    func theRouteFollowsThePartsList() {
        #expect(CatalogFacts.route(itemId: "lva:a", hasParts: true) == .series(itemId: "lva:a"))
        #expect(CatalogFacts.route(itemId: "lva:a", hasParts: false) == .catalogBook(itemId: "lva:a"))
    }

    @MainActor
    @Test("the living door answers from the register, the empty one answers nothing")
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
        // Every hit carries one of these names right before its bracket, and
        // the joining in `viewHits` never touches that spot.
        let signatures = ["hasPartsList(", "licence(", "readingVersion(", "archiveForm(",
                          "librivoxBook(", "jamendoTrack(", "sourceURL("]
        guard signatures.contains(where: text.contains) else { return [:] }
        let read = #/\.(?:hasPartsList\(\s*itemId:|licence\(\s*forItemId:|readingVersion\(\s*forItemId:|archiveForm\(\s*itemId:|librivoxBook\(\s*forId:|jamendoTrack\(\s*forId:|sourceURL\(\s*forItemId:)/#
        return CatalogClientViewFenceTests.viewHits(in: text) { line in line.matches(of: read).count }
    }

    /// Views that still read the register themselves, measured: none. A new
    /// one fails here.
    nonisolated static let stock: [String: Int] = [:]

    @Test("views read the register only through the door, the stock only falls", .needsTheSources)
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

    /// Every entry a view writes into the catalogue's register, counted at
    /// the SIGNATURE of the provider's four `remember` forms, whoever the
    /// receiver is. The radio's and the known servers' `remember` carry no
    /// such label and do not count.
    nonisolated static func registerWrites(in text: String) -> [String: Int] {
        guard text.contains("remember(") else { return [:] }
        let write = #/\.remember\(\s*(?:popular|gutenberg|book|track)\s*:/#
        return CatalogClientViewFenceTests.viewHits(in: text) { line in line.matches(of: write).count }
    }

    /// Views that still fill the register themselves, measured: none, from
    /// seven. A new one fails here.
    nonisolated static let writeStock: [String: Int] = [:]

    @Test("the register is filled only below the views, the stock only falls", .needsTheSources)
    func onlyLoadersFillTheRegister() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 300, "der Zeuge hat den Quelltext nicht gelesen")
        var found: [String: Int] = [:]
        for file in files {
            found.merge(Self.registerWrites(in: try String(contentsOf: file, encoding: .utf8))) { $0 + $1 }
        }
        #expect(found == Self.writeStock, "Eintraege aus Ansichten: \(found.sorted { $0.key < $1.key })")
        #expect(Self.registerWrites(in: "struct T: View {\n func f() { let p = FreeCatalogProvider.shared\n  let k = docs.compactMap { p\n   .remember(popular: $0) } }\n}")
                == ["T": 1], "der Zaehler sieht das Eintragen ueber eine Bindung und einen Umbruch")
        #expect(Self.registerWrites(in: "struct T: View {\n func f() { RadioProvider.shared.remember(result) }\n}").isEmpty,
                "das Radio traegt anderes ein")
        #expect(Self.registerWrites(in: "enum L {\n static func f() { _ = FreeCatalogProvider.shared.remember(gutenberg: b) }\n}").isEmpty,
                "ein Lader darf eintragen")
    }

    /// Every `await` on the catalogue's provider in a view: through
    /// `FreeCatalogProvider.shared` or a name bound to it anywhere in the
    /// file. What a view waits for is a network question, and those belong
    /// to a loader. A break after `await` is closed first.
    nonisolated static func providerAwaits(in text: String) -> [String: Int] {
        // Both receivers, the provider itself and a name bound to it, need
        // the provider's name in the file, and every hit needs an `await`.
        guard text.contains("FreeCatalogProvider"), text.contains("await") else { return [:] }
        let binding = #/\b(?:let|var)\s+(\w+)\s*(?::\s*\w+\s*)?=\s*FreeCatalogProvider\s*\.\s*shared\b/#
        let names = ["FreeCatalogProvider.shared"] + text.matches(of: binding).map { String($0.output.1) }
        let receiver = names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let wait = try! Regex("\\bawait\\s+(?:try\\s+)?(?:\(receiver))\\.\\w+\\s*\\(")
        let closed = text.replacing(#/\bawait\s+/#, with: "await ")
        return CatalogClientViewFenceTests.viewHits(in: closed) { line in line.matches(of: wait).count }
    }

    /// Views that still wait on the provider, measured: none. A new one
    /// fails here.
    nonisolated static let awaitStock: [String: Int] = [:]

    @Test("no view waits for the catalog provider, the stock only falls", .needsTheSources)
    func noViewAwaitsTheProvider() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 300, "der Zeuge hat den Quelltext nicht gelesen")
        var found: [String: Int] = [:]
        for file in files {
            found.merge(Self.providerAwaits(in: try String(contentsOf: file, encoding: .utf8))) { $0 + $1 }
        }
        #expect(found == Self.awaitStock, "Warten auf den Provider in Ansichten: \(found.sorted { $0.key < $1.key })")
        #expect(Self.providerAwaits(in: "struct T: View {\n func f() async { _ = await FreeCatalogProvider.shared\n  .item(id: i) }\n}")
                == ["T": 1], "der Zaehler sieht das Warten auch ueber einen Umbruch am Punkt")
        #expect(Self.providerAwaits(in: "struct T: View {\n func f() async { _ = await\n  FreeCatalogProvider.shared.item(id: i) }\n}")
                == ["T": 1], "der Zaehler sieht das Warten auch ueber einen Umbruch nach await")
        #expect(Self.providerAwaits(in: "struct T: View {\n func f() async { let p = FreeCatalogProvider.shared\n  _ = try await p.item(id: i) }\n}")
                == ["T": 1], "der Zaehler sieht das Warten auch ueber eine Bindung")
        #expect(Self.providerAwaits(in: "enum L {\n static func f() async { _ = await FreeCatalogProvider.shared.item(id: i) }\n}").isEmpty,
                "ein Lader darf warten")
        #expect(Self.providerAwaits(in: "struct T: View {\n func f() async { _ = await LibriVoxCoverLoader.hiresCover(forItemId: i) }\n}").isEmpty,
                "das Warten auf den Lader zaehlt nicht")
    }
}
#endif
