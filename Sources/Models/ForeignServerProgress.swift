// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// An episode's handles as its feed carries them, for an episode the
/// podcast server holds. The server's own episode fields are not the feed's.
nonisolated struct ServerEpisodeHandle: Sendable, Equatable {
    var guid: String?
    var enclosure: String?
}

/// A foreign import onto the podcast server: the server's progress is
/// judged by the same conflict rule as a local entry, and what the rule
/// adopts goes to the server the way the history push sends it.
nonisolated enum ForeignServerProgress {
    /// The ladder's targets: one per server episode whose feed handles are
    /// known. Only guid and enclosure; the titles are the server's.
    static func targets(shows: [PodcastShow], handles: [String: ServerEpisodeHandle],
                        feedKeyOf: (String) -> String) -> [ForeignMatchTarget] {
        var targets: [ForeignMatchTarget] = []
        for show in shows where !show.feedURL.isEmpty {
            let feedKey = feedKeyOf(show.feedURL)
            for episode in show.episodes {
                guard let handle = handles[episode.guid] else { continue }
                targets.append(ForeignMatchTarget(id: episode.guid, rawGUID: handle.guid,
                                                  enclosureURL: handle.enclosure ?? "", link: nil,
                                                  title: episode.title, feedKey: feedKey))
            }
        }
        return targets
    }

    /// The server's progress as a listening-store entry `[position, momentMs]`.
    /// A finished episode without a duration takes the played sentinel,
    /// as everywhere else.
    static func entry(_ progress: BookProgress, duration: Double) -> [Double] {
        let position: Double
        if progress.isFinished {
            position = duration > 0 ? duration : ProgressMark.playedSentinel
        } else {
            position = progress.currentTime ?? progress.fraction * max(duration, 0)
        }
        return [position, progress.lastUpdate]
    }

    /// What goes to the server for an adopted entry: its position, and
    /// finished at the true end (the sentinel included), as the history
    /// push sends it.
    static func write(_ entry: [Double], duration: Double) -> (time: Double, finished: Bool) {
        (entry.first ?? 0, ProgressMark.reachedEnd(stored: entry, currentDuration: duration))
    }
}
