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
}
