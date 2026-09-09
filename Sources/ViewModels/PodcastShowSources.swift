// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE place that asks the two podcast sources for their shows and hands
/// the answer to `PodcastShowMerge`. Five call sites used to ask the pots
/// themselves; they now ask here.
///
/// The switch is asked HERE and not in the rule, because it is a fact about
/// this device at this moment and not about what „the same show" means.
@MainActor
enum PodcastShowSources {
    /// Every show the user should see right now, from both sources, each
    /// once. A source that is switched off contributes nothing.
    static func active() -> [PodcastShow] {
        PodcastShowMerge.merge(abs: absShows(), rss: PodcastSubscriptions.shared.shows)
    }

    /// The ABS side alone, already gated by the source switch.
    ///
    /// `activeShows` means „not archived" and knows nothing about the switch,
    /// which is exactly the gap the three un-gated copies fell into.
    static func absShows() -> [PodcastShow] {
        AppStorageKeys.absPodcastsActive ? ABSPodcastProvider.shared.activeShows : []
    }

    /// Everything we OWN, from both sources, full lists.
    ///
    /// Deliberately not `active()`: no source switch and no archive filter,
    /// because a subscription survives both. Six places built this union by
    /// hand, every one of them to answer „which shows must NOT appear in the
    /// recommendations".
    static func ownedShows() -> [PodcastShow] {
        PodcastSubscriptions.shared.shows + ABSPodcastProvider.shared.shows
    }

    /// The normalised addresses of everything we own. The one argument
    /// `PodcastRecommendationsStore.excludingSubscribed` wants.
    static func subscribedFeeds() -> Set<String> {
        PodcastShowMerge.normalizedFeeds(ownedShows())
    }

    /// Is this feed subscribed on either source? The subscribe badge and the
    /// source page asked this in their own words, in the same words.
    ///
    /// This deliberately does NOT go through `active()`, and the difference
    /// is the whole point: a subscription survives both archiving and a
    /// switched-off source. An archived ABS show is still subscribed on the
    /// server, so offering „subscribe" for it would subscribe a second time.
    /// `active()` answers what to SHOW, this answers what we OWN.
    static func isSubscribed(feedURL: String) -> Bool {
        PodcastShowMerge.contains(feedURL: feedURL, in: ownedShows())
    }
}
