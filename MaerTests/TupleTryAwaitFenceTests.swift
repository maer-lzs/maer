// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The optimizer of Swift 6.4 miscompiles one form: a task body that
/// returns, inside `do`/`catch`, a tuple holding the bare result of
/// `try await`. With `-O` the task group then hands back no answer, is torn
/// down while its children run, and their end aborts the app (`Pure virtual
/// function called`). Rebuilt outside the app; the result taken into a
/// `let` first, or wrapped in an enum case, stays whole. No tuple in the
/// sources returns a bare `try await` at its top level.
struct TupleTryAwaitFenceTests {
    /// The `return (…)` tuples in `code` that hold `try await` (or `try?`,
    /// `try!`) as one of their own elements, by line number. A `try await`
    /// inside a call or an enum case of an element does not count.
    nonisolated static func bareTryAwaitReturns(in code: String) -> [Int] {
        let chars = Array(code)
        var lines: [Int] = []
        var search = code.startIndex
        while let found = code.range(of: "return (", range: search..<code.endIndex) {
            search = found.upperBound
            var index = code.distance(from: code.startIndex, to: found.upperBound)
            var depth = 1
            var element = ""
            var elements: [String] = []
            while index < chars.count, depth > 0 {
                let char = chars[index]
                if "([{".contains(char) { depth += 1 }
                if ")]}".contains(char) { depth -= 1 }
                if depth == 1, char == "," {
                    elements.append(element); element = ""
                } else if depth > 0 {
                    element.append(char)
                }
                index += 1
            }
            elements.append(element)
            let bare = elements.contains { part in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                return ["try await", "try? await", "try! await"].contains { trimmed.hasPrefix($0) }
            }
            if elements.count > 1, bare {
                lines.append(code[..<found.lowerBound].filter { $0 == "\n" }.count + 1)
            }
        }
        return lines
    }

    @Test("der Leser findet die reissende Form und laesst die heilen stehen")
    func theReaderTellsTheForms() {
        #expect(Self.bareTryAwaitReturns(in: "do { return (key, try await ask(key), nil) } catch { }") == [1])
        #expect(Self.bareTryAwaitReturns(in: "return (\n    key,\n    try? await ask(key))") == [1])
        #expect(Self.bareTryAwaitReturns(in: "return (index, .success(try await ask(key)))").isEmpty)
        #expect(Self.bareTryAwaitReturns(in: "let tracks = try await ask(key)\nreturn (key, tracks, nil)").isEmpty)
        #expect(Self.bareTryAwaitReturns(in: "return (try await decode(data)).folders").isEmpty, "one element is no tuple")
    }

    @Test("kein Tupel in Sources gibt ein nacktes try await zurueck", .needsTheSources)
    func noTupleReturnsABareTryAwait() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            // Comment lines are emptied, not dropped, so a finding names its real line.
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
                .joined(separator: "\n")
            offenders += Self.bareTryAwaitReturns(in: code).map { "\(file.lastPathComponent):\($0)" }
        }
        #expect(offenders.isEmpty, "a tuple returns a bare try await, the form the optimizer breaks: \(offenders)")
    }
}
#endif
