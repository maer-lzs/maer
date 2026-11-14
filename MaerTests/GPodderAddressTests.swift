// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The user name and the device id go into the gpodder address as one path
/// segment each, percent-encoded once. A server that decodes the path once
/// (gpodder.net, Nextcloud GPodder) reads exactly the name that was typed;
/// oPodSync does not decode the path and reads the encoded form, which for
/// a name of letters and digits is the same.
struct GPodderAddressTests {
    private let base = URL(string: "https://gp.example.com")!

    private func built(_ name: String, base: URL? = nil) throws -> URL {
        try #require(GPodderClient.address(base: base ?? self.base,
                                           path: "api/2/subscriptions/\(GPodderClient.segment(name)).json"))
    }

    @Test("the user name goes into the address once encoded as one segment, also with space, umlaut, percent and slash")
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
            // What a server that decodes once reads: the typed name.
            let last = try #require(encoded.split(separator: "/").last)
            #expect(String(last).removingPercentEncoding == name + ".json", "\(name): the server reads \(last)")
        }
    }

    @Test("the address keeps the path of the base and the query")
    func theBasePathAndTheQueryStand() throws {
        let url = try #require(GPodderClient.address(base: URL(string: "https://host.example/gpodder/")!,
                                                     path: "api/2/episodes/\(GPodderClient.segment("anna smith")).json",
                                                     query: [URLQueryItem(name: "since", value: "0")]))
        #expect(url.absoluteString == "https://host.example/gpodder/api/2/episodes/anna%20smith.json?since=0")
    }

    /// A path that is not encoded gives no address instead of ending the
    /// process in `percentEncodedPath`.
    @Test("an unencoded path gives no address instead of crashing")
    func anUnencodedPathGivesNoAddress() {
        #expect(GPodderClient.address(base: base, path: "api/2/subscriptions/anna smith.json") == nil)
        #expect(GPodderClient.address(base: base, path: "api/2/subscriptions/50%.json") == nil)
        #expect(GPodderClient.address(base: base, path: "api/2/subscriptions/%zz.json") == nil)
        #expect(GPodderClient.address(base: base, path: "api/2/subscriptions/50%25.json") != nil)
    }

    /// Basic auth splits at the first colon (RFC 7617): a user name with one
    /// is refused with its own sentence, before anything is sent.
    @Test("a colon in the user name is refused, in the password it is not")
    func aColonInTheUserNameIsRefused() {
        #expect(GPodderClient.basicAuthorization(user: "anna", password: "p:w")
                == "Basic \(Data("anna:p:w".utf8).base64EncodedString())")
        #expect(GPodderClient.basicAuthorization(user: "an:na", password: "pw") == nil)
        #expect(GPodderError.colonInUserName.errorDescription?.isEmpty == false)
    }

    /// Every value interpolated into a request path goes through `segment`,
    /// counted per path, so one raw value among segmented ones is seen.
    @Test("every value inserted into a request path goes through segment", .needsTheSources)
    func everyPathValueIsASegment() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderClient.swift"), encoding: .utf8))
        let raw = Self.rawPathValues(in: code)
        #expect(Self.pathValues(in: code) >= 6, "the fence read the paths")
        #expect(raw.isEmpty, "a value goes into a path without segment: \(raw)")
        // Calibration: a raw value beside a segmented one counts.
        #expect(Self.rawPathValues(in: #"request("api/2/x/\(Self.segment(a))/\(b).json")"#) == [#"\(b)"#])
    }

    /// The interpolations in `"api/2/` path literals.
    nonisolated static func pathValues(in code: String) -> Int {
        code.split(separator: "\n").filter { $0.contains("\"api/2/") }
            .map { $0.components(separatedBy: "\\(").count - 1 }.reduce(0, +)
    }

    /// The interpolations in path literals that are not `\(Self.segment(`.
    nonisolated static func rawPathValues(in code: String) -> [String] {
        code.split(separator: "\n").filter { $0.contains("\"api/2/") }.flatMap { line in
            line.matches(of: #/\\\((?!Self\.segment\()[^)]*\)/#).map { String($0.output) }
        }
    }

    /// The class, asked of the source: an encoded segment never passes
    /// `appendingPathComponent`, which encodes every `%` again.
    @Test("the gpodder client never builds its addresses through appendingPathComponent", .needsTheSources)
    func noSecondEncoding() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/GPodderClient.swift"), encoding: .utf8))
        #expect(code.contains("Self.segment("), "the fence read the client")
        #expect(!code.contains("appendingPathComponent("), "an encoded segment goes through appendingPathComponent")
    }
}
#endif
