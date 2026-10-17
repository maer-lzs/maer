// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What changed between two states of the subscription list, as rows.
///
/// The stock used to be one document: every save encoded and wrote every
/// show with every episode (80 MB at 300 shows, measured). The row backend
/// takes a diff instead: the show heads (a show without its episodes) and
/// the episodes that are new, changed, moved or gone. Pure, so the rule is
/// witnessed without a database.
///
/// Positions are part of the row: the list order of the shows and the order
/// of the episodes within a show are facts of the stock, and a row backend
/// has no order of its own. A new episode at the front therefore moves every
/// episode of THAT show, and only that show; that is one show's rows, not
/// the whole stock.
nonisolated struct PodcastRowDiff: Equatable, Sendable {
    struct ShowRow: Equatable, Sendable {
        var position: Int
        /// The head: the show with `episodes` emptied.
        var show: PodcastShow
    }

    struct EpisodeRow: Equatable, Sendable {
        var showId: String
        var position: Int
        var episode: PodcastEpisode
    }

    var showsUpserted: [ShowRow] = []
    var showsRemoved: [String] = []
    var episodesUpserted: [EpisodeRow] = []
    var episodesRemoved: [String] = []

    var isEmpty: Bool {
        showsUpserted.isEmpty && showsRemoved.isEmpty && episodesUpserted.isEmpty && episodesRemoved.isEmpty
    }

    /// The show without its episodes, the way the `show` table carries it.
    static func head(of show: PodcastShow) -> PodcastShow {
        var head = show
        head.episodes = []
        return head
    }

    static func compute(previous: [PodcastShow], current: [PodcastShow]) -> PodcastRowDiff {
        var diff = PodcastRowDiff()
        var previousShows: [String: (position: Int, show: PodcastShow)] = [:]
        for (position, show) in previous.enumerated() { previousShows[show.id] = (position, show) }
        var currentIds = Set<String>()
        currentIds.reserveCapacity(current.count)

        for (position, show) in current.enumerated() {
            currentIds.insert(show.id)
            let head = self.head(of: show)
            let before = previousShows[show.id]
            if before == nil || before!.position != position || self.head(of: before!.show) != head {
                diff.showsUpserted.append(ShowRow(position: position, show: head))
            }
            var previousEpisodes: [String: (position: Int, episode: PodcastEpisode)] = [:]
            if let before {
                for (index, episode) in before.show.episodes.enumerated() {
                    previousEpisodes[episode.guid] = (index, episode)
                }
            }
            var seen = Set<String>()
            for (index, episode) in show.episodes.enumerated() {
                seen.insert(episode.guid)
                let old = previousEpisodes[episode.guid]
                if old == nil || old!.position != index || old!.episode != episode {
                    diff.episodesUpserted.append(EpisodeRow(showId: show.id, position: index, episode: episode))
                }
            }
            for guid in previousEpisodes.keys where !seen.contains(guid) {
                diff.episodesRemoved.append(guid)
            }
        }
        for show in previous where !currentIds.contains(show.id) {
            diff.showsRemoved.append(show.id)
        }
        diff.episodesRemoved.sort()
        diff.showsRemoved.sort()
        return diff
    }
}
