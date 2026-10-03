// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The load runs of one page. A reset (a reload, a new sort or filter)
/// starts a new generation; a run that lands in an older generation decides
/// nothing, and its late end does not free the run of the new one. A paged
/// load asks `begin` so one page is fetched at a time per generation; a
/// whole load asks `reset`, so the newest call wins.
nonisolated struct PageRuns: Equatable, Sendable {
    private(set) var generation = 0
    private var running: Int?

    /// Whether a run of the current generation is under way.
    var isRunning: Bool { running == generation }

    @discardableResult
    mutating func reset() -> Int {
        generation += 1
        return generation
    }

    /// A run of the current generation, or nil while one already runs in it.
    mutating func begin() -> Int? {
        guard running != generation else { return nil }
        running = generation
        return generation
    }

    mutating func end(_ run: Int) {
        if running == run { running = nil }
    }

    func isCurrent(_ run: Int) -> Bool { run == generation }
}
