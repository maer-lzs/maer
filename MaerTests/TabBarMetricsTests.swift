// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// No title is squeezed on its own. One size per bar,
/// derived from the LONGEST title.
@Suite struct TabBarMetricsTests {

    /// The bar offers its row at DESCENDING sizes and takes
    /// the first that fits whole. The candidate list is the whole rule, so
    /// these are the invariants that matter. A computed scale is gone, and
    /// with it the estimate that produced "Hörbüch…".
    @Test func theCandidateSizesDescendFromTheBase() {
        let sizes = MediaTabBar.labelSizes
        #expect(sizes.first == MediaTabBar.baseLabelSize)
        #expect(sizes == sizes.sorted(by: >), "die Kandidaten müssen absteigen")
        #expect(Set(sizes).count == sizes.count, "kein Maß doppelt")
    }

    /// A floor exists, and it is far enough below the base to reach the case
    /// that failed: measured, the longest title needs about 0,74 of its natural
    /// size on an iPhone with five tabs. A list stopping at 0,8 could not get
    /// there and truncated instead.
    @Test func theSmallestCandidateReachesTheMeasuredNeed() {
        let smallest = MediaTabBar.labelSizes.last!
        #expect(smallest / MediaTabBar.baseLabelSize <= 0.74)
        // …but not so small that the bar reads smaller than the interface.
        #expect(smallest >= 8)
    }

    /// The capsule grew VERTICALLY, and the horizontal measure may
    /// never fall below what it was. That width is exactly the room the long
    /// title is missing.
    @Test func theCapsuleGrewInHeightOnly() {
        #expect(TabBarMetrics.Capsule.verticalPadding > TabBarMetrics.Capsule.previousVerticalPadding)
        #expect(TabBarMetrics.Capsule.horizontalPadding >= 8)
        // The value, so the report can name it instead of describing it.
        #expect(TabBarMetrics.Capsule.verticalPadding == 11)
    }

    /// The fourth device crash of this class: the sizing
    /// engine's off-main reach cannot be enumerated. Data-pure candidates
    /// trapped, `nonisolated` candidates trapped (ObservationCenter reached a
    /// live isolated reference no fix could name). The class is only dead
    /// while the engine is unused, so the fence is a BAN with no allowlist:
    /// `ViewThatFits(` does not appear in Sources at all. `MeasuredFits` /
    /// `MeasuredLadder` are the replacements. They decide on the main
    /// render path and need no off-main guarantee.
    @Test(.needsTheSources) func viewThatFitsIsBannedRepoWide() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        for url in SourceTree.files(under: sources) where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("ViewThatFits("),
                    "\(url.lastPathComponent): ViewThatFits ist nach vier Geraete-Crashes verboten (e111072) — MeasuredFits/MeasuredLadder nehmen")
        }
    }

}

#endif
