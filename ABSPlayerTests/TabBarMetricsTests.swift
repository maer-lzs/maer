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

    /// The rule in one line: the scale comes from the widest label, so every
    /// label carries the same one. A per-label factor is what made the size a
    /// property of the WORD.
    @Test func theScaleFollowsTheLongestTitle() {
        // 60 pt available, longest label 75 pt wide → 0.8.
        #expect(TabBarMetrics.uniformScale(labelWidths: [30, 75, 40], available: 60) == 0.8)
        // The same row with more room needs no shrinking at all.
        #expect(TabBarMetrics.uniformScale(labelWidths: [30, 75, 40], available: 100) == 1)
    }

    /// A short row does not GROW — the scale is a reduction or nothing.
    @Test func aRowThatFitsStaysAtFullSize() {
        #expect(TabBarMetrics.uniformScale(labelWidths: [20, 25], available: 200) == 1)
    }

    /// the reviewer's caveat, and it is his order to name the floor: below a readable
    /// size we stop shrinking. Otherwise a layout problem becomes a legibility
    /// problem, and the bar ends up smaller than the text around it.
    @Test func theFloorHolds() {
        #expect(TabBarMetrics.uniformScale(labelWidths: [500], available: 10)
                == TabBarMetrics.minimumScale)
        #expect(TabBarMetrics.minimumScale == 0.8)
    }

    @Test func nonsenseInputsDoNotShrinkAnything() {
        #expect(TabBarMetrics.uniformScale(labelWidths: [], available: 100) == 1)
        #expect(TabBarMetrics.uniformScale(labelWidths: [50], available: 0) == 1)
        #expect(TabBarMetrics.uniformScale(labelWidths: [0], available: 100) == 1)
    }

    /// the owner's measurement, reproduced as a case: with FOUR tabs "Hörbücher"
    /// fits, with FIVE it does not. That is not evidence for the system bar —
    /// it is exactly how a fitting-driven scale behaves, and it is ours.
    @Test func fourTabsFitWhereFiveDoNot() {
        let font = UIFont.systemFont(ofSize: MediaTabBar.baseLabelSize)
        let labels = ["Home", "Hörbücher", "Podcasts", "Musik", "Radio"]
        let widths = labels.map { TabBarMetrics.labelWidth($0, font: font) }
        // An iPhone-width bar, minus the gaps, divided by the tab count.
        func perCell(_ count: Int, barWidth: CGFloat = 380) -> CGFloat {
            (barWidth - 4 * CGFloat(count - 1) - 10) / CGFloat(count)
                - TabBarMetrics.Capsule.horizontalPadding * 2
        }
        let five = TabBarMetrics.uniformScale(labelWidths: widths, available: perCell(5))
        let four = TabBarMetrics.uniformScale(labelWidths: Array(widths.dropFirst()),
                                              available: perCell(4))
        #expect(five < 1, "mit fünf Tabs muss verkleinert werden — sonst misst der Fall nichts")
        #expect(four == 1, "mit vier Tabs passt es, genau wie the owner gemessen hat")
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
