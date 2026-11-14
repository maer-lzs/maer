// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// How often a download's progress reaches the views. Every publish re-runs
/// every view that observes the download manager, so the count per download
/// is the number that the observer placement multiplies.
struct ProgressPublishRuleTests {
    /// Drives the rule the way the manager does: the phase shows the last
    /// fraction that went out, and every report is asked about.
    static func publishes(for reports: [Double]) -> Int {
        var current: Double = 0
        var last: Double?
        var count = 0
        for report in reports {
            switch ProgressPublishRule.outcome(current: current, lastPublished: last, fraction: report) {
            case .skip:
                continue
            case .indeterminate:
                current = -1
                count += 1
            case .fraction(let value):
                current = value
                last = value
                count += 1
            }
        }
        return count
    }

    static func evenStream(chunks: Int) -> [Double] {
        (1...chunks).map { Double($0) / Double(chunks) }
    }

    @Test("a download reports about a hundred times, however fine the chunks arrive")
    func aDownloadPublishesAboutAHundredTimes() {
        // A 200 MB book in 64 KB chunks, and the same book reported a
        // hundred thousand times: the count stays at the percent steps.
        let coarse = Self.publishes(for: Self.evenStream(chunks: 3_200))
        let fine = Self.publishes(for: Self.evenStream(chunks: 100_000))
        #expect((100...102).contains(coarse), "3200 Stuecke, \(coarse) Meldungen")
        #expect((100...102).contains(fine), "100000 Stuecke, \(fine) Meldungen")
        // Without the rule every chunk goes out.
        #expect(coarse < 3_200 / 30)
    }

    @Test("coarse reports all go out, and the end always")
    func coarseReportsAllGoOutAndTheEndAlways() {
        #expect(Self.publishes(for: Self.evenStream(chunks: 10)) == 10)
        // A report just below the next step is held back, the end is not.
        #expect(ProgressPublishRule.outcome(current: 0.995, lastPublished: 0.995, fraction: 1)
                == .fraction(1))
        #expect(ProgressPublishRule.outcome(current: 0.5, lastPublished: 0.5, fraction: 0.505)
                == .skip)
    }

    @Test("an unknown size is reported once, not per chunk")
    func anUnknownSizeGoesOutOnce() {
        #expect(Self.publishes(for: Array(repeating: -1, count: 500)) == 1)
        #expect(ProgressPublishRule.outcome(current: 0, lastPublished: nil, fraction: -1)
                == .indeterminate)
        #expect(ProgressPublishRule.outcome(current: -1, lastPublished: nil, fraction: -1)
                == .skip)
    }

    @Test("whoever is not loading reports nothing")
    func nothingGoesOutWhileNotDownloading() {
        #expect(ProgressPublishRule.outcome(current: nil, lastPublished: nil, fraction: 0.5) == .skip)
        #expect(ProgressPublishRule.outcome(current: nil, lastPublished: 0.4, fraction: 1) == .skip)
        #expect(ProgressPublishRule.outcome(current: nil, lastPublished: nil, fraction: -1) == .skip)
    }
}
#endif
