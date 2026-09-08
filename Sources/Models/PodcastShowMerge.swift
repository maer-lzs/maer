// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Podcast shows reach the app from two sources: RSS subscriptions and the
/// ABS server. A show can arrive from both, and then it must appear ONCE.
///
/// This rule stood five times in the tree, copied by hand: twice in the
/// podcast tab, once in auto-continue, once in CarPlay and once in the
/// background refresh. Three of the five said in their own comment that they
/// mirror the others, and they did not: two asked whether the ABS source is
/// switched on at all, three did not. A user who turns the ABS podcast
/// source off kept seeing ABS shows in the tab and in auto-continue, while
/// CarPlay and the refresh had already dropped them.
///
/// So the merge lives here, once, without a source of its own to ask. Who is
/// switched on is decided by `PodcastShowSources`, and the pure part below
/// only says what „once" means.
nonisolated enum PodcastShowMerge {
    /// The cross-source show list. A show is the same show when its feed URL
    /// normalises to the same string; on a collision the ABS side wins,
    /// because it carries the server's progress.
    ///
    /// Order is kept on purpose: ABS shows first in their own order, then the
    /// RSS-only ones in theirs. Every one of the five copies did that, and a
    /// list that reorders itself under the user is its own defect.
    static func merge(abs: [PodcastShow], rss: [PodcastShow]) -> [PodcastShow] {
        let absFeeds = Set(abs.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        return abs + rss.filter {
            !absFeeds.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL))
        }
    }

    /// Is this feed among the given shows? Asked when a page has to decide
    /// between „subscribe" and „manage subscription".
    static func contains(feedURL: String, in shows: [PodcastShow]) -> Bool {
        let target = PodcastSubscriptions.normalizeFeedURL(feedURL)
        return shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == target }
    }
}
