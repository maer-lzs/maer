// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// In which state a show page stands. There is ONE show page; the state says
/// where its episodes come from and what the page may do.
nonisolated enum PodcastShowMode: String, Sendable, CaseIterable {
    /// The show is in the subscription store. Episodes come from there.
    case subscribed
    /// The show is only being looked at. Episodes come from the freshly
    /// parsed feed and live for the visit.
    case browsed
}

/// What a show page may do, derived from its state.
///
/// The browsed state does not HAVE these abilities rather than having them
/// switched off at four places in the view. A fifth place somebody adds later
/// asks the same value, so it cannot forget the check.
///
/// The line is what the app FETCHES for you, not what it remembers about you:
/// playing an episode writes a position in either state, because a position
/// belongs to the listener. Subscribing is what makes the app carry a show
/// forward, download it, and keep sort and filter for it.
nonisolated struct PodcastShowCapabilities: Equatable, Sendable {
    /// Manage or end an existing subscription. Without it the page offers
    /// subscribing instead.
    var managesSubscription: Bool
    /// The per-show settings sheet (sort, filter, auto-download, refresh).
    var showsSettingsSheet: Bool
    /// Sort and filter are kept per show across visits. Without it they live
    /// for the visit only, because looking at a show writes nothing.
    var remembersPreferences: Bool
    /// Download an episode for offline listening.
    var downloads: Bool
    /// Fetch MORE episodes than the feed carries right now (the server's
    /// older episodes, the full history from the index).
    var fetchesMoreEpisodes: Bool
    /// Bulk-mark every episode as played or unplayed.
    var marksAllEpisodes: Bool

    static func of(_ mode: PodcastShowMode) -> PodcastShowCapabilities {
        switch mode {
        case .subscribed:
            return PodcastShowCapabilities(
                managesSubscription: true, showsSettingsSheet: true,
                remembersPreferences: true, downloads: true,
                fetchesMoreEpisodes: true, marksAllEpisodes: true)
        case .browsed:
            return PodcastShowCapabilities(
                managesSubscription: false, showsSettingsSheet: false,
                remembersPreferences: false, downloads: false,
                fetchesMoreEpisodes: false, marksAllEpisodes: false)
        }
    }
}

/// Sort and filter of one show page.
///
/// Both states offer them, only one keeps them. That is the whole difference,
/// and it lives HERE instead of in the view, so a look at a show cannot leave
/// a key behind under an id that no subscription owns.
nonisolated struct PodcastShowPreferences: Equatable, Sendable {
    var newestFirst: Bool
    var unplayedOnly: Bool

    static let `default` = PodcastShowPreferences(newestFirst: true, unplayedOnly: false)

    static func sortKey(showId: String) -> String { "podcastSort.\(showId)" }
    static func filterKey(showId: String) -> String { "podcastFilter.\(showId)" }

    /// What the page starts with. A browsed show starts from the default,
    /// because nothing was ever written for it.
    ///
    /// The fallback reads `default` instead of naming `true` here. A default
    /// value written a second time is how thirty-five copies of one setting
    /// grew, and a fence holds against exactly that.
    static func load(showId: String, mode: PodcastShowMode,
                     defaults: UserDefaults = .standard) -> PodcastShowPreferences {
        guard PodcastShowCapabilities.of(mode).remembersPreferences else { return .default }
        return PodcastShowPreferences(
            newestFirst: defaults.object(forKey: sortKey(showId: showId)) as? Bool
                ?? Self.default.newestFirst,
            unplayedOnly: defaults.object(forKey: filterKey(showId: showId)) as? Bool
                ?? Self.default.unplayedOnly)
    }

    /// The ONE write. In the browsed state it does nothing, so the store is
    /// byte-identical after looking at a show.
    func save(showId: String, mode: PodcastShowMode,
              defaults: UserDefaults = .standard) {
        guard PodcastShowCapabilities.of(mode).remembersPreferences else { return }
        defaults.set(newestFirst, forKey: Self.sortKey(showId: showId))
        defaults.set(unplayedOnly, forKey: Self.filterKey(showId: showId))
    }
}
