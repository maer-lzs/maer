// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An expectation whose condition is a parenthesized optional chain with a
/// fallback, asked for a property or a method without a comparison, such as
/// `#expect((a?.b ?? d).isEmpty)`, passes whatever the value is: a fault of
/// the testing library, measured on a witness whose value was not empty
/// (W-Sammel, 09.10.2026) and rebuilt. Bound to a name first, or compared,
/// the same check tears as it should. No expectation in the tests takes that
/// form, in `#expect` or `#require`, on one line or over several.
struct ExpectationFormFenceTests {
    /// The condition of every `#expect(` and `#require(` in a text, read over
    /// lines up to its own closing parenthesis and cut at its first comma on
    /// the top level (the message follows there).
    nonisolated static func conditions(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let start = rest.firstRange(of: #/#(?:expect|require)\(/#) {
            var depth = 1
            var condition = ""
            var index = start.upperBound
            var inString = false
            while index < rest.endIndex, depth > 0 {
                let character = rest[index]
                if character == "\"" { inString.toggle() }
                if !inString {
                    if character == "(" || character == "[" { depth += 1 }
                    if character == ")" || character == "]" { depth -= 1 }
                    if depth == 1, character == "," { break }
                }
                if depth > 0 { condition.append(character) }
                index = rest.index(after: index)
            }
            out.append(condition.trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[start.upperBound...]
        }
        return out
    }

    /// Whether a condition is the form that always passes: it opens with a
    /// parenthesized group that holds an optional chain (`?.` or `?[`) and a
    /// fallback (`??`), and goes on with a property or a method, with no
    /// comparison after the group.
    nonisolated static func isSilent(_ condition: String) -> Bool {
        guard condition.hasPrefix("(") else { return false }
        var depth = 0
        var close: String.Index?
        for index in condition.indices {
            if condition[index] == "(" { depth += 1 }
            if condition[index] == ")" { depth -= 1; if depth == 0 { close = index; break } }
        }
        guard let close else { return false }
        let group = condition[condition.startIndex...close]
        let after = condition[condition.index(after: close)...].drop(while: \.isWhitespace)
        guard group.contains("??"), group.contains("?.") || group.contains("?[") else { return false }
        guard after.hasPrefix(".") else { return false }
        return after.firstMatch(of: #/==|!=|<=|>=|\s<\s|\s>\s/#) == nil
    }

    @Test("keine Erwartung fragt eine Eigenschaft oder Methode an einer Optional-Kette mit Rueckfall in Klammern ohne Vergleich", .needsTheTests)
    func noExpectationTakesTheSilentForm() throws {
        var offenders: [String] = []
        var read = 0
        for folderName in ["MaerTests", "MaerUITests"] {
            let folder = SourceTree.root.appendingPathComponent(folderName)
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "ExpectationFormFenceTests.swift" {
                read += 1
                let text = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
                for condition in Self.conditions(in: text) where Self.isSilent(condition) {
                    offenders.append("\(url.lastPathComponent): \(condition)")
                }
            }
        }
        #expect(read > 100, "the fence read the tests: \(read)")
        #expect(offenders.isEmpty, "an expectation in the form that always passes: \(offenders)")
        // Calibration: the forms that always pass count, in either macro, on
        // one line or several, with `?.` or `?[`, any property or method.
        let silent = [
            "#expect((restOfB?.unread ?? [:]).isEmpty, \"A's unread row\")",
            "#require((carrier.pots[\"b\"]?.lists ?? [:]).isEmpty)",
            "#expect((set?.ids ?? []).contains(\"x\"))",
            "#expect((map?[\"k\"] ?? []).isEmpty)",
            "#expect(\n    (store?.rows ?? [])\n        .allSatisfy { $0.isRead },\n    \"rows\")",
            "#expect((list?.items ?? []).isSorted)",
        ]
        let kept = [
            "#expect(listsAtB.isEmpty, \"A's lists went to B\")",
            "#expect((cloud.storage[key] as? [String: Any] ?? [:]).isEmpty)",
            "#expect(restOfB?.unread?.shows.map(\\.id) == [\"x\"])",
            "#expect((set?.ids ?? []).count == 2)",
            "#expect((a?.b ?? 0) > 1)",
        ]
        for line in silent {
            #expect(Self.conditions(in: line).contains(where: Self.isSilent), "not seen: \(line)")
        }
        for line in kept {
            #expect(!Self.conditions(in: line).contains(where: Self.isSilent), "taken for the silent form: \(line)")
        }
    }
}
#endif
