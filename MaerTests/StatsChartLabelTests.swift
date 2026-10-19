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
        let normal = (0..<14).filter { StatsView.labelsDay(at: $0, of: 14, accessibilitySize: false) }
        let large = (0..<14).filter { StatsView.labelsDay(at: $0, of: 14, accessibilitySize: true) }
        #expect(normal == [1, 3, 5, 7, 9, 11, 13])
        #expect(large == [1, 4, 7, 10, 13])
        #expect(normal.contains(13) && large.contains(13), "the anchor is today, the right end; today always carries its date")
    }

    @Test("jede Saeule sagt VoiceOver ihren Tag und ihre Hoerzeit")
    func eachBarSpeaksItsDayAndTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        let parts = StatsView.barAccessibility(date: date, seconds: 3_660)
        #expect(parts.label == date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        #expect(parts.label.contains("5"), "the label names the day: \(parts.label)")
        #expect(parts.value == DurationText.length(seconds: 3_660), "the value is the listening time")
        #expect(StatsView.barAccessibility(date: date, seconds: 0).value == DurationText.length(seconds: 0))
    }

    @Test("die Saeulen sind je ein Element mit Tag und Hoerzeit", .needsTheSources)
    func theBarsAreElements() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/StatsView.swift"), encoding: .utf8))
        let chart = try #require(functionBody(of: "private var barChart: some View", in: code))
        #expect(chart.contains(".accessibilityElement(children: .ignore)"), "a bar is no element of its own")
        #expect(chart.contains(".accessibilityLabel(Text(Self.barAccessibility(") && chart.contains(".accessibilityValue(Text(Self.barAccessibility("),
                "a bar says neither its day nor its time")
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
