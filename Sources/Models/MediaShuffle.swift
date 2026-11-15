// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE shuffle for playback: every caller. Whole music library,
/// a playlist, an album. Hands in its own item/track set and gets a random
/// permutation back. Plain randomness on purpose: this is NOT the deterministic,
/// seeded rotation `RediscoverSections` uses (that solves a different problem. A
/// stable "rediscover" set per period). Kept deliberately separate. Foundation-only.
nonisolated enum MediaShuffle {
    /// A uniformly random permutation of `items` (Fisher–Yates via the standard
    /// library), using the system RNG.
    static func shuffled<T>(_ items: [T]) -> [T] {
        var generator = SystemRandomNumberGenerator()
        return shuffled(items, using: &generator)
    }

    /// Testable seam: same permutation with an injected generator, so a seeded
    /// run is deterministic in CI.
    static func shuffled<T>(_ items: [T], using generator: inout some RandomNumberGenerator) -> [T] {
        items.shuffled(using: &generator)
    }

    /// A mixed rest put back in order: the titles still waiting in the
    /// order they had before the mix, then any title that came in since
    /// (an album drawn into its songs) where the mix left it. A title
    /// that started or left meanwhile stays gone.
    static func backInOrder(now: [String], before: [String]) -> [String] {
        let waiting = Set(now)
        let kept = before.filter { waiting.contains($0) }
        let known = Set(kept)
        return kept + now.filter { !known.contains($0) }
    }
}
