// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a directory says about a feed's health. Nil fields are the normal
/// case — a directory that does not answer this question must not be read as
/// bad news.
nonisolated struct FeedLiveness: Equatable, Sendable {
    /// PodcastIndex `dead`: 0 = alive. Anything else means the index gave up.
    var dead: Int?
    /// The status the index saw last. 0 means "never reached".
    var lastHttpStatus: Int?
    var parseErrors: Int?
    var crawlErrors: Int?

    var isEmpty: Bool {
        dead == nil && lastHttpStatus == nil && parseErrors == nil && crawlErrors == nil
    }
}

/// Offering something that turns out to be undeliverable is the defect worth
/// avoiding — but so is an empty row. The directory already knows which feeds
/// it can no longer reach; we used to throw that away and re-guess per device
/// at display time.
///
/// The answer is therefore an ORDER, never a filter: a doubtful feed moves
/// behind the healthy ones and falls off the visible tail on its own. Nothing
/// is dropped, so a directory having a bad day cannot empty a row.
nonisolated enum PodcastFeedLiveness {

    enum Verdict: Int, Comparable {
        /// The directory says it is alive, or says nothing at all. Both are
        /// "usable" — absence of news is not bad news.
        case usable = 0
        /// Reachable, but the index keeps stumbling over it.
        case doubtful = 1
        /// The index gave up on it, or never got a usable answer.
        case gone = 2

        static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }
    }

    static func verdict(_ liveness: FeedLiveness?) -> Verdict {
        guard let liveness, !liveness.isEmpty else { return .usable }
        if let dead = liveness.dead, dead != 0 { return .gone }
        if let status = liveness.lastHttpStatus {
            // 0 = the index never reached it. 4xx/5xx that STUCK is the same
            // statement in another shape. 3xx is a redirect the fetch follows.
            if status == 0 || status >= 400 { return .gone }
        }
        if (liveness.parseErrors ?? 0) > 0 || (liveness.crawlErrors ?? 0) > 0 { return .doubtful }
        return .usable
    }

    /// Stable ordering by verdict: usable first, gone last, and inside each
    /// group the incoming order (the ranking) is preserved — the health signal
    /// must not quietly become a second ranking.
    static func demotingDoubtful<T>(_ items: [T], liveness: (T) -> FeedLiveness?) -> [T] {
        items.enumerated()
            .sorted { a, b in
                let left = verdict(liveness(a.element)), right = verdict(liveness(b.element))
                return left == right ? a.offset < b.offset : left < right
            }
            .map(\.element)
    }
}
