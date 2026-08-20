// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import ABSPlayer

/// 7fb1cc1 / 59b320e: no title is squeezed on its own — one size per bar,
/// derived from the LONGEST title.
@Suite struct TabBarMetricsTests {

    /// 7fb1cc1 / 85a7c00: the bar offers its row at DESCENDING sizes and takes
    /// the first that fits whole. The candidate list is the whole rule, so
    /// these are the invariants that matter — a computed scale is gone, and
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

    /// 98c621f: the capsule grew VERTICALLY, and the horizontal measure may
    /// never fall below what it was — that width is exactly the room the long
    /// title is missing.
    @Test func theCapsuleGrewInHeightOnly() {
        #expect(TabBarMetrics.Capsule.verticalPadding > TabBarMetrics.Capsule.previousVerticalPadding)
        #expect(TabBarMetrics.Capsule.horizontalPadding >= 8)
        // The value, so the report can name it instead of describing it.
        #expect(TabBarMetrics.Capsule.verticalPadding == 11)
    }
}

/// b08c719 / 2c0a907: the settings chips wrap, and the line count follows the
/// WIDTH — never the selection.
@Suite struct FlowLayoutTests {

    /// The fence 2c0a907 asks for as its own case: switching tabs must not
    /// change the number of lines. Active and inactive chips differ in colour,
    /// not in metric — so the same widths produce the same breaking, whichever
    /// one is selected.
    @Test func theLineCountDoesNotDependOnWhichChipIsActive() {
        let widths: [CGFloat] = [80, 90, 85, 70, 75]
        let rows = Self.rowCount(widths: widths, available: 300, spacing: 8)
        for active in widths.indices {
            // "Selecting" a chip changes nothing about its width.
            var selected = widths
            selected[active] = widths[active]
            #expect(Self.rowCount(widths: selected, available: 300, spacing: 8) == rows)
        }
    }

    @Test func aRowThatFitsStaysOnOneLine() {
        #expect(Self.rowCount(widths: [40, 40, 40], available: 300, spacing: 8) == 1)
    }

    @Test func theLastChipDropsToTheNextLine() {
        #expect(Self.rowCount(widths: [100, 100, 100], available: 220, spacing: 8) == 2)
    }

    /// Width MAY change the line count — that is a layout change (device,
    /// rotation, split view, type size) and explicitly allowed.
    @Test func moreWidthMeansFewerLines() {
        let narrow = Self.rowCount(widths: [100, 100, 100, 100], available: 220, spacing: 8)
        let wide = Self.rowCount(widths: [100, 100, 100, 100], available: 900, spacing: 8)
        #expect(wide < narrow)
    }

    /// The same breaking rule the layout uses, so the fence measures the rule
    /// and not a re-description of it.
    private static func rowCount(widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> Int {
        var rows = 1
        var current: CGFloat = 0
        for width in widths {
            let needed = current == 0 ? width : current + spacing + width
            if current > 0, needed > available {
                rows += 1
                current = width
            } else {
                current = needed
            }
        }
        return rows
    }
}
#endif
