// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The pull of the listening history asks the server from a marker, and the
/// marker moves on after each round. A play action whose episode this
/// device does not know yet (a first round runs before the feeds are
/// fetched) would be gone behind it. Such an action of a feed this device
/// follows is parked and matched again at the next rounds; one of a feed
/// it does not follow is not this device's and goes.
enum GPodderParking {
    /// The most actions kept parked, the newest by their stamp.
    static let most = 1_000

    /// The play actions split: those whose episode is known now, those to
    /// park (episode unknown, feed followed), the rest dropped.
    static func split(_ actions: [GPodderEpisodeAction],
                      isKnownEpisode: (String) -> Bool,
                      isFollowedFeed: (String) -> Bool) -> (matched: [GPodderEpisodeAction], parked: [GPodderEpisodeAction]) {
        var matched: [GPodderEpisodeAction] = []
        var parked: [GPodderEpisodeAction] = []
        for action in actions where action.action?.lowercased() == "play" {
            guard let episode = action.episode else { continue }
            if isKnownEpisode(episode) {
                matched.append(action)
            } else if let feed = action.podcast, isFollowedFeed(feed) {
                parked.append(action)
            }
        }
        return (matched, Array(parked.sorted { ($0.timestamp ?? "") > ($1.timestamp ?? "") }.prefix(most)))
    }

    /// The parked actions; none when nothing is parked or the value does
    /// not read (a line says so).
    static func load() -> [GPodderEpisodeAction] {
        guard let data = AppStorageKeys.data(AppStorageKeys.gpodderParkedActions) else { return [] }
        do {
            return try JSONDecoder().decode([GPodderEpisodeAction].self, from: data)
        } catch {
            Logger.gpodder.error("GPODDER parked actions do not read: \(FailureReason.of(error), privacy: .public)")
            return []
        }
    }

    static func save(_ actions: [GPodderEpisodeAction]) {
        guard !actions.isEmpty, let data = try? JSONEncoder().encode(actions) else {
            AppStorageKeys.remove(AppStorageKeys.gpodderParkedActions)
            return
        }
        AppStorageKeys.set(data, for: AppStorageKeys.gpodderParkedActions)
    }
}
