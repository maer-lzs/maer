// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
@testable import ABSPlayer

/// The stock repair — and above all: that it happens WITHOUT a server action.
///
/// Measured on a real device: the repair rode inside the incremental gpodder
/// pull, so it only reached episodes with a fresh server action. About eighty
/// finished episodes, imported once, carried no reference point at all. The
/// defect was not the rule but its placement, so that is what these tests hold.
struct PodcastProgressHealingTests {
    private let hour: Double = 3600
    private let stamp: Double = 1_753_180_608_000

    @Test("the local stock heals with no server action involved")
    func healsWithoutServer() {
        let episodes = [
            PodcastProgressHealing.Episode(guid: "a", duration: hour),
            PodcastProgressHealing.Episode(guid: "b", duration: 1800),
        ]
        // Two finished entries without a reference point — exactly the shape
        // an import leaves behind.
        let stock: [String: [Double]] = ["a": [hour, stamp], "b": [1800, stamp]]
        let writes = PodcastProgressHealing.writes(for: episodes) { stock[$0] }
        #expect(writes["a"] == [hour, stamp, hour])
        #expect(writes["b"] == [1800, stamp, 1800])
    }

    @Test("a half-heard episode is left alone")
    func inProgressUntouched() {
        // Nobody can say which duration this was written against, and a guess
        // would be the invention the whole type exists to prevent.
        let writes = PodcastProgressHealing.writes(
            for: [PodcastProgressHealing.Episode(guid: "a", duration: hour)]) { _ in [1200, stamp] }
        #expect(writes.isEmpty)
    }

    @Test("entries that already carry their duration stay as they are")
    func alreadyHealed() {
        let writes = PodcastProgressHealing.writes(
            for: [PodcastProgressHealing.Episode(guid: "a", duration: hour)]) { _ in [hour, stamp, hour] }
        #expect(writes.isEmpty)
    }

    @Test("an unknown duration heals nothing")
    func unknownDuration() {
        let writes = PodcastProgressHealing.writes(
            for: [PodcastProgressHealing.Episode(guid: "a", duration: 0)]) { _ in [hour, stamp] }
        #expect(writes.isEmpty)
        // Nor does an episode without any stored entry produce one.
        let none = PodcastProgressHealing.writes(
            for: [PodcastProgressHealing.Episode(guid: "a", duration: hour)]) { _ in nil }
        #expect(none.isEmpty)
    }

    /// The threshold is the read side's, not exact equality — precisely the
    /// entries that would fall below it when a duration grows.
    @Test("the threshold matches the one that decides played")
    func thresholdMatchesReadSide() {
        let episode = [PodcastProgressHealing.Episode(guid: "a", duration: hour)]
        #expect(!PodcastProgressHealing.writes(for: episode) { _ in [hour - 0.5, stamp] }.isEmpty)
        #expect(PodcastProgressHealing.writes(for: episode) { _ in [hour - 5, stamp] }.isEmpty)
        // And what the read side calls played stays played afterwards.
        let healed = PodcastProgressHealing.writes(for: episode) { _ in [hour - 0.5, stamp] }["a"]
        #expect(ProgressMark.isPlayed(stored: try! #require(healed), currentDuration: hour + 180))
    }

    /// The sentinel needs no reference point — it was never written against a
    /// duration, so entering one would be a lie.
    @Test("the sentinel is not touched")
    func sentinelUntouched() {
        let writes = PodcastProgressHealing.writes(
            for: [PodcastProgressHealing.Episode(guid: "a", duration: hour)]) { _ in
                [ProgressMark.playedSentinel, self.stamp]
            }
        #expect(writes.isEmpty)
    }

    /// What the repair is FOR: a duration that grows must no longer undo a
    /// finished episode.
    @Test("a grown duration no longer topples a healed entry")
    func grownDurationSurvives() throws {
        let healed = try #require(PodcastProgressHealing.writes(
            for: [PodcastProgressHealing.Episode(guid: "a", duration: hour)]) { _ in [self.hour, self.stamp] }["a"])
        // Three minutes of fresh advertising in today's copy.
        #expect(ProgressMark.isPlayed(stored: healed, currentDuration: hour + 180))
        // Without the reference point the same entry reads as started again.
        #expect(!ProgressMark.isPlayed(stored: [hour, stamp], currentDuration: hour + 180))
    }
}
