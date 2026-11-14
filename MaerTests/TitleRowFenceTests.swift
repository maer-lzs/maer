// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The large title of every tab root stands in the bar, level with the
/// settings gear. Measured in the simulator: with
/// `.toolbarTitleDisplayMode(.inlineLarge)` alone the title sits at the
/// gear's height on all five tabs; next to
/// `.navigationBarTitleDisplayMode(.large)` the older modifier wins and the
/// title drops back into a row of its own. So the older one must not return.
struct TitleRowFenceTests {
    @Test("the tab roots name the title mode exactly once, and that is inlineLarge", .needsTheSources)
    func theTabRootsNameInlineLargeOnly() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "LibraryView.swift" })
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(IdQuestionDoorFenceTests.withoutComment)
            .joined(separator: "\n")
        #expect(code.components(separatedBy: ".toolbarTitleDisplayMode(.inlineLarge)").count - 1 == 1,
                "die Reiter-Wurzeln tragen den Titel nicht mehr auf Hoehe des Zahnrads")
        #expect(!code.contains("navigationBarTitleDisplayMode("),
                "der aeltere Modifier gewinnt und legt den Titel wieder in eine eigene Zeile")
        #expect(code.components(separatedBy: "toolbarTitleDisplayMode(").count - 1 == 1,
                "ein zweiter Titelmodus an den Reiter-Wurzeln")
    }
}
#endif
