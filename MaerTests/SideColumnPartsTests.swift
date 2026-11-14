// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// The side column is built once: one capsule, one round button. No other
/// place builds a part of it, and its measure, spacing and material stand in
/// `SideColumnStyle`.
struct SideColumnPartsTests {
    /// The one place that names the column's material besides the two
    /// parts: the playback bar beside the column takes the same glass.
    nonisolated static let materialUsers: Set<String> = ["SideColumnParts.swift", "MiniPlayerBar.swift"]

    /// Lines of code that give a view the column's glass.
    nonisolated static func materialLines(in text: String) -> Int {
        SyncContractFenceTests.stripped(text).components(separatedBy: "SideColumnStyle.tier").count - 1
            + SyncContractFenceTests.stripped(text).components(separatedBy: "tier: .sideColumn").count - 1
    }

    @Test("no capsule and no round button of the column outside the two parts", .needsTheSources)
    func theColumnIsBuiltOnce() throws {
        var users: Set<String> = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) where name != "AdaptiveGlassBackground.swift" {
            if Self.materialLines(in: text) > 0 { users.insert(name) }
        }
        #expect(users == Self.materialUsers, "the column's glass is put on elsewhere: \(users.subtracting(Self.materialUsers))")
        // The tab bar takes the capsule upright, not a glass of its own.
        let bar = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/MediaTabBar.swift"), encoding: .utf8))
        #expect(bar.contains("SideCapsule {"))
        #expect(bar.contains("private static let pillGap = SideColumnStyle.pillGap"))
        #expect(!bar.contains("CGFloat = 5") && !bar.contains("CGFloat = 4"), "the bar keeps a measure of its own")
        // Red probe of the counter: a view with the column's glass is seen.
        #expect(Self.materialLines(in: ".modifier(AdaptiveGlassBackground(shape: Circle(), tier: .sideColumn))") == 1)
    }

    @Test("the column takes the brightness the page asks for, otherwise the app's")
    @MainActor
    func theColumnTakesThePagesBrightness() {
        #expect(SideColumnStyle.scheme(page: .dark, system: .light) == .dark)
        #expect(SideColumnStyle.scheme(page: nil, system: .light) == .light)
        #expect(SideColumnStyle.scheme(page: nil, system: .dark) == .dark)
    }

    @Test("the dark book page reports itself, only the visible tab counts, the column asks the rule", .needsTheSources)
    func theDarkPageReachesTheColumn() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let library = try source("Sources/Views/LibraryView.swift")
        #expect(library.contains(".transformPreference(SideColumnSchemeKey.self) { if selectedMediaType != type { $0 = nil } }"))
        #expect(library.contains(".onPreferenceChange(SideColumnSchemeKey.self) { sidePageScheme = $0 }"))
        // One brightness for the parts and the playback bar beside them.
        #expect(library.components(separatedBy: "SideColumnStyle.scheme(").count - 1 == 1)
        #expect(library.contains("SideColumnStyle.scheme(page: sidePageScheme, system: systemColorScheme)"))
        #expect(library.contains(".environment(\\.colorScheme, sideColumnScheme)"))
        #expect(library.contains(".bottomGlassContainer()\n            .environment(\\.colorScheme, tabBarPlacement.isSide ? sideColumnScheme : systemColorScheme)"),
                "the playback bar beside the column keeps a brightness of its own")
        let page = try source("Sources/Views/BookDetailScreen.swift")
        #expect(page.contains(".environment(\\.colorScheme, .dark)\n                .sideColumnScheme(isTopPage ? .dark : nil)"),
                "the dark book page does not tell the column, or tells it while covered")
        #expect(page.contains(".onAppear { isTopPage = true }\n                .onDisappear { isTopPage = false }"))
        // The episode stands on its dark gradient too and tells the column.
        let episode = try source("Sources/Views/Podcasts/PodcastEpisodeDetailView.swift")
        #expect(episode.contains(".environment(\\.colorScheme, .dark)\n            .sideColumnScheme(isTopPage ? .dark : nil)"),
                "the dark episode page does not tell the column")
    }

    @Test("the capsule folds in to the active tab with the bottom bar, the edge stays", .needsTheSources)
    func theCapsuleCollapsesWithTheBar() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let library = try source("Sources/Views/LibraryView.swift")
        // One signal for both bars: the column reads the bottom bar's.
        #expect(library.contains("BottomBarCollapseReader { barCollapsed in\n                                mediaBar(upright: true, collapsed: barCollapsed)"))
        let bar = try source("Sources/Views/MediaTabBar.swift")
        #expect(bar.contains("collapsed ? cells.filter { $0.id == selected } : cells"), "collapsed keeps the selected tab")
        #expect(bar.components(separatedBy: "var collapsed").count - 1 == 1, "a second collapse state")
        // A tap on the one tab left only opens the column; the page stays.
        #expect(library.contains("if collapsed, newValue == selectedMediaType {\n                        BottomBarState.shared.expand()\n                        return\n                    }"))
        // The reserved strip is the system's, never the capsule's height.
        #expect(library.contains(".readsReservedStrip(ofWidth: strip, $reservedSide)"))
    }
}
#endif
