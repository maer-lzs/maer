// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The day labels of the 14-day chart: at AX3 a two-digit day split into a
/// digit over a digit. The rule thins them at an accessibility size, and the
/// label stands in one line in its own width over its empty neighbours.
struct StatsChartLabelTests {
    @Test("die Tagesbeschriftung der 14 Tage: jede zweite, in AX3 jede dritte")
    func theDayLabelsThinAtAccessibilitySizes() {
        let normal = (0..<14).filter { StatsView.labelsDay(at: $0, accessibilitySize: false) }
        let large = (0..<14).filter { StatsView.labelsDay(at: $0, accessibilitySize: true) }
        #expect(normal == [0, 2, 4, 6, 8, 10, 12])
        #expect(large == [0, 3, 6, 9, 12])
    }

    @Test("die Tagesbeschriftung steht in einer Zeile in eigener Breite ueber der Saeule", .needsTheSources)
    func theDayLabelStandsInOneLine() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/StatsView.swift"), encoding: .utf8))
        let chart = try #require(functionBody(of: "private var barChart: some View", in: code))
        let label = try #require(chart.range(of: "Text(day.date.formatted(.dateTime.day()))"), "the day label moved")
        let after = String(chart[label.upperBound...])
        #expect(after.contains(".lineLimit(1)") && after.contains(".fixedSize()"),
                "the day label may wrap again (at AX3 a digit over a digit)")
        #expect(chart.contains(".overlay {"), "the label left the overlay and widens its column")
    }
}
#endif
