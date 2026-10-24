// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// With the tabs at the side the full player stands in a stack of its own:
/// its symbol tools are the system's bar buttons in the column, its content
/// keeps to the free area, its ground reaches every corner and its value row
/// stays in sight. Everywhere else the player stays as it was.
struct PlayerToolsAtSideTests {
    private func source(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("nur bei seitlicher Leiste steht der Player im eigenen Stapel, mit den Werkzeugen als Leistenknoepfe", .needsTheSources)
    func onlyBesideTheColumnTheStackAndTheBar() throws {
        let library = try source("Sources/Views/LibraryView.swift")
        #expect(library.contains(".environment(\\.playerToolsAtSide, tabBarPlacement.isSide)"))
        let overlay = try source("Sources/Views/FullPlayerOverlay.swift")
        #expect(overlay.contains("if toolsAtSide {\n            NavigationStack {"), "the stack stands without the side column too")
        #expect(overlay.components(separatedBy: "NavigationStack").count - 1 == 1)
        let player = try source("Sources/Views/PlayerView.swift")
        #expect(player.contains("if toolsAtSide {\n                ToolbarItemGroup(placement: .bottomBar) { extrasItems }"))
        #expect(player.contains("if !toolsAtSide {\n                MeasuredFits {"), "the own row stands beside the system's bar")
    }

    @Test("der Grund reicht bis an jede Ecke, die Wertezeile bleibt sichtbar", .needsTheSources)
    func theGroundFillsAndTheValueRowStays() throws {
        let player = try source("Sources/Views/PlayerView.swift")
        // Both grounds of the sheet ignore the stack's safe area.
        #expect(player.components(separatedBy: ".opacity(SheetCorners.opacity(dragProgress: dragProgress))\n                .ignoresSafeArea()").count - 1 == 1)
        #expect(player.contains(".opacity(max(0.0, 0.9 - Double(dragProgress) * 0.9))\n                .ignoresSafeArea()"))
        // The scroll keeps no room for a bar that stands in the column, and
        // draws no soft edge over the value row.
        #expect(player.contains(".ignoresSafeArea(.container, edges: toolsAtSide ? .bottom : [])"))
        #expect(player.contains(".bottomScrollEdgeHidden(toolsAtSide)"))
    }
}
#endif
