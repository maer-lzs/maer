// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which stored entries of the EXISTING stock get their missing reference
/// point. Decided over the local stock alone, without asking any server.
///
/// That is the whole point. The repair used to ride inside the gpodder pull,
/// and that pull is incremental: it only sees episodes with a fresh server
/// action. A stock imported once and never touched again carries a timestamp
/// far older than any `since`, so the repair reached none of it. Measured on a
/// real device: about eighty finished episodes, not one with a reference
/// point. They read correctly today only because no duration has grown yet.
///
/// The condition against a server-free witness lives in `ProgressMark`; this
/// type is the pass over the stock, kept pure so the placement itself is
/// testable. No defaults, no network, no subscriptions.
nonisolated enum PodcastProgressHealing {
    struct Episode: Equatable, Sendable {
        let guid: String
        /// The duration the feed states. Zero means unknown, and unknown heals
        /// nothing. An invented reference point is worse than none.
        let duration: Double
    }

    /// The entries to write, keyed by guid. Empty means there is nothing to do,
    /// which is the normal case after the first pass.
    static func writes(for episodes: [Episode],
                       stored: (String) -> [Double]?) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for episode in episodes {
            guard let entry = stored(episode.guid),
                  let healed = ProgressMark.supplementingFinished(
                    entry, duration: episode.duration) else { continue }
            out[episode.guid] = healed
        }
        return out
    }
}
