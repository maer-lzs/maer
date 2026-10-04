// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The user name and the device id go into the gpodder address as one path
/// segment each, percent-encoded once: after one decoding the server reads
/// exactly the name that was typed.
struct GPodderAddressTests {
    private let base = URL(string: "https://gp.example.com")!

    private func built(_ name: String, base: URL? = nil) throws -> URL {
        try #require(GPodderClient.address(base: base ?? self.base,
                                           path: "api/2/subscriptions/\(GPodderClient.segment(name)).json"))
    }

    @Test("der Benutzername geht einmal kodiert als ein Segment in die Adresse, auch mit Leerzeichen, Umlaut, Prozent und Schraegstrich")
    func theNameIsOneSegmentEncodedOnce() throws {
        let table: [(name: String, path: String)] = [
            ("anna", "/api/2/subscriptions/anna.json"),
            ("anna smith", "/api/2/subscriptions/anna%20smith.json"),
            ("ä", "/api/2/subscriptions/%C3%A4.json"),
            ("50%", "/api/2/subscriptions/50%25.json"),
            ("a/b", "/api/2/subscriptions/a%2Fb.json"),
            ("a@b", "/api/2/subscriptions/a@b.json"),
            ("a+b", "/api/2/subscriptions/a+b.json"),
        ]
        for (name, path) in table {
            let url = try built(name)
            let encoded = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)).percentEncodedPath
            #expect(encoded == path, "\(name): \(encoded)")
            // What the server reads after one decoding: the typed name.
            let last = try #require(encoded.split(separator: "/").last)
            #expect(String(last).removingPercentEncoding == name + ".json", "\(name): the server reads \(last)")
        }
    }

    @Test("die Adresse behaelt den Pfad der Basis und die Abfrage")
    func theBasePathAndTheQueryStand() throws {
        let url = try #require(GPodderClient.address(base: URL(string: "https://host.example/gpodder/")!,
                                                     path: "api/2/episodes/\(GPodderClient.segment("anna smith")).json",
                                                     query: [URLQueryItem(name: "since", value: "0")]))
        #expect(url.absoluteString == "https://host.example/gpodder/api/2/episodes/anna%20smith.json?since=0")
    }

    /// The class, asked of the source: an encoded segment never passes
    /// `appendingPathComponent`, which encodes every `%` again.
    @Test("der gpodder-Klient baut seine Adressen nie ueber appendingPathComponent", .needsTheSources)
    func noSecondEncoding() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderClient.swift"), encoding: .utf8))
        #expect(code.contains("Self.segment("), "the fence read the client")
        #expect(!code.contains("appendingPathComponent("), "an encoded segment goes through appendingPathComponent")
    }
}
#endif
