// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// With the tabs at the side the full player stands its own side column,
/// where the library's stands and from the same two parts: its glyph tools
/// and the sleep timer in the capsule, AirPlay as the round button at its
/// foot. Its content keeps to the free area, its ground reaches every
/// corner, its dismiss zones leave the column's strip free. Everywhere else
/// the player stays as it was.
struct PlayerToolsAtSideTests {
    private func source(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("bei seitlicher Leiste steht der Player seine Spalte aus den zwei Bauteilen, ohne eigenen Stapel", .needsTheSources)
    func besideTheColumnThePlayerStandsItsOwn() throws {
        let library = try source("Sources/Views/LibraryView.swift")
        #expect(library.contains(".environment(\\.playerToolsAtSide, tabBarPlacement.isSide)"))
        #expect(library.contains(".environment(\\.sideColumnPlacement,\n                                 tabBarPlacement.isSide ? sideColumnPlacement(strip: sideStripWidth) : nil)"))
        // Both columns stand by the one placement.
        #expect(library.components(separatedBy: ".placedInSideColumn(").count - 1 == 1)
        let player = try source("Sources/Views/PlayerView.swift")
        #expect(player.components(separatedBy: ".placedInSideColumn(").count - 1 == 1)
        #expect(player.contains("SideCapsule {\n                Group {\n                    glyphTools\n                    SleepTimerMenu(viewModel: viewModel, columnCell: true)"))
        #expect(player.contains("SideRound {\n                AirPlayButton("))
        #expect(!player.contains("ToolbarItemGroup"), "the system's bar is back in the player")
        let overlay = try source("Sources/Views/FullPlayerOverlay.swift")
        #expect(!overlay.contains("NavigationStack"), "the player stands in a stack of its own again")
        #expect(overlay.contains(".padding(columnPlacement?.edge ?? [], columnPlacement?.strip ?? 0)"),
                "the dismiss zones take the column's taps")
    }

    @Test("die Werkzeuge stehen einmal: in der Reihe oder in der Spalte, der Timer ebenso", .needsTheSources)
    func theToolsStandOnce() throws {
        let player = try source("Sources/Views/PlayerView.swift")
        #expect(player.contains("if toolsAtSide {\n                if tools.contains(.source) { catalogSourceControl }\n            } else {\n                MeasuredFits {"))
        #expect(player.components(separatedBy: "if !toolsAtSide { sleepControl }").count - 1 == 2)
        // The tools carry no type size of their own; the row and the cell give it.
        #expect(!player.contains("}\n        .font(.footnote)\n        .accessibilityIdentifier(\"player-"))
    }

    @Test("der Player teilt am Falz, den die Bibliothek nennt, und oeffnet nie von selbst", .needsTheSources)
    func thePlayerDividesAtTheFoldAndNeverOpensItself() throws {
        let library = try source("Sources/Views/LibraryView.swift")
        // One fold for the pages and the player.
        #expect(library.components(separatedBy: ".environment(\\.foldLine, foldLine)").count - 1 == 2)
        #expect(library.components(separatedBy: "FoldLine(").count - 1 == 1)
        let player = try source("Sources/Views/PlayerView.swift")
        #expect(player.contains("if sideBySide, foldLine.fold != nil {\n                    FoldColumns { column in"))
        // Only a tap on the playback bar opens the player: no posture
        // change, no binding, no second writer.
        let opens = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]).reduce(0) {
            $0 + SyncContractFenceTests.stripped($1.1).components(separatedBy: "isShowingFullPlayer = true").count - 1
        }
        #expect(opens == 1)
        #expect(library.contains("onOpenPlayer: {\n                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {\n                        isShowingFullPlayer = true"))
        #expect(!library.contains("$isShowingFullPlayer") && !library.contains("isShowingFullPlayer.toggle"))
    }

    @Test("der Grund reicht bis an jede Ecke, der Inhalt bleibt in der freien Flaeche", .needsTheSources)
    func theGroundFillsAndTheContentKeepsClear() throws {
        let player = try source("Sources/Views/PlayerView.swift")
        #expect(player.components(separatedBy: ".opacity(SheetCorners.opacity(dragProgress: dragProgress))\n                .ignoresSafeArea()").count - 1 == 1)
        #expect(player.contains(".opacity(max(0.0, 0.9 - Double(dragProgress) * 0.9))\n                .ignoresSafeArea()"))
        #expect(player.contains(".padding(columnPlacement?.edge ?? [], columnPlacement?.strip ?? 0)"))
    }
}
#endif
