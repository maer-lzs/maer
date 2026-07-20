// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// F6: SearchableProvider — the RSS conformance lives here; the ABS and
// Subsonic conformances sit in their providers' own files (they need private
// plumbing there). Every provider returns only what it has; offline each one
// searches its cached/downloaded stock through the SAME protocol
// (offline-first), with `isPlayableNow` driving the overlay-glyph rule.

extension RSSProvider: SearchableProvider {
    /// Searches ALL subscribed shows (rss: AND abspod: — `allShows()` is the
    /// shared, bridge-aware set), so the ABS-podcast provider deliberately does
    /// NOT conform too: one searcher, no double hits. Purely local data — the
    /// same on- and offline; episodes that cannot start right now (offline, not
    /// downloaded) carry the glyph flag.
    @MainActor
    func search(query: String) async throws -> [SearchResult] {
        let online = NetworkMonitor.shared.isConnected
        let shows = PodcastAutoContinue.allShows().map { show in
            (feedURL: show.feedURL, title: show.title,
             coverURL: show.artworkURL.flatMap { URL(string: $0) },
             episodes: show.episodes.map { (id: $0.guid, title: $0.title) })
        }
        return PodcastLocalSearch.results(shows: shows, query: query).map { result in
            guard result.kind == .episode else { return result }
            var episode = result
            episode.isPlayableNow = online || DownloadManager.shared.isDownloaded(itemId: result.id)
            return episode
        }
    }
}
