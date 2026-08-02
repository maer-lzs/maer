// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Home "Rediscover" (Teil 3): purely local candidates from the library, three
/// sources in fixed priority — (a) started items whose last progress is older
/// than `pausedAfter`, (b) additions sitting unheard for longer than
/// `unheardAfter`, (c) the next volume of a series whose predecessor was
/// finished. The daily selection is deterministic: the same calendar day always
/// yields the same picks (seeded shuffle per source, then a round-robin mix so
/// media types and sources interleave). No candidates → the section hides.
nonisolated enum RediscoverSections {
    /// (a) A started item counts as paused after 3 weeks without progress.
    static let pausedAfter: TimeInterval = 21 * 24 * 3600
    /// (b) An addition counts as lying unheard after 30 days.
    static let unheardAfter: TimeInterval = 30 * 24 * 3600

    enum Reason: Equatable {
        /// Paused for N weeks (≥ 3).
        case paused(weeks: Int)
        /// Unheard since its (absolute) added date.
        case unheardSince(added: Date)
        /// Volume N of a series whose predecessor is finished.
        case nextInSeries(volume: Int)
        /// 5dcbf21: a subscribed show long unheard that still has unplayed
        /// episodes ("Lange nicht gehört · zuletzt vor N Wochen").
        case showDormant(weeks: Int)
    }

    struct Pick: Equatable {
        let id: String
        let reason: Reason
    }

    /// Inputs are plain value tuples so every caller (books, episodes, albums)
    /// can feed the same shapes; timestamps in seconds since 1970.
    /// 5dcbf21: share cap for the NEW show source — sinngemäß the 2-of-10
    /// continue rule: shows never displace books/episodes beyond a fifth.
    static func showCap(limit: Int) -> Int { max(2, limit / 5) }

    static func picks(
        paused: [(id: String, lastPlayed: TimeInterval)],
        unheard: [(id: String, addedAt: TimeInterval)],
        seriesNext: [(id: String, volume: Int)],
        showsDormant: [(id: String, lastPlayed: TimeInterval)] = [],
        now: Date,
        daySeed: Int,
        limit: Int
    ) -> [Pick] {
        guard limit > 0 else { return [] }
        let nowT = now.timeIntervalSince1970

        let pausedPicks: [Pick] = paused
            .filter { nowT - $0.lastPlayed > pausedAfter && $0.lastPlayed > 0 }
            .map { Pick(id: $0.id, reason: .paused(weeks: Int((nowT - $0.lastPlayed) / (7 * 24 * 3600)))) }
        let unheardPicks: [Pick] = unheard
            .filter { nowT - $0.addedAt > unheardAfter && $0.addedAt > 0 }
            .map { Pick(id: $0.id, reason: .unheardSince(added: Date(timeIntervalSince1970: $0.addedAt))) }
        let seriesPicks: [Pick] = seriesNext
            .map { Pick(id: $0.id, reason: .nextInSeries(volume: $0.volume)) }
        // 5dcbf21: dormant shows share the paused threshold (one anchor, no
        // second constant) — "long unheard" means the same everywhere.
        let showPicks: [Pick] = showsDormant
            .filter { nowT - $0.lastPlayed > pausedAfter && $0.lastPlayed > 0 }
            .map { Pick(id: $0.id, reason: .showDormant(weeks: Int((nowT - $0.lastPlayed) / (7 * 24 * 3600)))) }

        // Deterministic daily rotation: seeded shuffle per source (stable within
        // a day), then round-robin across the sources in priority order.
        let sources = [pausedPicks, unheardPicks, seriesPicks, showPicks]
            .enumerated()
            .map { shuffled($0.element, seed: UInt64(bitPattern: Int64(daySeed)) &+ UInt64($0.offset &* 7919)) }

        let cap = showCap(limit: limit)
        var shows = 0
        var out: [Pick] = []
        var seen = Set<String>()
        var index = 0
        while out.count < limit {
            var appended = false
            for source in sources where index < source.count {
                let pick = source[index]
                // Share cap: shows above their fifth are skipped, never queued.
                if case .showDormant = pick.reason, shows >= cap { appended = true; continue }
                if seen.insert(pick.id).inserted {
                    if case .showDormant = pick.reason { shows += 1 }
                    out.append(pick)
                    if out.count == limit { return out }
                }
                appended = true
            }
            if !appended { break }
            index += 1
        }
        return out
    }

    /// Volume number from a full ABS series name ("… #5" convention) — nil
    /// when the name carries no sequence.
    static func volume(fromSeriesName name: String?) -> Int? {
        guard let name, let hash = name.lastIndex(of: "#") else { return nil }
        let digits = name[name.index(after: hash)...].prefix(while: \.isNumber)
        return Int(digits)
    }

    /// The rotation seed: the calendar day (local), so the selection changes at
    /// most once per day.
    static func daySeed(for date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    /// Small deterministic LCG shuffle — `Array.shuffled(using:)` with a seeded
    /// generator, so tests can pin exact outputs.
    private static func shuffled(_ picks: [Pick], seed: UInt64) -> [Pick] {
        var generator = SplitMix64(seed: seed)
        return picks.shuffled(using: &generator)
    }

    /// SplitMix64 — tiny, stable, seedable RNG (deterministic across runs).
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
