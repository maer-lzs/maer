// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The Apple reader hands its rows to the one seam; what it may write is
/// decided by the shared rule (`ForeignStateMergeTests`). What stays
/// Apple's own: the date conversion, and the shape of its rows.
struct AppleImportAdoptionTests {
    private let hour: Double = 3600
    private let appleTs: Double = 1_750_000_000_000

    /// Apple resets state AND playhead on completion. A played episode
    /// without any known duration still gets its mark, via the sentinel,
    /// and carries Apple's moment, not the import's.
    @Test("an Apple row without duration lands as the sentinel with Apple's moment")
    func playedWithoutDuration() throws {
        let row = ForeignListeningState(feedURL: nil, episodeGUID: nil,
                                        enclosureURL: "https://cdn.example/1.mp3",
                                        episodeLink: nil, episodeTitle: "One",
                                        position: 0, duration: nil, finished: true, stampedAt: appleTs)
        let adopted = try #require(ForeignStateMerge.adopt(local: nil, foreign: row, duration: 0))
        #expect(adopted[0] == ProgressMark.playedSentinel)
        #expect(ProgressMark.isPlayed(stored: adopted, currentDuration: 0))
        #expect(ProgressMark.timestamp(adopted) == appleTs)
    }

    /// The imported-stock rule: many rows at once, one shared moment, no
    /// local state. Everything lands, nothing is stamped "now".
    @Test("an imported stock lands with its own moments")
    func importedStock() {
        for index in 0..<200 {
            let row = ForeignListeningState(feedURL: nil, episodeGUID: nil,
                                            enclosureURL: "https://cdn.example/\(index).mp3",
                                            episodeLink: nil, episodeTitle: nil,
                                            position: 0, duration: 1800 + Double(index),
                                            finished: true, stampedAt: appleTs)
            let entry = ForeignStateMerge.adopt(local: nil, foreign: row, duration: 1800 + Double(index))
            #expect(entry != nil)
            #expect(entry.flatMap(ProgressMark.timestamp) == appleTs)
        }
    }

    @Test("Apple's Core-Data dates convert, implausible ones are discarded")
    func timestampConversion() {
        // 2001-epoch seconds land in the plausible window as 1970-based ms.
        let expected: Double = (700_000_000 + 978_307_200) * 1000
        #expect(PodcastImport.appleTimestampMs(700_000_000) == expected)
        #expect(PodcastImport.appleTimestampMs(nil) == nil)
        #expect(PodcastImport.appleTimestampMs(0) == nil)
        #expect(PodcastImport.appleTimestampMs(-5) == nil)
        // Before the Podcasts app existed, or in the far future: no date is
        // better than a wrong one.
        #expect(PodcastImport.appleTimestampMs(100_000) == nil)
        #expect(PodcastImport.appleTimestampMs(4_000_000_000) == nil)
    }
}
