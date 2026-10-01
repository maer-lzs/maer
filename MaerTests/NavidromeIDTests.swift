// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Navidrome 0.64 recomputes every song and playlist id from the old one.
/// The cases come from Navidrome's own tests, from a test bench that ran a
/// copy of a real library from 0.63.2 to 0.64.2 (every id pair), and from
/// the rule's edges. Swift and Kotlin read the same file.
struct NavidromeIDTests {
    nonisolated static let cases = SharedCases.cases("kennungen", area: "navidrome")

    @Test("gemeinsame Faelle: kennungen traegt 23 Faelle")
    func casesLoaded() {
        #expect(Self.cases.count == 23)
    }

    @Test("gemeinsame Faelle: jede ID wird, was die Datei sagt", arguments: cases)
    func everyCaseAsTheFileSays(_ c: SharedCase) throws {
        let input = try c.value("input")
        let expect = try c.value("expect")
        switch c.ask {
        case "canonical":
            let id = try #require(input["id"]?.string)
            #expect(NavidromeID.canonical(id) == expect.string, "\(c.slug)")
        case "encode":
            let hex = Array(try #require(input["hex"]?.string).utf8)
            let bytes = try #require(NavidromeID.hex(hex[...]), "\(c.slug): no hex")
            #expect(NavidromeID.encode(bytes) == expect.string, "\(c.slug)")
        case "canonical-list":
            let ids = try #require(input["ids"]?.strings)
            let expected = try #require(expect.strings)
            try #require(ids.count == expected.count && !ids.isEmpty, "\(c.slug): lists differ in length")
            let wrong = zip(ids, expected).filter { NavidromeID.canonical($0.0) != $0.1 }
            #expect(wrong.isEmpty, "\(c.slug): \(wrong.count) of \(ids.count) differ, first \(wrong.first.map { "\($0.0) -> \($0.1)" } ?? "")")
        default:
            Issue.record("\(c.slug): unknown ask \(c.ask)")
        }
    }

    @Test("der Pruefstand: 4143 Paare, davon 1741 geaendert")
    func theBenchCountsHold() throws {
        let lists = Self.cases.filter { $0.ask == "canonical-list" }
        try #require(lists.count == 4)
        var pairs = 0, changed = 0
        for c in lists {
            let ids = try #require(c["input"]?["ids"]?.strings)
            let expected = try #require(c["expect"]?.strings)
            pairs += ids.count
            changed += zip(ids, expected).filter { $0.0 != $0.1 }.count
        }
        // 1732 songs and 9 playlists changed; albums and artists kept theirs.
        #expect(pairs == 4143)
        #expect(changed == 1741)
    }

    @Test("auf einer neuen ID ist die Vorschrift die Identitaet, an allen vier Formen")
    func newIdsStayAsTheyAre() throws {
        let olds = ["5cLJPkLA5DK2BADhoeotPk", "zzzzzzzzzzzzzzzzzzzzzz",
                    "e3b7fc2ae9447bbec37a13bf916e3cf6", "f47ac10b-58cc-4372-a567-0e02b2c3d479"]
        for old in olds {
            let once = NavidromeID.canonical(old)
            #expect(once.utf8.count == NavidromeID.length, "\(old)")
            #expect(NavidromeID.canonical(once) == once, "\(old)")
        }
        let bench = Self.cases.filter { $0.ask == "canonical-list" }.compactMap { $0["expect"]?.strings }.flatMap { $0 }
        try #require(bench.count == 4143)
        #expect(bench.allSatisfy { NavidromeID.canonical($0) == $0 })
    }

    @Test("die Grenze 128 Bit: genau 128 Bit passen, eins mehr nicht")
    func theBoundary() {
        #expect(NavidromeID.base62(Array("7N42dgm5tFLK9N8MT7fHC7".utf8)) != .overflows)
        #expect(NavidromeID.base62(Array("7N42dgm5tFLK9N8MT7fHC8".utf8)) == .overflows)
        #expect(NavidromeID.base62(Array("!!!!!!!!!!!!!!!!!!!!!!".utf8)) == .invalid)
    }

    // MARK: - When the rule applies

    @Test("die Regel: nur Navidrome ab 0.64.0", arguments: [
        ("navidrome", "0.64.0", true),
        ("navidrome", "0.64.2 (38dc2727)", true),
        ("Navidrome", "0.65.1", true),
        ("navidrome", "1.0.0", true),
        ("navidrome", "0.64", true),
        ("navidrome", "0.64.0-SNAPSHOT", true),
        ("navidrome", "0.63.2", false),
        ("navidrome", "0.63.99 (abc)", false),
        ("gonic", "0.64.0", false),
        ("airsonic", "11.0.0", false),
        ("nextcloud music", "0.64.0", false),
        ("", "0.64.0", false),
    ] as [(String, String, Bool)])
    func theRule(_ type: String, _ version: String, _ applies: Bool) {
        #expect(NavidromeIDRule.applies(type: type, version: version) == applies, "\(type) \(version)")
    }

    @Test("die Regel: fehlender Typ, fehlende oder unlesbare Fassung fassen nichts an")
    func missingOrUnreadable() {
        #expect(!NavidromeIDRule.applies(type: nil, version: "0.64.0"))
        #expect(!NavidromeIDRule.applies(type: "navidrome", version: nil))
        for raw in ["", "dev", "v0.64", "0.", "64", "0.x.1"] {
            #expect(!NavidromeIDRule.applies(type: "navidrome", version: raw), "\(raw)")
        }
    }

    // MARK: - The version is kept per server

    @Test("die Fassung wird je Server gemerkt, leer schreibt nichts")
    func theVersionIsKept() {
        let server = "navidrome-version-\(UUID().uuidString).example/music"
        defer { AppStorageKeys.set(nil, for: "subsonicServerVersion.\(server)") }
        #expect(SubsonicClient.reportedVersion(server: server) == nil)
        SubsonicClient.persistReportedVersion("0.64.2 (38dc2727)", server: server)
        #expect(SubsonicClient.reportedVersion(server: server) == "0.64.2 (38dc2727)")
        SubsonicClient.persistReportedVersion("", server: server)
        SubsonicClient.persistReportedVersion(nil, server: server)
        #expect(SubsonicClient.reportedVersion(server: server) == "0.64.2 (38dc2727)")
    }

    @Test("die Antwort liest serverVersion aus dem OpenSubsonic-Kopf")
    func theBodyReadsTheVersion() throws {
        let json = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (38dc2727)","openSubsonic":true}}"#
        let body = try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(json.utf8)).subsonicResponse
        #expect(body.type == "navidrome")
        #expect(body.serverVersion == "0.64.2 (38dc2727)")
        #expect(NavidromeIDRule.applies(type: body.type, version: body.serverVersion))
    }
}
#endif
