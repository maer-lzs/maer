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

    @Test("the bar stands where the system stands its bars upright, otherwise at the bottom")
    func theBarFollowsTheSystem() {
        #expect(TabBarPlacement.of(verticalBarSide: nil) == .bottom)
        #expect(TabBarPlacement.of(verticalBarSide: .trailing) == .side(.trailing))
        #expect(TabBarPlacement.of(verticalBarSide: .leading) == .side(.leading))
        #expect(!TabBarPlacement.bottom.isSide)
        #expect(TabBarPlacement.side(.trailing).isSide)
    }

    @Test("at the side only where the system keeps a column free at the edge")
    func theSideNeedsAFreeColumn() {
        // Folded upright: the status column keeps 84 pt free at the right.
        #expect(TabBarPlacement.side(systemEdge: .trailing, freeColumn: 84) == .trailing)
        // Folded on its side: an edge, but nothing free at it (the bar slid
        // off the screen).
        #expect(TabBarPlacement.side(systemEdge: .trailing, freeColumn: 0) == nil)
        #expect(TabBarPlacement.side(systemEdge: .trailing, freeColumn: 43) == nil)
        #expect(TabBarPlacement.side(systemEdge: nil, freeColumn: 84) == nil)
    }

    /// One form of the settings for both postures of the Duo: beside the
    /// side column over the whole window with a column of their own; a
    /// sheet in a wide window floated over the fold and kept no column free.
    @Test("the settings stand beside the column over the whole window, folded as well as unfolded, with the bar at the bottom as a sheet")
    func theSettingsTakeTheWindowBesideTheColumn() {
        #expect(SettingsPresentation.of(.side(.trailing)) == .fullScreen)
        #expect(SettingsPresentation.of(.side(.leading)) == .fullScreen)
        #expect(SettingsPresentation.of(.bottom) == .sheet)
    }

    @Test("the library shows the settings in the form of the rule, wide they stand in two columns at the fold", .needsTheSources)
    func theSettingsFollowTheRuleAndTheFold() throws {
        let library = try FetchAnswerTests.squeezedSource("Sources/Views/LibraryView.swift")
        #expect(library.contains(".sheet(isPresented: settingsShown(as: .sheet)) { settingsPage.followsAppearanceChoice() }"))
        #expect(library.contains(".fullScreenCover(isPresented: settingsShown(as: .fullScreen)) { settingsPage.followsAppearanceChoice() }"))
        #expect(library.contains("showSettings && SettingsPresentation.of(tabBarPlacement) == form"),
                "the form does not follow the rule")
        #expect(!library.contains(".sheet(isPresented: $showSettings)"), "the settings open as a sheet everywhere again")
        let page = try #require(library.components(separatedBy: "private var settingsPage: some View {").last?.prefix(500))
        #expect(page.contains(".environment(\\.foldLine, foldLine)"), "the settings do not know where the fold lies")
        // Two columns through the detail pages' frame and rule, one form each.
        let settings = try FetchAnswerTests.squeezedSource("Sources/Views/SettingsView.swift")
        #expect(settings.contains("if BookDetailLayout.of(width: geo.size.width, height: geo.size.height, compactHeight: verticalSizeClass == .compact) == .twoColumns { FoldColumns { _ in sectionForm(atFold: true) { firstSections } } trailing: { _ in sectionForm(atFold: true) { secondSections } }"))
        #expect(settings.contains("sectionForm(atFold: false) { firstSections secondSections }"), "one column leaves out a half")
        #expect(settings.components(separatedBy: "Form {").count - 1 == 1, "a second form of sections")
        #expect(settings.contains(".contentMargins(.horizontal, atFold ? FoldSplit.pageGutter : nil, for: .scrollContent)"),
                "the sections at the fold keep another gutter")
    }

    @Test("one calculation for library and sheet: the column hits the axis also where its strip ends before the window edge")
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

    @Test("the axis of the status glyphs lies on the measured glyphs in both postures of the Duo")
    func theStatusAxisMatchesBothPostures() {
        // Folded: column from 382, 84 wide, glyphs measured at 418.1.
        #expect(abs(StatusColumnAxis.x(columnMinX: 382, columnWidth: 84) - 418.1) < 1)
        // Open on its side: column from 867, 84 wide, glyphs at 903.7.
        #expect(abs(StatusColumnAxis.x(columnMinX: 867, columnWidth: 84) - 903.7) < 1)
        // Not the column's middle, which lay 6 pt off.
        #expect(abs(StatusColumnAxis.x(columnMinX: 867, columnWidth: 84) - 909) > 5)
    }

    @Test("every row that draws beyond its frame runs under the side column and ends before it", .needsTheSources)
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

    @Test("one tab bar: the library and the settings build the same one, once each", .needsTheSources)
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
        #expect(library.contains("mediaBar(upright: true, collapsed: barCollapsed)")
                && library.contains("upright: upright, collapsed: collapsed)"),
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
    @Test("a UIKit view that only measures takes no touch", .needsTheSources)
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

    @Test("one measure for the side column: tabs, magnifier, cog and the playback bar beside it", .needsTheSources)
    func oneMeasureForTheSideColumn() throws {
        #expect(TabBarPlacement.sideMeasure == 48)
        func source(_ path: String) throws -> String {
            try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8)
        }
        let library = try source("Sources/Views/LibraryView.swift")
        #expect(library.contains("private static let sideColumnWidth = TabBarPlacement.sideMeasure"))
        // Cog, search and the search's close button are the column's round
        // button, which takes the measure itself (`SideColumnStyle`).
        #expect(library.components(separatedBy: "SideRoundButton(").count - 1 == 3)
        let parts = try source("Sources/Views/SideColumnParts.swift")
        #expect(parts.contains("static let measure = TabBarPlacement.sideMeasure"))
        let settings = try source("Sources/Views/SettingsView.swift")
        #expect(settings.contains(".frame(width: TabBarPlacement.sideMeasure)"))
        let bar = try source("Sources/Views/MiniPlayerBar.swift")
        #expect(bar.contains("slim ? TabBarPlacement.sideMeasure - 2 : 48"), "the bar beside the column has its own height")
        // Red probe: a number of its own in the column is noticed.
        for text in [library, settings, bar] {
            #expect(!text.contains("frame(width: 46)") && !text.contains("slim ? 44"))
        }
    }

    @Test("the top edge is soft in every posture, only the settings carry none in both forms", .needsTheSources)
    func theTopEdgeIsSoft() throws {
        let edge = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/TopScrollEdge.swift"), encoding: .utf8))
        #expect(edge.contains("scrollEdgeEffectStyle(.soft, for: .top)"))
        #expect(edge.contains("scrollEdgeEffectHidden(true, for: .top)"))
        // The one component declares the edge; no other place declares one,
        // and every navigation stack names it: a presented stack does not
        // inherit it from the stack below.
        let stack = try NSRegularExpression(pattern: #"NavigationStack\s*[({]"#)
        var declared = 0, stacks = 0, hidden: [String: Int] = [:], bare: [String] = []
        for (name, raw) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let text = SyncContractFenceTests.stripped(raw)
            declared += text.components(separatedBy: "scrollEdgeEffectStyle(").count - 1
                + text.components(separatedBy: "scrollEdgeEffectHidden(").count - 1
            let opened = stack.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            let named = text.components(separatedBy: ".softTopScrollEdge()").count - 1
            stacks += opened
            if opened != named { bare.append("\(name): \(opened) stacks, \(named) edges") }
            let calls = text.components(separatedBy: ".withoutTopScrollEdge()").count - 1
            if calls > 0 { hidden[name] = calls }
        }
        #expect(declared == 2, "another scroll edge is declared")
        #expect(stacks > 0, "the fence found no navigation stack, so it measures nothing")
        #expect(bare.isEmpty, "a navigation stack without the soft edge: \(bare.sorted())")
        // The settings are the one page without an edge, one call for each
        // of its two forms; a file count would stay green with one form bare.
        #expect(hidden == ["SettingsView.swift": 2], "pages without a top edge: \(hidden)")
    }
}
#endif
