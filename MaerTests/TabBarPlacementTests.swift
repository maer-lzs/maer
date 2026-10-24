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

    @Test("seitlich nur, wo das System an der Kante eine Spalte frei haelt")
    func theSideNeedsAFreeColumn() {
        // Folded upright: the status column keeps 84 pt free at the right.
        #expect(TabBarPlacement.side(systemEdge: .trailing, freeColumn: 84) == .trailing)
        // Folded on its side: an edge, but nothing free at it (the bar slid
        // off the screen).
        #expect(TabBarPlacement.side(systemEdge: .trailing, freeColumn: 0) == nil)
        #expect(TabBarPlacement.side(systemEdge: .trailing, freeColumn: 43) == nil)
        #expect(TabBarPlacement.side(systemEdge: nil, freeColumn: 84) == nil)
    }

    @Test("eine Rechnung fuer Bibliothek und Blatt: die Spalte trifft die Achse auch, wo ihr Streifen vor dem Fensterrand endet")
    func oneReckoningForLibraryAndSheet() {
        var reading = ReservedStrip()
        reading.axisShift = -6
        reading.windowMaxX = 466
        // The library's strip ends at the window's edge.
        #expect(reading.shift(stripMaxX: 466) == -6)
        // The settings sheet's strip ended 8 pt short (measured on the
        // folded Duo): the column moves those 8 pt back onto the axis.
        #expect(reading.shift(stripMaxX: 458) == 2)
        // Unmeasured, the shift stays the axis alone.
        #expect(ReservedStrip(axisShift: -6).shift(stripMaxX: 458) == -6)
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

    @Test("jede Reihe, die ueber ihren Rahmen zeichnet, laeuft unter die Seitenspalte und endet vor ihr", .needsTheSources)
    func everyRowReachesUnderTheSideColumn() throws {
        var bare: [String] = []
        var rows = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            rows += text.components(separatedBy: ".rowReachesUnderSideColumn()").count - 1
            guard file.lastPathComponent != "VerticalBarSideReader.swift" else { continue }
            if text.contains(".scrollClipDisabled()") { bare.append(file.lastPathComponent) }
        }
        #expect(rows >= 20, "the fence read the rows: \(rows)")
        #expect(bare.isEmpty, "a row draws past its frame without the side column: \(bare)")
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
        // column (decided 23.10.2026), and so do the search's scopes there
        // (`searchScopeColumn`, decided 24.10.2026); no other place builds a
        // tab bar.
        #expect(builds.sorted() == ["LibraryView.swift: 2", "SettingsView.swift: 1"],
                "the tab bar is built somewhere else too: \(builds)")
        let library = FetchAnswerTests.squeezed(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8))
        #expect(library.contains("mediaBar(upright: true)") && library.contains("upright: upright)"),
                "the upright bar is not the same tab bar")
        #expect(library.contains(".readsVerticalBarSide($verticalBarSide)"),
                "the placement no longer follows the system's edge")
    }

    /// The reader of the reserved strip lay as a UIView over the whole window
    /// while the tabs stood at the side, and a UIView takes touches: no card,
    /// tile or pill under it could be tapped (measured on the iPhone Duo,
    /// 24.10.2026; the accessibility tree still called them hittable). A
    /// UIKit view that only measures never takes a touch; a control
    /// (`AirPlayButton`) is the one that may.
    @Test("eine UIKit-Ansicht, die nur misst, nimmt keine Beruehrung an", .needsTheSources)
    func measuringViewsTakeNoTouch() throws {
        let controls: Set<String> = ["AirPlayButton.swift"]
        var readers: [String] = []
        var touchable: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            guard text.contains(": UIViewRepresentable"), !controls.contains(file.lastPathComponent) else { continue }
            readers.append(file.lastPathComponent)
            let representables = text.components(separatedBy: ": UIViewRepresentable").count - 1
            let refused = text.components(separatedBy: "isUserInteractionEnabled = false").count - 1
            if refused < representables { touchable.append(file.lastPathComponent) }
        }
        #expect(readers.count >= 2, "the fence read the readers: \(readers)")
        #expect(touchable.isEmpty, "a measuring UIKit view takes touches: \(touchable)")
        let reader = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/VerticalBarSideReader.swift"), encoding: .utf8))
        #expect(reader.contains(".takesInput(false)"), "the strip reader's background takes input")
    }

    @Test("ein Mass fuer die Seitenspalte: Reiter, Lupe, Zahnrad und die Wiedergabeleiste daneben", .needsTheSources)
    func oneMeasureForTheSideColumn() throws {
        #expect(TabBarPlacement.sideMeasure == 48)
        func source(_ path: String) throws -> String {
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
        }
        let library = try source("Sources/Views/LibraryView.swift")
        #expect(library.contains("private static let sideColumnWidth = TabBarPlacement.sideMeasure"))
        #expect(library.components(separatedBy: "diameter: Self.sideColumnWidth").count - 1 == 3,
                "cog, search and the search's close button take the measure")
        let settings = try source("Sources/Views/SettingsView.swift")
        #expect(settings.contains(".frame(width: TabBarPlacement.sideMeasure)"))
        let bar = try source("Sources/Views/MiniPlayerBar.swift")
        #expect(bar.contains("slim ? TabBarPlacement.sideMeasure - 2 : 48"), "the bar beside the column has its own height")
        // Rot-Probe: eine eigene Zahl in der Spalte faellt auf.
        for text in [library, settings, bar] {
            #expect(!text.contains("frame(width: 46)") && !text.contains("slim ? 44"))
        }
    }
}
#endif
