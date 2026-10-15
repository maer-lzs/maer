// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A JSON value as the shared case files carry it. Integers only: a
/// decimal number is refused at decoding, because the two `org.json`
/// readers on the Android side read decimals differently (`Double` on the
/// platform, `BigDecimal` on the JVM) and read integers alike.
nonisolated indirect enum JSONValue: Decodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let bool = try? single.decode(Bool.self) { self = .bool(bool); return }
        if let int = try? single.decode(Int.self) { self = .int(int); return }
        if (try? single.decode(Double.self)) != nil {
            throw DecodingError.dataCorruptedError(in: single, debugDescription: "a decimal number; the shared cases carry whole numbers only")
        }
        if let string = try? single.decode(String.self) { self = .string(string); return }
        if let array = try? single.decode([JSONValue].self) { self = .array(array); return }
        self = .object(try single.decode([String: JSONValue].self))
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .int(let i) = self { return i }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
    var strings: [String]? { array?.compactMap(\.string) }
    var ints: [Int]? { array?.compactMap(\.int) }
    subscript(key: String) -> JSONValue? { object?[key] }
}

/// One case of a shared file: its fields, named by its slug in the log.
nonisolated struct SharedCase: Sendable, CustomTestStringConvertible {
    let fields: [String: JSONValue]
    var slug: String { fields["slug"]?.string ?? "?" }
    var ask: String { fields["ask"]?.string ?? "" }
    var testDescription: String { slug }
    subscript(key: String) -> JSONValue? { fields[key] }

    /// The field, or a recorded issue that names the case and the field.
    func value(_ key: String) throws -> JSONValue {
        try #require(fields[key], "\(slug): field \(key) missing")
    }
}

/// The shared case files under `MaerTests/Fixtures/Shared`: Swift and
/// Kotlin read the SAME file, neither side transcribes. A file carries a
/// head (`regel`, `pin`, `form`) and its cases, each with a `slug` and an
/// `expect`; the fence below holds the form.
nonisolated enum SharedCases {
    struct File: Decodable {
        let regel: String
        let pin: String
        let form: Int
        let cases: [[String: JSONValue]]
    }

    /// The cases of a file, empty when the file is missing or unreadable;
    /// every witness states the count it expects, so an empty file tears.
    static func cases(_ name: String, area: String = "abos") -> [SharedCase] {
        guard let data = try? CorpusFixture.data(name, ext: "json", subdirectory: "Shared/\(area)"),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.cases.map(SharedCase.init(fields:))
    }
}

/// The form of every shared case file, so no file quietly takes a shape
/// that only one side reads.
struct SharedCasesFenceTests {
    static func files() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Shared")
        return SourceTree.files(under: root).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    /// `area/name.json` of every `SharedCases.cases("name", area: …)` in the
    /// witnesses; the area defaults to `abos`, as in `cases`.
    static func namedFiles() throws -> Set<String> {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var named: Set<String> = []
        for url in SourceTree.files(under: tests) where url.pathExtension == "swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
            for match in code.matches(of: #/SharedCases\.cases\("([^"]+)"(?:, area: "([^"]+)")?\)/#) {
                named.insert("\(match.output.2.map(String.init) ?? "abos")/\(match.output.1).json")
            }
        }
        return named
    }

    @Test("Zaun: jede gemeinsame Falldatei traegt Kopf (regel, pin, form) und Faelle mit slug und expect, slugs einmalig, Zahlen ganz", .needsTheTests)
    func everySharedFileKeepsTheForm() throws {
        let files = try Self.files()
        // The precondition names what the fence must see: exactly the files
        // the witnesses ask for, both ways. A floor (it was `>= 4` with 13
        // files) let twelve vanish unseen.
        let found = Set(files.map { "\($0.deletingLastPathComponent().lastPathComponent)/\($0.lastPathComponent)" })
        let named = try Self.namedFiles()
        #expect(!named.isEmpty, "the fence found no witness that asks for a shared file")
        #expect(named.subtracting(found).isEmpty, "a witness asks for a file that is not there: \(named.subtracting(found).sorted())")
        #expect(found.subtracting(named).isEmpty, "a shared file no witness reads: \(found.subtracting(named).sorted())")
        for url in files {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(SharedCases.File.self, from: data)
            #expect(!file.regel.isEmpty, "\(name): regel missing")
            #expect(file.pin.count == 8 && file.pin.allSatisfy(\.isHexDigit), "\(name): pin is no short commit: \(file.pin)")
            #expect(file.form >= 1, "\(name): form missing")
            #expect(!file.cases.isEmpty, "\(name): no cases")
            var slugs: Set<String> = []
            for fields in file.cases {
                let slug = fields["slug"]?.string ?? ""
                #expect(!slug.isEmpty, "\(name): a case without slug")
                #expect(slugs.insert(slug).inserted, "\(name): slug twice: \(slug)")
                #expect(fields["expect"] != nil, "\(name): \(slug) has no expect")
            }
        }
    }

    @Test("Zaun: der Leser weist Dezimalzahlen ab und liest ganze Zahlen, null, Listen und Objekte")
    func theReaderRefusesDecimals() throws {
        let whole = try JSONDecoder().decode(JSONValue.self, from: Data("{\"a\": [1, null, \"s\", true], \"b\": {\"c\": 2}}".utf8))
        #expect(whole["a"]?.array?.count == 4 && whole["b"]?["c"]?.int == 2)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(JSONValue.self, from: Data("{\"seconds\": 1.5}".utf8))
        }
    }
}
#endif
