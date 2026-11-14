// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A plus sign in a query value travels as `%2B`: at the one place
/// that every query construction goes through, and no caller encodes itself.
struct QueryValuesTests {
    @Test("the one place: a plus in the value becomes %2B, everything else stays Apple's encoding, nil empties the query")
    func thePlusTravelsEncoded() throws {
        var comps = try #require(URLComponents(string: "https://music.example/rest/search3.view"))
        comps.setQuery([URLQueryItem(name: "u", value: "hoerer+plus@example.org"),
                        URLQueryItem(name: "query", value: "Zett+Plus"),
                        URLQueryItem(name: "f", value: "json")])
        let query = try #require(comps.url?.query)
        #expect(query.contains("u=hoerer%2Bplus"), "\(query)")
        #expect(query.contains("query=Zett%2BPlus"), "\(query)")
        #expect(!query.contains("+"), "a raw plus left the setter")
        #expect(query.hasSuffix("f=json"), "the order and the plain values are untouched")
        // Read back, the value is the plus again: the encoding is the wire's, not the app's.
        #expect(URLComponents(url: try #require(comps.url), resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "query" }?.value == "Zett+Plus")
        comps.setQuery(nil)
        #expect(comps.url?.query == nil)
    }

    @Test("Subsonic: username and search with a plus go out as %2B, and a Wikidata search term likewise")
    func subsonicAndWikidataCarryThePlusEncoded() throws {
        let server = "plus-\(UUID().uuidString.lowercased()).test"
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.\(server)/sub") }
        let client = try #require(SubsonicClient(serverURL: "https://\(server)/sub",
                                                 username: "hoerer+plus@example.org", password: "geheim-42"))
        let search = try #require(client.mediaURL("search3", ["query": "Zett+Plus"])?.query)
        #expect(search.contains("u=hoerer%2Bplus"), "\(search)")
        #expect(search.contains("query=Zett%2BPlus"), "\(search)")
        let wikidata = try #require(RadioLogoLookup.wikidataSearchURL(name: "Zett+Plus")?.query)
        #expect(wikidata.contains("search=Zett%2BPlus"), "\(wikidata)")
    }

    /// The tokens that set a query, and the one file that may hold them.
    nonisolated static let setters = ["queryItems =", "queryItems?.append", "queryItems.append", "percentEncodedQuery ="]

    @Test("Fence: the query is set only in QueryValues, no caller sets queryItems or percentEncodedQuery itself", .needsTheSources)
    func onlyTheOnePlaceSetsTheQuery() throws {
        var offenders: [String] = []
        var seen = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let sites = Self.setters.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
            guard sites > 0 else { continue }
            if file.lastPathComponent == "QueryValues.swift" { seen = sites } else {
                offenders.append("\(file.lastPathComponent): \(sites)")
            }
        }
        #expect(seen == 2, "the one place sets queryItems and percentEncodedQuery once each: \(seen)")
        #expect(offenders.isEmpty, "a query set past the one place: \(offenders)")
        #expect(Self.setters.reduce(0) { $0 + "comps?.queryItems = [\n]\ncomp.queryItems?.append(x)".components(separatedBy: $1).count - 1 } == 2)
    }
}
#endif
