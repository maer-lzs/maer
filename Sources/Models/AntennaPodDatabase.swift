// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// AntennaPod's database export, turned into the common library. Pure:
/// the rows arrive as values, the SQLite read lives with the other
/// readers. Measured on the schema of AntennaPod 3.12.0 (database
/// version 3110000): three tables carry everything the import needs.
///
/// `Feeds`: `download_url` is the feed, `state` 0 means subscribed.
/// `FeedItems`: `item_identifier` is the RSS guid, `read` is -1 new,
/// 0 unplayed or started, 1 played. `FeedMedia`: `position`,
/// `duration` and `last_played_time` in milliseconds, `download_url`
/// the enclosure. An episode marked played by hand has no
/// `last_played_time`; its state then carries no moment and may only
/// fill.
nonisolated enum AntennaPodDatabase {
    struct Feed: Sendable, Equatable {
        var id: Int64
        var title: String?
        var downloadURL: String?
        /// nil on a schema without the column, which counts as subscribed.
        var state: Int64?
    }

    struct Item: Sendable, Equatable {
        var id: Int64
        var feedID: Int64
        var title: String?
        var identifier: String?
        var link: String?
        var read: Int64
    }

    struct Media: Sendable, Equatable {
        var itemID: Int64
        var durationMs: Int64
        var positionMs: Int64
        var lastPlayedMs: Int64
        var completionMs: Int64
        var downloadURL: String?
    }

    static let played: Int64 = 1

    /// Subscribed feeds and one state per episode that was started or
    /// played. Episodes of unsubscribed feeds stay out with their feed.
    static func library(feeds: [Feed], items: [Item], media: [Media]) -> ForeignLibrary {
        var feedURLByID: [Int64: String] = [:]
        var feedURLs: [String] = []
        for feed in feeds where feed.state ?? 0 == 0 {
            guard let url = feed.downloadURL, !url.isEmpty else { continue }
            feedURLByID[feed.id] = url
            feedURLs.append(url)
        }
        var mediaByItem: [Int64: Media] = [:]
        for m in media { mediaByItem[m.itemID] = m }

        var states: [ForeignListeningState] = []
        for item in items {
            guard let feedURL = feedURLByID[item.feedID] else { continue }
            let m = mediaByItem[item.id]
            let finished = item.read == played
            let position = Double(m?.positionMs ?? 0) / 1000
            guard finished || position > 1 else { continue }
            let duration = Double(m?.durationMs ?? 0) / 1000
            // The moment: when it last played, else when it completed.
            // Both zero means marked by hand, and then there is none.
            let stamp = [m?.lastPlayedMs ?? 0, m?.completionMs ?? 0].max() ?? 0
            states.append(ForeignListeningState(
                feedURL: feedURL,
                episodeGUID: item.identifier.flatMap { $0.isEmpty ? nil : $0 },
                enclosureURL: m?.downloadURL.flatMap { $0.isEmpty ? nil : $0 },
                episodeLink: item.link.flatMap { $0.isEmpty ? nil : $0 },
                episodeTitle: item.title.flatMap { $0.isEmpty ? nil : $0 },
                position: position,
                duration: duration > 0 ? duration : nil,
                finished: finished,
                stampedAt: stamp > 0 ? Double(stamp) : nil))
        }
        return ForeignLibrary(feedURLs: feedURLs, states: states)
    }
}
