// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The tab bar follows the system's own bars: upright at the edge the system
/// names (a folded iPhone Duo names the trailing one), at the bottom
/// everywhere else, and there is one tab bar in the app.
struct TabBarPlacementTests {

    @Test("die Leiste steht, wo das System seine Leisten aufrecht stellt, sonst unten")
    func theBarFollowsTheSystem() {
        #expect(TabBarPlacement.of(verticalBarSide: nil) == .bottom)
        #expect(TabBarPlacement.of(verticalBarSide: .trailing) == .side(.trailing))
        #expect(TabBarPlacement.of(verticalBarSide: .leading) == .side(.leading))
        #expect(!TabBarPlacement.bottom.isSide)
        #expect(TabBarPlacement.side(.trailing).isSide)
    }

    @Test("die Achse der Statuszeichen liegt in beiden Haltungen des Duo auf den gemessenen Zeichen")
    func theStatusAxisMatchesBothPostures() {
        // Folded: column from 382, 84 wide, glyphs measured at 418.1.
        #expect(abs(StatusColumnAxis.x(columnMinX: 382, columnWidth: 84) - 418.1) < 1)
        // Open on its side: column from 867, 84 wide, glyphs at 903.7.
        #expect(abs(StatusColumnAxis.x(columnMinX: 867, columnWidth: 84) - 903.7) < 1)
        // Not the column's middle, which lay 6 pt off.
        #expect(abs(StatusColumnAxis.x(columnMinX: 867, columnWidth: 84) - 909) > 5)
    }

    @Test("eine Reiterleiste: die Bibliothek und die Einstellungen bauen dieselbe, je einmal", .needsTheSources)
    func oneTabBar() throws {
        var builds: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let count = text.components(separatedBy: "MediaTabBar(").count - 1
            if count > 0 { builds.append("\(file.lastPathComponent): \(count)") }
        }
        // The settings' sections take the library's bar upright in the side
        // column (decided 23.10.2026); no other place builds a tab bar.
        #expect(builds.sorted() == ["LibraryView.swift: 1", "SettingsView.swift: 1"],
                "the tab bar is built somewhere else too: \(builds)")
        let library = FetchAnswerTests.squeezed(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8))
        #expect(library.contains("mediaBar(upright: true)") && library.contains("upright: upright)"),
                "the upright bar is not the same tab bar")
        #expect(library.contains(".readsVerticalBarSide($verticalBarSide)"),
                "the placement no longer follows the system's edge")
    }
}
#endif
