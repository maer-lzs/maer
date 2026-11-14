// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CryptoKit
import Foundation
@testable import Maer

/// The fence on the contract, app side.
///
/// The service has lived in a repo of its own since the move. `CONTRACT.md`
/// lies in both, byte for byte the same, and each side holds it against
/// its OWN code. **No fence sees the other repo**, and the contract says so
/// instead of keeping quiet about it: what the two fences achieve
/// is that a change to the wire that touches only one side turns red there on the
/// next run, instead of staying silent until a device stops
/// agreeing.
struct SyncContractFenceTests {
    nonisolated static func contractText() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/maer-sync-contract.md"),
                          encoding: .utf8)
    }

    /// The machine-readable block, name to values.
    nonisolated static func declared(in text: String) -> [String: [String]] {
        guard let start = text.range(of: "<!-- maer-sync-contract"),
              let end = text.range(of: "-->", range: start.upperBound..<text.endIndex)
        else { return [:] }
        var out: [String: [String]] = [:]
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].split(separator: " ").map(String.init)
        }
        return out
    }

    /// Not `nonisolated`: the file enumeration of the project fence is bound to
    /// the main actor, and the language mode does not allow a call from
    /// outside. The two helpers above do not need it.
    @MainActor
    static func sources() throws -> String {
        try ProjectFileIntegrityTests.sourceFiles()
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Only the two files that talk to the service.
    ///
    /// The whole source tree is no good for a three-digit number: `503`
    /// stands as a genre weight in `CatalogGenreAxis`, `413` and `403` are found
    /// in Wikidata ids. A fence that looks for a number anywhere
    /// always finds it.
    nonisolated static func syncSources() throws -> String {
        let net = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Networking")
        // Three files, and the third came from the fence itself: the 403 is handled in
        // the sign-in, not in the client, and the case said so
        // instead of staying green.
        return try ["MaerSyncClient.swift", "MaerSyncCarriers.swift", "MaerSyncSignIn.swift"]
            .map { try String(contentsOf: net.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Answers that are handled BY NAME, each with its reason.
    nonisolated static let byName: [String: String] = [
        "200": "die einzige gelungene",
        "401": "haelt die Runden an, bis sich jemand neu anmeldet",
        "404": "kein solches Dokument, eine gewoehnliche Antwort",
        "409": "der Schrieb schrumpfte ohne Ansage, mit eigenem Satz",
        "412": "die Fassung hat sich bewegt, also neu lesen und wiederholen",
        "503": "der Dienst hat noch keine Kennung, und das kann ein Mensch beenden",
        "410": "die Sitzung ist beendet; ein Handschlag und eine Wiederholung, kein Satz an einen Menschen",
        "403": "steht mit Absicht NICHT im Vertrag: er kommt von etwas davor",
        "428": "das Passwort setzte der Betreiber; die Anmeldung fragt nach einem neuen, nichts reist",
        "429": "zu viele Fehlversuche; die Seite sagt mit Retry-After, wann, und nichts wiederholt sich selbst",
    ]

    /// Answers that deliberately stay general, each with its reason.
    /// They mean the same for the app: the request was wrong or too
    /// big, and at runtime there is nothing to tell apart.
    nonisolated static let deliberatelyGeneric: [String: String] = [
        "400": "die Anfrage ist keine; die App baut sie selbst, also ist das ein Fehler bei uns",
        "405": "der Pfad gibt es und nicht fuer diese Art; ebenfalls unser Fehler",
        "413": "der Rumpf ist groesser als der Wirt annimmt; nichts, was die App zur Laufzeit anders machen kann",
        "426": "die alten Wege sind abgeschaltet; diese App spricht seit Fassung 5 nie im Klartext, also trifft sie ihn nicht",
    ]

    /// The same source text WITHOUT comment lines.
    ///
    /// Built because a red probe stayed green: I had taken the handling of
    /// 503 out of the code, and the fence found the number anyway, because
    /// it stands in the COMMENT beside it, which explains why it should not be a bare
    /// number. A source searcher that counts comments guards
    /// the talk about the thing instead of the thing.
    nonisolated static func stripped(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The imprint of the contract, as it stands TODAY in BOTH repos.
    ///
    /// **What it achieves and what it cannot achieve.** No fence in one
    /// repo sees the other, so nothing here can DETECT that the two
    /// copies have drifted apart. What it can do: make a change loud on the
    /// side where it happens. Whoever touches a byte is stopped
    /// here and reminded in the failure text that the other
    /// side has to follow.
    ///
    /// **The version number does not cover this.** It is declared by hand, so
    /// every change that leaves it alone is invisible to every other case
    /// here: a reworded promise, a status that silently
    /// changes its meaning, and above all a path that ends up only in the
    /// PROSE TABLE instead of the machine block, the only one that
    /// any case reads. The imprint covers every byte.
    nonisolated static let contractDigest =
        "283761495f6fd0abc669ca30ab97fc02370addf3a7353e0fc770acfe32143b55"

    /// The same for the published vectors, which also lie twice.
    /// They are foreign numbers, copied word for word, so a
    /// difference between the copies would mean that one of the two is no longer
    /// a copy.
    nonisolated static let vectorsDigest =
        "f33e06a31acb005ff39acea462a19fe02f3354a6da113abfa6febadd13d6f196"

    nonisolated static func digest(ofFileAt url: URL) throws -> String {
        try Data(contentsOf: url).sha256Hexed
    }

    @Test("the contract is the agreed bytes", .needsTheDocs)
    func theContractIsTheAgreedBytes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(try Self.digest(ofFileAt: root.appendingPathComponent("docs/maer-sync-contract.md"))
                == Self.contractDigest,
                "der Vertrag hat sich geaendert. Das ist erlaubt und nie einseitig: denselben neuen Abdruck in den Zaun des Dienst-Repos schreiben und dieselbe Datei hinuebertragen, sonst beschreiben die zwei Enden still nicht mehr denselben Dienst")
    }

    @Test("the published vectors are the agreed bytes", .needsTheTests)
    func theVectorsAreTheAgreedBytes() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        #expect(try Self.digest(ofFileAt: here.appendingPathComponent("Fixtures/Noise/noise-nk.json"))
                == Self.vectorsDigest,
                "die veroeffentlichten Vektoren haben sich geaendert. Sie sind wortgetreu von zwei fremden Umsetzungen kopiert, eine Aenderung ist also entweder eine neue Herkunft in BEIDEN Repos oder ein Fehler")
    }

    /// A shape with a reason, and the reason is the front server.
    ///
    /// The service is reached through one by its own instructions,
    /// and nginx first makes a request header with an underscore in its name
    /// INVALID (`underscores_in_headers off`, the default) and then throws
    /// away what is invalid (`ignore_invalid_headers on`, also the default).
    /// Two policies and not one: whoever ever changes the second changes
    /// the behaviour without touching the first. Either way a header
    /// that nobody set and one that the proxy swallowed look
    /// exactly the same from here.
    ///
    /// The two own headers that exist travel through a real
    /// proxy today and do so. That is where the shape comes from: measured in operation instead of
    /// reasoned. This case keeps the next one in the same shape,
    /// instead of leaving it to whoever adds it.
    @Test("no declared header name carries an underscore", .needsTheDocs)
    func noDeclaredHeaderNameCarriesAnUnderscore() throws {
        let headers = Self.declared(in: try Self.contractText())["headers"] ?? []
        #expect(!headers.isEmpty, "ohne Koepfe misst dieser Fall nichts")
        let offenders = headers.filter { $0.contains("_") }.sorted()
        #expect(offenders.isEmpty,
                "ein Proxy vor dem Dienst darf diese wortlos verwerfen, und ein gefressener Kopf ist von einem nie gesetzten nicht zu unterscheiden: \(offenders)")
    }

    /// The two paths of the encrypted session carry NO token, and
    /// that is the pattern and no negligence.
    ///
    /// The caller identifies itself INSIDE the session. That is exactly what protects
    /// the sign-in, because it carries the account secret and takes place
    /// before there is a token with which one could prove anything.
    /// Whoever demanded a token here would protect everything except the one
    /// exchange that matters most.
    ///
    /// What is read is the BODY of the two functions, not the file: a
    /// window over the whole file would find the token door of the four
    /// other paths and would always be red.
    @Test("the two session paths set no token", .needsTheSources)
    func theTwoSessionWaysSetNoToken() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let whole = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"),
                               encoding: .utf8)
        // Only from the door on: since `serviceKey` is a REQUIREMENT of the protocol,
        // its name stands twice in the file, and the first hit
        // was the declaration. This case then read the lines between
        // two protocols and reported green, without ever having
        // seen the door.
        let door = try #require(whole.range(of: "final class MaerSyncHTTP"), "die Tuer gibt es nicht mehr")
        let tunnel = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncTunnel.swift"),
                                encoding: .utf8)
        // The handshake has lived in the tunnel since version 5, not in the door.
        for (text, name) in [(String(whole[door.upperBound...]), "func serviceKey(at baseURL: URL)"),
                             (tunnel, "static func handshake(at base: URL")] {
            let start = try #require(text.range(of: name), "\(name) gibt es nicht mehr")
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    func ")
            let body = end.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            #expect(!body.contains("authoriz"),
                    "\(name) setzt ein Zeichen; damit waere die Anmeldung der einzige ungeschuetzte Austausch")
        }
    }

    /// The opposite direction, otherwise the case above only measures that a word
    /// is missing: the three paths with a token go through the ONE place that puts it
    /// into the header, the socket puts it into its first frame, and
    /// the sign-in bypasses both, because it has none yet.
    @Test("the other paths do set a token, and since version 5 only in the frame", .needsTheSources)
    func theOtherWaysDoSetATokenAfterAll() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"),
                                            encoding: .utf8))
        #expect(text.components(separatedBy: "MaerSyncHeaders.authorization(").count - 1 == 2,
                "das Zeichen wird an zwei Stellen in einen Kopf gelegt: im Helfer der drei Wege und im ersten Rahmen der Steckdose")
        #expect(text.components(separatedBy: "try await inside(access, ").count - 1 == 3,
                "drei Wege tragen das Zeichen: lesen, schreiben, auflisten")
        // Both files that build requests: the door and the tunnel. A
        // token on the OUTER request of the tunnel would be the same
        // gap one file further.
        let tunnel = Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncTunnel.swift"),
                                              encoding: .utf8))
        #expect(!(text + tunnel).contains("forHTTPHeaderField: \"Authorization\""),
                "kein Zeichen liegt mehr auf einer Anfrage im Klartext")
        #expect(!tunnel.contains("MaerSyncHeaders."), "der Tunnel kennt das Zeichen nicht; er versiegelt, was die Tuer ihm gibt")
    }

    @Test("the two session paths build their address through the one door")
    func theTwoSessionWaysBuildTheirAddressThroughTheOneDoor() {
        let base = URL(string: "https://sync.example.com")!
        #expect(MaerSyncPaths.key(base).absoluteString == "https://sync.example.com/v2/key")
        #expect(MaerSyncPaths.session(base).absoluteString == "https://sync.example.com/v1/session")
    }

    @Test("the contract lies here and names its version twice", .needsTheDocs)
    func theContractIsHereAndNamesItsVersionTwice() throws {
        let text = try Self.contractText()
        #expect(Self.declared(in: text)["version"] == ["6"])
        // Twice on purpose: once for the reader, once for the fence.
        // Whoever raises one and not the other fails here.
        #expect(text.contains("**Version: 6**"))
        #expect(MaerSyncSignIn.contractVersion == 6, "die App nennt dieselbe Fassung, die sie hier liest")
    }

    @Test("this app also calls every path that the contract promises", .needsTheSources)
    func everyPromisedPathIsCalled() throws {
        let text = try Self.sources()
        for path in Self.declared(in: try Self.contractText())["paths"] ?? [] {
            // The contract writes the path with a leading slash, the app
            // appends it to a base address. The body is what is compared.
            let stem = path.hasPrefix("/") ? String(path.dropFirst()) : path
            #expect(text.contains(stem), "der Vertrag verspricht \(path), die App ruft ihn nicht")
        }
    }

    /// The OPPOSITE DIRECTION, the same gap the service had earlier: up to
    /// here the fence only held that every promised path is called.
    /// A path that the app calls and the contract does not name stayed
    /// green. Both directions in one case, with the reporter for its own
    /// hole: if the searcher sees fewer paths than declared, it says so.
    @Test("the contract also promises every path that this app calls", .needsTheSources)
    func everyPathThisAppCallsIsInTheContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var text = ""
        for file in ["MaerSyncClient.swift", "MaerSyncTunnel.swift"] {
            text += Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/\(file)"),
                                             encoding: .utf8)) + "\n"
        }
        var called: Set<String> = []
        var cursor = text.startIndex
        // Every version of a path, not only v1: since version 6
        // `/v2/key` stands in the contract, and a searcher only for v1 would never see it.
        while let range = text.range(of: "v[0-9]+/[a-z]+", options: .regularExpression, range: cursor..<text.endIndex) {
            called.insert("/" + text[range])
            cursor = range.upperBound
        }
        let declared = Set(Self.declared(in: try Self.contractText())["paths"] ?? [])
        #expect(!called.isEmpty, "ohne gefundene Pfade misst dieser Fall nichts")
        #expect(called.subtracting(declared).isEmpty,
                "diese App ruft Pfade, die der Vertrag nicht nennt: \(called.subtracting(declared).sorted())")
        #expect(declared.subtracting(called).isEmpty,
                "der Sucher sieht erklaerte Pfade nicht, also sagt sein Schweigen nichts: \(declared.subtracting(called).sorted())")
    }

    @Test("the contract also promises every header line that this app names", .needsTheSources)
    func everyHeaderThisAppNamesIsInTheContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = Self.stripped(try Self.syncSources()) + "\n"
            + Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncTunnel.swift"),
                                       encoding: .utf8))
        // The own headers and the four of the contract from the standard
        // (`Retry-After` since version 6; the reporter below found it missing).
        // `Content-Type` is none of them: it says what a body is,
        // and the contract explains meanings, not formats.
        var named: Set<String> = []
        var cursor = text.startIndex
        while let range = text.range(of: "\"(X-Maer-[A-Za-z-]+|If-Match|ETag|Authorization|Retry-After)\"",
                                     options: .regularExpression, range: cursor..<text.endIndex) {
            named.insert(String(text[range].dropFirst().dropLast()))
            cursor = range.upperBound
        }
        let declared = Set(Self.declared(in: try Self.contractText())["headers"] ?? [])
        #expect(!named.isEmpty, "ohne gefundene Koepfe misst dieser Fall nichts")
        #expect(named.subtracting(declared).isEmpty,
                "diese App nennt Koepfe, die der Vertrag nicht nennt: \(named.subtracting(declared).sorted())")
        #expect(declared.subtracting(named).isEmpty,
                "der Sucher sieht erklaerte Koepfe nicht: \(declared.subtracting(named).sorted())")
    }

    @Test("this app sets or reads every header line of the contract", .needsTheSources)
    func everyPromisedHeaderIsUsed() throws {
        let text = try Self.sources()
        for header in Self.declared(in: try Self.contractText())["headers"] ?? [] {
            #expect(text.contains(header), "der Vertrag verspricht \(header), niemand setzt sie")
        }
    }

    @Test("this app knows every kind of the contract by name", .needsTheSources)
    func everyKindIsNamedHere() throws {
        // The OPPOSITE DIRECTION to the fence on the service side, and the
        // asymmetry is the point itself: the service must not know any kind,
        // it checks the SHAPE of a name. The app must know all six,
        // because it decides what belongs to which.
        let text = try Self.sources()
        for kind in Self.declared(in: try Self.contractText())["kinds"] ?? [] {
            #expect(text.contains("\"\(kind)\""),
                    "der Vertrag nennt die Sorte \(kind), die App kennt sie nicht")
        }
    }

    @Test("the socket message is the one that stands in the contract", .needsTheSources)
    func theSocketMessageIsTheOneInTheContract() throws {
        // Version 2. Until then the two sides agreed by chance of the
        // implementation, not by a written agreement: a
        // renamed field would have failed loudly on neither side, the app
        // would have read nil, silently fallen back to its own beat
        // and the takeover would only have become slower.
        let text = try Self.sources()
        for field in ["\"kind\"", "\"scope\"", "\"version\""] {
            #expect(text.contains(field), "die App liest das Socket-Feld \(field) nicht")
        }
        #expect(try Self.contractText()
            .contains("{\"kind\": \"<kind>\", \"scope\": \"<scope>\", \"version\": \"<etag>\"}"))
    }

    @Test("the app handles the answers on which the contract commits it", .needsTheSources)
    func thePromisedAnswersAreHandled() throws {
        let text = Self.stripped(try Self.sources())
        let declared = Self.declared(in: try Self.contractText())["status"] ?? []
        // 403 is deliberately NOT in the contract: the service never sends
        // one. The app reads it anyway, because it comes from something in front,
        // and exactly this separation must not be lost.
        #expect(!declared.contains("403"), "403 gehoert nicht in den Vertrag des Dienstes")
        #expect(text.contains("403"), "die App liest den 403 des Vorgelagerten weiter")
        // Every declared answer is either handled BY NAME or
        // deliberately general, and both stand in the stock with a reason. What
        // stood here before was a selection of three numbers, searched by
        // `contains` over the WHOLE source tree, and that was weak twice over:
        // the contract learned 503 without the case
        // noticing, and 403 like 413 stood as green although the app
        // compares them nowhere. They were found as digits in a
        // Wikidata id and in a genre table (`"fiction": 503`).
        let sync = Self.stripped(try Self.syncSources())
        for (status, grund) in Self.byName {
            #expect(declared.contains(status) || status == "403",
                    "\(status) wird beim Namen behandelt und ist nicht erklaert: \(grund)")
            #expect(sync.contains("case \(status)") || sync.contains("statusCode == \(status)"),
                    "\(status) soll beim Namen behandelt werden (\(grund)) und wird es nicht")
        }
        let benannt = Set(Self.byName.keys)
        let allgemein = Set(Self.deliberatelyGeneric.keys)
        #expect(benannt.isDisjoint(with: allgemein), "eine Antwort ist das eine oder das andere")
        #expect(Set(declared).subtracting(benannt).subtracting(allgemein).isEmpty,
                "jede erklaerte Antwort ist beim Namen behandelt oder mit Grund allgemein")
    }
}

nonisolated extension Data {
    /// The imprint as hex, without CryptoKit in a fence file: the fences
    /// also run where nobody expects a framework, and SHA-256
    /// is already available here as a tool anyway.
    var sha256Hexed: String {
        Data(SHA256.hash(data: self)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
