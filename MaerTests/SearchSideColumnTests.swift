// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// With the tabs at the side the search keeps the side column: its scopes
/// stand there as the tabs do, the close button at the search's place, and
/// the X stands once.
struct SearchSideColumnTests {
    @Test("jeder Bereich der Suche traegt das Zeichen seines Reiters, die Bibliothek das Haus")
    func everyScopeWearsItsTabsGlyph() {
        #expect(SearchScope.library.tab == .home)
        for scope in SearchScope.allCases where scope != .library {
            #expect(SearchScope.initial(for: scope.tab) == scope, "\(scope) wears another tab's glyph")
        }
    }

    @Test("die Spalte bleibt in der Suche, die Bereiche stehen nur dort, das X steht einmal", .needsTheSources)
    func theColumnStaysInTheSearch() throws {
        let library = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8))
        #expect(!library.contains("if tabBarPlacement.isSide, !isShowingFullPlayer, !isShowingSearch,"),
                "the column leaves the search again")
        #expect(library.contains("scopesAtSide: tabBarPlacement.isSide"))
        #expect(library.contains("searchScopeColumn"))
        // The X: in the column unless the keyboard is up, at the bottom only
        // with the bars below or with the keyboard up.
        #expect(library.contains("if searchFieldFocused {\n                                Color.clear.frame(height: Self.sideColumnWidth)"))
        #expect(library.contains("if barsBelow || searchFieldFocused { searchCloseButton() }"))
        let screen = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/SearchScreen.swift"), encoding: .utf8))
        #expect(screen.contains("if !scopesAtSide {\n                scopeBar"), "the page draws its scope bar beside the column")
    }
}
#endif
