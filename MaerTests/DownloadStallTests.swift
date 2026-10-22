// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A download that starts over and ends at the same byte again and again
/// fails after `DownloadStall.limit` such runs; a run that reaches further
/// or ends earlier never makes it fail.
struct DownloadStallTests {
    /// Feeds runs that each start from the first byte and end at the given
    /// byte, in three chunks or (`once`) as the one report the loopback
    /// gives, and says at which run the rule gave up (nil: never).
    static func gaveUp(endingAt ends: [Int64], once: Bool = false) -> Int? {
        var stall = DownloadStall()
        for (number, end) in ends.enumerated() {
            let totals: [Int64] = once ? [end] : [1_000, end / 2, end]
            var before: Int64 = 0
            for total in totals {
                if stall.written(total - before, total: total) { return number + 1 }
                before = total
            }
        }
        return nil
    }

    @Test("der gemessene Fall: jeder Lauf endet bei 50000, die Regel gibt auf, sobald der fuenfte Lauf beginnt")
    func theMeasuredCaseFails() {
        #expect(Self.gaveUp(endingAt: Array(repeating: 50_000, count: 7), once: true) == 5,
                "as measured: one report of 50000 per run; run 5 starting shows the third round without gain")
        #expect(Self.gaveUp(endingAt: Array(repeating: 50_000, count: 7)) == 5, "the same in chunks")
        #expect(DownloadStall.limit == 3)
    }

    @Test("ein Lauf, der weiter kommt, beginnt die Zaehlung neu; ein frueher endender zaehlt nicht")
    func progressAndWeakNetworksNeverFail() {
        #expect(Self.gaveUp(endingAt: (1...10).map { Int64($0) * 10_000 }) == nil, "every run reaches further")
        #expect(Self.gaveUp(endingAt: [50_000, 40_000, 30_000, 20_000, 45_000, 10_000, 49_000]) == nil,
                "runs that end earlier than the best are a weak network, not a stall")
        #expect(Self.gaveUp(endingAt: [50_000, 50_000, 50_000, 60_000, 60_000, 60_000]) == nil,
                "a further run starts the count again")
        #expect(Self.gaveUp(endingAt: [100_000]) == nil, "one run is no circle")
        #expect(Self.gaveUp(endingAt: [10_000, 20_000, 30_000, 40_000, 50_000], once: true) == nil,
                "one report per run, each further")
    }
}
#endif
