// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// An expectation of the form `#expect((a?.b ?? d).isEmpty)` (or
/// `.contains`) passes whatever the value is: a fault of the testing library,
/// measured on a witness whose value was not empty (W-Sammel, 09.10.2026).
/// Bound to a name first, the same check tears as it should. No expectation
/// in the tests takes that form.
struct ExpectationFormFenceTests {
    /// A line that asks `isEmpty` or `contains` of an optional chain with a
    /// fallback, inside the expectation itself.
    nonisolated static var silentForm: Regex<Substring> {
        #/#expect\(\(.*\?\..*\?\?.*\)\.(?:isEmpty|contains)/#
    }

    @Test("keine Erwartung fragt isEmpty oder contains an einer Optional-Kette mit Rueckfall in Klammern", .needsTheTests)
    func noExpectationTakesTheSilentForm() throws {
        let folder = SourceTree.root.appendingPathComponent("MaerTests")
        let walker = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var read = 0
        for case let url as URL in walker where url.pathExtension == "swift" && url.lastPathComponent != "ExpectationFormFenceTests.swift" {
            read += 1
            let lines = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8)).split(separator: "\n")
            for line in lines where line.contains(Self.silentForm) {
                offenders.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(read > 100, "the fence read the tests: \(read)")
        #expect(offenders.isEmpty, "an expectation in the form that always passes: \(offenders)")
        // Calibration: the forms as they stood, and the bound form and a
        // comparison stay out.
        #expect("#expect((restOfB?.unread ?? [:]).isEmpty, \"A's unread row\")".contains(Self.silentForm))
        #expect("#expect((carrier.pots[\"b\"]?.lists ?? [:]).isEmpty)".contains(Self.silentForm))
        #expect("#expect((set?.ids ?? []).contains(\"x\"))".contains(Self.silentForm))
        #expect(!"#expect(listsAtB.isEmpty, \"A's lists went to B\")".contains(Self.silentForm))
        #expect(!"#expect((cloud.storage[key] as? [String: Any] ?? [:]).isEmpty)".contains(Self.silentForm))
        #expect(!"#expect(restOfB?.unread?.shows.map(\\.id) == [\"x\"])".contains(Self.silentForm))
    }
}
#endif
