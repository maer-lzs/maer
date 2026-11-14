// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The glass of the column, the tab bar and the playback bar follows the
/// system's Liquid Glass setting: no surface lays a tint of its own over it.
struct GlassFollowsSystemTests {
    @Test("the glass carries no tint of its own, every glass surface takes the system's glass", .needsTheSources)
    func theGlassCarriesNoTintOfItsOwn() throws {
        let glass = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/AdaptiveGlassBackground.swift"),
                       encoding: .utf8))
        #expect(glass.components(separatedBy: ".glassEffect(.regular, in: shape)").count - 1 == 3)
        #expect(!glass.contains(".regular.tint("), "the glass lays its own tint again")
        var accents: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if text.contains("glassAccent") || text.contains("lightAccent:") { accents.append(file.lastPathComponent) }
        }
        #expect(accents.isEmpty, "a surface hands the glass an accent: \(accents)")
    }
}
#endif
