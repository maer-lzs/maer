// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The number on a show tile per mode, on one mixed show: eight
/// episodes, three played, one in progress, four unplayed, of which two
/// are newer than the last played one.
struct PodcastTileCountTests {
    private let unplayed = 4
    private let newSince = 2

    @Test("Default: all unheard, like Apple and Pocket Casts")
    func allUnplayedIsTheStandard() {
        #expect(PodcastTileCount.mode(raw: nil) == .allUnplayed)
        #expect(PodcastTileCount.mode(raw: "garbage") == .allUnplayed)
        #expect(PodcastTileCount.allUnplayed.badge(unplayed: unplayed, newSinceLastPlayed: newSince) == 4)
    }

    @Test("second choice: new since the last one heard")
    func newSinceLastPlayed() {
        #expect(PodcastTileCount.mode(raw: "newSinceLastPlayed") == .newSinceLastPlayed)
        #expect(PodcastTileCount.newSinceLastPlayed.badge(unplayed: unplayed, newSinceLastPlayed: newSince) == 2)
    }

    @Test("off shows nothing, and zero shows nothing in any mode")
    func offAndZero() {
        #expect(PodcastTileCount.off.badge(unplayed: unplayed, newSinceLastPlayed: newSince) == nil)
        for mode in PodcastTileCount.allCases {
            #expect(mode.badge(unplayed: 0, newSinceLastPlayed: 0) == nil)
        }
    }

    /// Red probe on the counts the sections hand over: an episode in
    /// progress is neither unplayed nor new, so it reaches no mode.
    @Test("started counts as unheard in no mode")
    func inProgressCountsNowhere() {
        let states: [String: EpisodePlayState] = ["a": .played, "b": .inProgress(fraction: 0.5, remaining: 100), "c": .unplayed]
        let unplayedIDs = states.filter { $0.value == .unplayed }.map(\.key)
        #expect(unplayedIDs == ["c"])
        for mode in PodcastTileCount.allCases where mode != .off {
            #expect(mode.badge(unplayed: unplayedIDs.count, newSinceLastPlayed: unplayedIDs.count) == 1)
        }
    }
}
#endif
