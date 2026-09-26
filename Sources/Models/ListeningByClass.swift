// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "What do I really listen to a lot". Per class, derived at ONE place.
///
/// The recommendation seed and the statistics ask the same question, so they
/// ask the same function. Two parallel derivations of one number would be the
/// second version this project keeps abolishing, and here it would be worse
/// than usual: the two would disagree on screen.
nonisolated enum ListeningByClass {

    /// Seconds per podcast SHOW, summed from the stored episode positions.
    ///
    /// **This is an ESTIMATE, and every surface that shows it has to say so.**
    /// A position says how far into an episode someone got, not how often they
    /// listened: hearing an episode three times counts once, and an episode
    /// deleted from the feed is missing entirely. It is nevertheless the honest
    /// choice here, because it works RETROACTIVELY. The alternative would be a
    /// new per-episode measurement that costs 85 % of the shared iCloud budget
    /// and would still know nothing about the past.
    /// `excluding` names episodes whose position was imported from another
    /// app and never listened to here: they are a state, not listening
    /// time, and would otherwise turn an import into hundreds of hours.
    static func shows(in defaults: [String: Any],
                      showId: (String) -> String?,
                      excluding imported: Set<String> = []) -> [String: Double] {
        shows(positions: ListeningStore.positions(inDictionary: defaults), showId: showId, excluding: imported)
    }

    /// The same over the position entries by item id, as the store holds them.
    static func shows(positions: [String: [Double]],
                      showId: (String) -> String?,
                      excluding imported: Set<String> = []) -> [String: Double] {
        var out: [String: Double] = [:]
        for (episodeId, stored) in positions {
            guard ItemNamespace.isPodcastEpisode(episodeId), stored.count >= 2 else { continue }
            guard !imported.contains(episodeId), let show = showId(episodeId) else { continue }
            out[show, default: 0] += max(stored[0], 0)
        }
        return out
    }

    /// Top entries of a per-key second count, longest first. Ties resolve by
    /// key so two devices rank the same list identically. `atLeast` keeps
    /// out what was barely heard, before the limit, so it takes no place.
    static func top(_ seconds: [String: Double], limit: Int,
                    atLeast: Double = 0) -> [(id: String, seconds: Double)] {
        seconds
            .filter { $0.value > 0 && $0.value >= atLeast }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { (id: $0.key, seconds: $0.value) }
    }
}
