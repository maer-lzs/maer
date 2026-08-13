// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// What an Apple entry may write over the local one.
///
/// Measured on a real store: the import wrote raw two-value literals with a
/// fresh stamp unconditionally over the local state — two finished marks were
/// confirmed destroyed. And the played definition read the wrong field:
/// cross-tabulated, every hand-marked episode had state 2 and count 0, every
/// listened-through one state 0 and count 1 — 1,163 finished episodes fell
/// through both conditions.
struct AppleImportAdoptionTests {
    private let hour: Double = 3600
    private let appleTs: Double = 1_750_000_000_000
    private let now: Double = 1_760_000_000_000

    @Test("a partial Apple entry never resets a finished local one")
    func partialNeverResetsFinished() {
        // Apple knows the episode half-heard, Mär has it finished — the
        // measured destruction class.
        #expect(PodcastImport.adoptedEntry(
            local: [hour, appleTs, hour], playhead: 500, duration: hour,
            isPlayed: false, timestampMs: appleTs, nowMs: now) == nil)
        // Also against a finished two-value entry (the healed-later class).
        #expect(PodcastImport.adoptedEntry(
            local: [hour, appleTs], playhead: 500, duration: hour,
            isPlayed: false, timestampMs: appleTs, nowMs: now) == nil)
    }

    @Test("better wins against local, not only within the Apple data")
    func betterWinsAgainstLocal() throws {
        // Apple played, local partial → Apple wins, and the entry carries the
        // duration it was decided against.
        let adopted = try #require(PodcastImport.adoptedEntry(
            local: [1200, now], playhead: 0, duration: hour,
            isPlayed: true, timestampMs: appleTs, nowMs: now))
        #expect(ProgressMark.isPlayed(stored: adopted, currentDuration: hour))
        #expect(ProgressMark.markedDuration(adopted) == hour)
        // Both partial: the further position wins, in both directions.
        #expect(PodcastImport.adoptedEntry(
            local: [1200, now], playhead: 500, duration: hour,
            isPlayed: false, timestampMs: appleTs, nowMs: now) == nil)
        let further = try #require(PodcastImport.adoptedEntry(
            local: [500, now], playhead: 1200, duration: hour,
            isPlayed: false, timestampMs: appleTs, nowMs: now))
        #expect(further[0] == 1200)
    }

    @Test("the entry carries Apple's moment, not the import's")
    func carriesAppleMoment() throws {
        let adopted = try #require(PodcastImport.adoptedEntry(
            local: nil, playhead: 900, duration: hour,
            isPlayed: false, timestampMs: appleTs, nowMs: now))
        // A "now" stamp made every imported entry younger than everything it
        // met — it won merges it had no business winning.
        #expect(ProgressMark.timestamp(adopted) == appleTs)
    }

    /// Apple resets state AND playhead on completion — a played episode
    /// without any known duration still gets its mark, via the sentinel.
    @Test("played without a duration becomes the sentinel, not nothing")
    func playedWithoutDuration() throws {
        let adopted = try #require(PodcastImport.adoptedEntry(
            local: nil, playhead: 0, duration: 0,
            isPlayed: true, timestampMs: appleTs, nowMs: now))
        #expect(adopted[0] == ProgressMark.playedSentinel)
        #expect(ProgressMark.isPlayed(stored: adopted, currentDuration: 0))
    }

    /// The imported-stock rule: many entries at once, one shared moment, no
    /// local state — everything lands, nothing is stamped "now".
    @Test("an imported stock lands with its own moments")
    func importedStock() {
        for index in 0..<200 {
            let entry = PodcastImport.adoptedEntry(
                local: nil, playhead: 0, duration: 1800 + Double(index),
                isPlayed: true, timestampMs: appleTs, nowMs: now)
            #expect(entry != nil)
            #expect(entry.flatMap(ProgressMark.timestamp) == appleTs)
        }
    }

    @Test("both finished means nothing to write")
    func bothFinishedIsNoOp() {
        #expect(PodcastImport.adoptedEntry(
            local: [hour, now, hour], playhead: 0, duration: hour,
            isPlayed: true, timestampMs: appleTs, nowMs: now) == nil)
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
