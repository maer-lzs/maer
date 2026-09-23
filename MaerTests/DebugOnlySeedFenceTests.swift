// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Debug-only types (`UITestSeed`, `FrameProbe`) exist in Debug builds
/// only. A reference outside their own file must sit inside an `#if DEBUG`
/// block, or the Release archive fails while every Debug test run stays
/// green (measured on 05.09.2026: the "next steps" card asked the harness
/// marker unguarded; the unit pair was green twice, the archive gate was
/// red). The fence used to look for the one word `UITestSeed`; the second
/// type had the same shape and no fence.
struct DebugOnlySeedFenceTests {
    /// The types whose whole file compiles out of Release.
    /// `BookmarkMeasure` (24.09.2026) is the measure page before E1b.
    nonisolated static let debugOnlyTypes = ["UITestSeed", "FrameProbe", "BookmarkMeasure"]

    /// A home file compiles out of Release only when ALL its code sits in
    /// one `#if DEBUG` block: the first line after the header comments is
    /// `#if DEBUG`, the last non-empty line is `#endif`.
    nonisolated static func isWhollyDebug(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        return lines.first == "#if DEBUG" && lines.last == "#endif"
    }

    /// Lines that name one of the types outside a DEBUG block. Tracks the
    /// `#if` nesting: a line is guarded when any open `#if` names DEBUG.
    nonisolated static func unguardedLines(in text: String, naming types: [String] = debugOnlyTypes) -> [Int] {
        var guards: [Bool] = []
        var out: [Int] = []
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                guards.append(line.contains("DEBUG") && !line.contains("!DEBUG"))
                continue
            }
            if line.hasPrefix("#else") {
                if let last = guards.last { guards[guards.count - 1] = !last && line.contains("DEBUG") }
                continue
            }
            if line.hasPrefix("#endif") { _ = guards.popLast(); continue }
            if line.hasPrefix("//") { continue }
            if types.contains(where: line.contains), !guards.contains(true) { out.append(index + 1) }
        }
        return out
    }

    @Test("die Debug-only-Typen ausserhalb ihrer Datei nur hinter #if DEBUG")
    func seedOnlyBehindDebug() throws {
        var offenders: [String] = []
        var homes = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let name = file.deletingPathExtension().lastPathComponent
            if Self.debugOnlyTypes.contains(name) {
                homes += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                if !Self.isWhollyDebug(text) { offenders.append("\(file.lastPathComponent): not wholly #if DEBUG") }
                continue
            }
            let lines = Self.unguardedLines(in: try String(contentsOf: file, encoding: .utf8))
            if !lines.isEmpty { offenders.append("\(file.lastPathComponent): \(lines)") }
        }
        #expect(homes == Self.debugOnlyTypes.count, "every debug-only type has its own file: \(homes) of \(Self.debugOnlyTypes.count)")
        #expect(offenders.isEmpty, "a debug-only type is named outside DEBUG: \(offenders)")
        #expect(Self.unguardedLines(in: "FrameProbe.shared.startIfRequested()") == [1])
        #expect(Self.unguardedLines(in: "#if DEBUG\nFrameProbe.shared.startIfRequested()\n#endif") == [])
        #expect(Self.unguardedLines(in: "let x = UITestSeed.isHarness") == [1])
        #expect(Self.unguardedLines(in: "#if DEBUG\nlet x = UITestSeed.isHarness\n#endif") == [])
        #expect(Self.unguardedLines(in: "#if DEBUG\nlet a = 1\n#else\nlet x = UITestSeed.isHarness\n#endif") == [4])
        #expect(Self.unguardedLines(in: "#if os(iOS)\n#if DEBUG\nlet x = UITestSeed.isHarness\n#endif\n#endif") == [])
        #expect(Self.unguardedLines(in: "// UITestSeed in a comment") == [])
    }
}
#endif
