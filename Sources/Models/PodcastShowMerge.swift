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

    /// The same folding, but it hands back the WHOLE group instead of only
    /// the survivor: copies of one feed, in the order they were given, the
    /// survivor first. Groups appear in the order their survivor appeared.
    ///
    /// `merge` throws the losers away, which is right for a list to look at.
    /// The recommendation seed needs them: listening time is stored per show
    /// ID, and the two copies of one show carry two IDs. Folding to the
    /// survivor alone would silently drop the history filed under the other
    /// one, and a show would lose weight by being folded.
    static func foldByFeed(_ shows: [PodcastShow]) -> [[PodcastShow]] {
        var order: [String] = []
        var groups: [String: [PodcastShow]] = [:]
        for show in shows {
            let key = PodcastSubscriptions.normalizeFeedURL(show.feedURL)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(show)
        }
        return order.compactMap { groups[$0] }
    }

    /// The normalised feed addresses of these shows, as a set.
    ///
    /// Six call sites wrote this out by hand, always over the same two pots,
    /// and always to hand it to `excludingSubscribed`. They agreed, which is
    /// luck and not a guarantee: the address comparison is exactly where a
    /// spelling difference hides, and a set that misses one address puts a
    /// show the person already follows back into their recommendations.
    static func normalizedFeeds(_ shows: [PodcastShow]) -> Set<String> {
        Set(shows.map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
    }

    /// The recommendation seed's shape: folded per feed, and without any
    /// feed that ANY copy marks as a private mirror.
    ///
    /// The mirror question is asked of the ADDRESS, not of the copy, and
    /// that is the whole point. `origin` is only ever set on the local side,
    /// ABS never sets it, and the server sync mirrors capsules like every
    /// other subscription, so the ABS twin of a capsule comes back with no
    /// mark on it. A per-copy filter lets that twin through into a PUBLIC
    /// catalog search, which is the incident the seed's filter exists for.
    static func seedGroups(abs: [PodcastShow], rss: [PodcastShow]) -> [[PodcastShow]] {
        let mirrored = Set((abs + rss).filter { $0.origin != nil }
            .map { PodcastSubscriptions.normalizeFeedURL($0.feedURL) })
        // ABS first, so the survivor is the copy the display list keeps too.
        return foldByFeed(abs + rss).filter { group in
            guard let first = group.first else { return false }
            return !mirrored.contains(PodcastSubscriptions.normalizeFeedURL(first.feedURL))
        }
    }

    /// Give each survivor the listening time of its whole group, so folding
    /// costs a show nothing.
    ///
    /// MAX and not the sum: the copies are two spellings of the same
    /// episodes, and the same episode can carry a stored position under both
    /// IDs. Summing would count one listening twice, which is the very thing
    /// the fold is here to stop. Same shape as the bridge-aware progress
    /// lookup in `PodcastAutoContinue.next`.
    static func liftingTwins(_ listening: [String: Double],
                             groups: [[PodcastShow]]) -> [String: Double] {
        var out = listening
        for group in groups {
            guard let survivor = group.first else { continue }
            let best = group.reduce(0.0) { max($0, listening[$1.id] ?? 0) }
            if best > 0 { out[survivor.id] = best }
        }
        return out
    }
}
