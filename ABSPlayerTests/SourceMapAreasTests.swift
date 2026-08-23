// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// R36: the areas list must be COMPLETE — free music steered a visible
/// surface for months while its switch existed only under network services
/// (a different question: privacy per service, not presence of an area), so
/// the list looked complete and was not. A source-scan fence instead of a
/// house rule: every `FreeCatalog.Area` has to appear in the areas section,
/// and the section may not carry a switch the enumeration does not know.
struct SourceMapAreasTests {

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("every catalog area carries its switch in the areas list")
    func everyAreaHasItsToggle() throws {
        let text = try sourceText("Sources/Views/SourceMapCard.swift")
        for area in FreeCatalog.Area.allCases {
            #expect(text.contains(area.toggleIdentifier),
                    "area \(area.rawValue) has no switch in the areas list")
            #expect(text.contains(area.storageKey),
                    "area \(area.rawValue) does not bind its stored key")
        }
    }

    @Test("the areas list carries no switch outside the enumeration")
    func noStrayAreaToggle() throws {
        let text = try sourceText("Sources/Views/SourceMapCard.swift")
        let known = Set(FreeCatalog.Area.allCases.map(\.toggleIdentifier))
        let pattern = try NSRegularExpression(
            pattern: #"accessibilityIdentifier\("((?:books|music)-[a-z-]+-toggle)"\)"#)
        let range = NSRange(text.startIndex..., in: text)
        var found: Set<String> = []
        for match in pattern.matches(in: text, range: range) {
            if let r = Range(match.range(at: 1), in: text) { found.insert(String(text[r])) }
        }
        #expect(found.subtracting(known).isEmpty,
                "switches without an area case: \(found.subtracting(known).sorted())")
    }

    @Test("the fence would SEE a missing area (red probe)")
    func fenceCatchesAMissingArea() {
        // The shipped list without the free-music line: the check must fail.
        let crippled = """
        AppSwitch("Show free audiobooks", isOn: $freeAudiobooks)
            .accessibilityIdentifier("books-free-audiobooks-toggle")
        AppSwitch("Show Netlabels", isOn: $netlabelsRow)
            .accessibilityIdentifier("music-netlabels-toggle")
        """
        #expect(!crippled.contains(FreeCatalog.Area.freeMusic.toggleIdentifier))
    }
}
#endif
