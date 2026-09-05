// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The JSON answers of Pocket Casts' private interface, turned into the
/// common library. Pure: bytes in, values out; the requests live with
/// the other clients. Measured on a real account (form only, no values)
/// and on the public doors:
///
/// `POST api.pocketcasts.com/user/login` ⇒ `token`.
/// `POST user/podcast/list` ⇒ `podcasts[]` with `uuid`, `title`, `url`
/// (the website, not the feed).
/// `POST user/podcast/episodes {uuid}` ⇒ `episodes[]` with `uuid`,
/// `playingStatus` (1 unplayed, 2 in progress, 3 completed),
/// `playedUpTo` (seconds), `duration`. No title, no enclosure, no moment.
/// `POST refresh.pocketcasts.com/import/export_feed_urls {uuids}` ⇒
/// `result` map uuid ⇒ RSS feed address.
/// `GET cache.pocketcasts.com/podcast/full/{uuid}` ⇒ `podcast.episodes[]`
/// with `uuid`, `title`, `url` (the enclosure), `published`, `duration`.
///
/// Fields the interface adds later are ignored; a field this needs in
/// the wrong shape makes the whole answer nil, never a partial read.
nonisolated enum PocketCastsAPI {
    struct Podcast: Sendable, Equatable {
        var uuid: String
        var title: String?
    }

    struct EpisodeState: Sendable, Equatable {
        var uuid: String
        var playingStatus: Int
        var playedUpTo: Double
        var duration: Double?
        /// Pocket Casts' archive: the episode was put away. Decided: an
        /// archived episode counts as finished, heard or not.
        var isDeleted: Bool = false

        var finished: Bool { isDeleted || playingStatus == statusCompleted }
        var inProgress: Bool { !isDeleted && playingStatus == statusInProgress && playedUpTo > 1 }
    }

    struct CachedEpisode: Sendable, Equatable {
        var uuid: String
        var title: String?
        var enclosureURL: String?
        var duration: Double?
    }

    static let statusInProgress = 2
    static let statusCompleted = 3

    // MARK: - Answers

    /// The bearer token of a login, nil when the answer carries none.
    static func token(from data: Data) -> String? {
        guard let object = object(data), let token = object["token"] as? String, !token.isEmpty else { return nil }
        return token
    }

    /// The reason a login was refused, as the interface words it.
    static func errorMessage(from data: Data) -> String? {
        guard let object = object(data) else { return nil }
        return (object["errorMessage"] as? String) ?? (object["errorMessageId"] as? String)
    }

    static func podcasts(from data: Data) -> [Podcast]? {
        guard let object = object(data), let rows = object["podcasts"] as? [[String: Any]] else { return nil }
        var podcasts: [Podcast] = []
        for row in rows {
            guard let uuid = row["uuid"] as? String, !uuid.isEmpty else { return nil }
            podcasts.append(Podcast(uuid: uuid, title: row["title"] as? String))
        }
        return podcasts
    }

    static func episodeStates(from data: Data) -> [EpisodeState]? {
        guard let object = object(data), let rows = object["episodes"] as? [[String: Any]] else { return nil }
        var states: [EpisodeState] = []
        for row in rows {
            guard let uuid = row["uuid"] as? String, !uuid.isEmpty,
                  let status = number(row["playingStatus"]) else { return nil }
            states.append(EpisodeState(uuid: uuid, playingStatus: Int(status),
                                       playedUpTo: number(row["playedUpTo"]) ?? 0,
                                       duration: number(row["duration"]).flatMap { $0 > 0 ? $0 : nil },
                                       isDeleted: (row["isDeleted"] as? Bool) ?? false))
        }
        return states
    }

    static func cachedEpisodes(from data: Data) -> [CachedEpisode]? {
        cachedPodcast(from: data)?.episodes
    }

    /// The cache document with the show's own name, so the client can hold
    /// it against the account list: a cache that answers for a different
    /// show explains states whose titles belong to nothing the person has.
    static func cachedPodcast(from data: Data) -> (title: String?, episodes: [CachedEpisode])? {
        guard let object = object(data), let podcast = object["podcast"] as? [String: Any],
              let rows = podcast["episodes"] as? [[String: Any]] else { return nil }
        let title = (podcast["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var episodes: [CachedEpisode] = []
        for row in rows {
            guard let uuid = row["uuid"] as? String, !uuid.isEmpty else { return nil }
            episodes.append(CachedEpisode(uuid: uuid, title: row["title"] as? String,
                                          enclosureURL: (row["url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                          duration: number(row["duration"]).flatMap { $0 > 0 ? $0 : nil }))
        }
        return (title, episodes)
    }

    /// uuid ⇒ feed address. A podcast the door does not know is absent.
    static func feedURLs(from data: Data) -> [String: String]? {
        guard let object = object(data), let result = object["result"] as? [String: Any] else { return nil }
        var feeds: [String: String] = [:]
        for (uuid, value) in result {
            if let url = value as? String, !url.isEmpty { feeds[uuid] = url }
        }
        return feeds
    }

    // MARK: - The library

    /// Subscriptions with a feed and one state per started or completed
    /// episode, enriched with title and enclosure from the cache where
    /// the cache knows the episode. Pocket Casts records no moment, so
    /// every state may only fill. Podcasts without a feed address are
    /// counted as unimportable, the same class as paid feeds elsewhere.
    static func library(podcasts: [Podcast], feedURLs: [String: String],
                        states: [String: [EpisodeState]],
                        episodes: [String: [CachedEpisode]]) -> ForeignLibrary {
        var library = ForeignLibrary(feedURLs: [], states: [])
        for podcast in podcasts {
            guard let feed = feedURLs[podcast.uuid] else {
                library.unimportablePaidCount += 1
                continue
            }
            library.feedURLs.append(feed)
            var cached: [String: CachedEpisode] = [:]
            for episode in episodes[podcast.uuid] ?? [] { cached[episode.uuid] = episode }
            for state in states[podcast.uuid] ?? [] {
                guard state.finished || state.inProgress else { continue }
                let episode = cached[state.uuid]
                library.states.append(ForeignListeningState(
                    feedURL: feed,
                    showTitle: podcast.title,
                    episodeGUID: nil,
                    enclosureURL: episode?.enclosureURL,
                    episodeLink: nil,
                    episodeTitle: episode?.title,
                    position: state.playedUpTo,
                    duration: state.duration ?? episode?.duration,
                    finished: state.finished,
                    stampedAt: nil,
                    archived: state.isDeleted))
            }
        }
        return library
    }

    // MARK: - Helpers

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Numbers arrive as numbers, and on some doors as strings.
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
