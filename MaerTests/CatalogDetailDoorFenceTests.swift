// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The detail of a catalogue item is asked of the source its id names,
/// through the router, like every other item's detail. Six places asked the
/// catalogue by name, so a witness could not answer for them.
struct CatalogDetailDoorFenceTests {
    /// Detail fetches on the catalogue by name or through a name bound to it.
    nonisolated static func namedFetches(in text: String) -> Int {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(IdQuestionDoorFenceTests.withoutComment)
            .joined(separator: "\n")
            .replacing(#/\s*\.\s*/#, with: ".")
        let aliases = code.matches(of: #/\b(?:let|var)\s+(\w+)\s*=\s*FreeCatalogProvider\.shared\b(?!\.)/#)
            .map { String($0.output.1) }
        return (["FreeCatalogProvider.shared"] + aliases).reduce(0) {
            $0 + code.components(separatedBy: "\($1).fetchItemDetail(").count - 1
        }
    }

    @Test("the counter sees names, alias and line break")
    func theCounterSeesNameAliasAndBreak() {
        #expect(Self.namedFetches(in: "try await FreeCatalogProvider.shared.fetchItemDetail(itemId: i)") == 1)
        #expect(Self.namedFetches(in: "let provider = FreeCatalogProvider.shared\n_ = try? await provider.fetchItemDetail(itemId: i)") == 1)
        #expect(Self.namedFetches(in: "FreeCatalogProvider.shared // why\n    .fetchItemDetail(itemId: i)") == 1)
        #expect(Self.namedFetches(in: "try await router.provider(i).fetchItemDetail(itemId: i)") == 0)
    }

    @Test("nobody fetches a catalog detail by the name of the catalog", .needsTheSources)
    func nobodyFetchesACatalogDetailByName() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.count > 300, "der Zeuge hat den Quelltext nicht gelesen")
        var found: [String] = []
        for file in files where file.lastPathComponent != "FreeCatalogProvider.swift" {
            let count = Self.namedFetches(in: try String(contentsOf: file, encoding: .utf8))
            if count > 0 { found.append("\(file.lastPathComponent): \(count)") }
        }
        #expect(found.isEmpty, "ein Detail wird wieder beim Namen des Katalogs geholt: \(found)")
    }
}
#endif
