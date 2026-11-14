// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The three stages of the conflict rule, each on its own, with the
/// cases that used to go wrong under "better wins".
struct ForeignStateMergeTests {
    private func foreign(_ position: Double, finished: Bool = false,
                         at stamp: Double? = nil) -> ForeignListeningState {
        ForeignListeningState(feedURL: "https://f.example/rss", episodeGUID: nil,
                              enclosureURL: "https://f.example/1.mp3", episodeLink: nil,
                              episodeTitle: "One", position: position, finished: finished,
                              stampedAt: stamp)
    }

    @Test("(a) both with a moment: the newer wins, even with a smaller position")
    func newerWinsEvenWhenBehind() {
        let local: [Double] = [900, 1_000]           // Mär: further, but older
        let entry = ForeignStateMerge.adopt(local: local, foreign: foreign(300, at: 2_000), duration: 3_600)
        #expect(entry?.first == 300)
        #expect(entry?[1] == 2_000)
    }

    @Test("(a) both with a moment: the older loses, even with a larger position")
    func olderLosesEvenWhenAhead() {
        let local: [Double] = [300, 2_000]
        #expect(ForeignStateMerge.adopt(local: local, foreign: foreign(900, at: 1_000), duration: 3_600) == nil)
    }

    @Test("(a) the same moment is an honest tie, local stays")
    func tieKeepsLocal() {
        #expect(ForeignStateMerge.adopt(local: [300, 1_000], foreign: foreign(900, at: 1_000), duration: 3_600) == nil)
    }

    /// The tombstone `[0, moment]` a person writes by marking an episode
    /// unplayed is knowledge with a time. Position zero alone used to read
    /// as "nothing known", so a fill wrote over the reset and an older
    /// foreign state beat a newer one.
    @Test("Tombstone newer than the foreign state: stays")
    func newerTombstoneStays() {
        #expect(ForeignStateMerge.adopt(local: [0, 2_000], foreign: foreign(900, at: 1_000), duration: 3_600) == nil)
    }

    @Test("Tombstone older than the foreign state: the foreign state wins")
    func olderTombstoneLoses() throws {
        let entry = try #require(ForeignStateMerge.adopt(local: [0, 1_000], foreign: foreign(900, at: 2_000), duration: 3_600))
        #expect(entry[0] == 900)
        #expect(entry[1] == 2_000)
    }

    @Test("Foreign state without a moment against a tombstone: nothing")
    func unstampedNeverFillsOverTombstone() {
        #expect(ForeignStateMerge.adopt(local: [0, 1_000], foreign: foreign(900, at: nil), duration: 3_600) == nil)
        // Truly nothing known (no entry, or a bare zero) still fills.
        #expect(ForeignStateMerge.adopt(local: nil, foreign: foreign(900, at: nil), duration: 3_600) != nil)
        #expect(ForeignStateMerge.adopt(local: [0], foreign: foreign(900, at: nil), duration: 3_600) != nil)
    }

    @Test("(b) without a moment the source only fills a gap")
    func withoutMomentOnlyFills() {
        #expect(ForeignStateMerge.adopt(local: [300, 1_000], foreign: foreign(900), duration: 3_600) == nil)
        let filled = ForeignStateMerge.adopt(local: nil, foreign: foreign(900), duration: 3_600)
        #expect(filled?.first == 900)
        // And carries NO „jetzt": a moment of zero loses against
        // every real later one.
        #expect(filled?[1] == 0)
    }

    @Test("(c) heard is never taken back, not even by a newer unheard")
    func finishedIsNeverRetracted() {
        let local: [Double] = [3_600, 1_000]         // finished
        #expect(ForeignStateMerge.adopt(local: local, foreign: foreign(120, at: 9_000), duration: 3_600) == nil)
        #expect(ForeignStateMerge.adopt(local: local, foreign: foreign(3_600, finished: true, at: 9_000),
                                        duration: 3_600) == nil)
    }

    @Test("heard without a duration becomes the sentinel, not nothing")
    func finishedWithoutDurationIsTheSentinel() {
        let entry = ForeignStateMerge.adopt(local: nil, foreign: foreign(0, finished: true, at: 5), duration: 0)
        #expect(entry?.first == ProgressMark.playedSentinel)
    }

    @Test("an old entry without a moment counts as moment zero")
    func oneValueLocalCountsAsZeroMoment() {
        #expect(ForeignStateMerge.adopt(local: [900], foreign: foreign(300, at: 1), duration: 3_600)?.first == 300)
    }

    @Test("a position under one second is no state")
    func tinyPositionIsNothing() {
        #expect(ForeignStateMerge.adopt(local: nil, foreign: foreign(0.5, at: 1), duration: 3_600) == nil)
    }
}
#endif
