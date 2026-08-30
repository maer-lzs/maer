// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Package 2: the shared shuffle for playback. Seeded so CI is deterministic.
struct MediaShuffleTests {
    /// A deterministic RNG (SplitMix64). Purely for test repeatability. This is
    /// NOT the shuffle's real randomness (production uses the system RNG); it only
    /// pins the assertions.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test func resultIsAPermutation() {
        let input = Array(1...50)
        var gen = SeededGenerator(seed: 12345)
        let out = MediaShuffle.shuffled(input, using: &gen)
        #expect(out.count == input.count)
        #expect(out.sorted() == input)          // same multiset
    }

    @Test func reordersEnoughElements() {
        // "Ausreichend viele Elemente" → the permutation is not the identity.
        let input = Array(1...50)
        var gen = SeededGenerator(seed: 99)
        let out = MediaShuffle.shuffled(input, using: &gen)
        #expect(out != input)
    }

    @Test func deterministicForSameSeed() {
        let input = Array(1...20)
        var g1 = SeededGenerator(seed: 7)
        var g2 = SeededGenerator(seed: 7)
        #expect(MediaShuffle.shuffled(input, using: &g1) == MediaShuffle.shuffled(input, using: &g2))
    }

    @Test func edgeCounts() {
        var gen = SeededGenerator(seed: 1)
        #expect(MediaShuffle.shuffled([Int](), using: &gen).isEmpty)
        var gen2 = SeededGenerator(seed: 1)
        #expect(MediaShuffle.shuffled([42], using: &gen2) == [42])
    }
}
#endif
