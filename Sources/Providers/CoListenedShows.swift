// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The co-listened shows of this device, derived now (`CoListened`), and
/// their feeds fetched inside the existing refresh so "Latest Episodes"
/// has an episode list to show. Nothing here is persisted like a
/// subscription: the fetched feed lives in the browsed session half.
enum CoListenedShows {
    /// The shows as of now: kept browsed episodes joined with the listen
    /// log, minus subscriptions and the hidden list.
    static func current(now: Double = Date().timeIntervalSince1970 * 1000) -> [CoListened.Show] {
        let log = PodcastListenLog.shared
        _ = log.history()   // loads the log
        let entries = log.entries
        let kept = BrowsedEpisodes.shared.allListened()
        let listened = kept.compactMap { kept -> CoListened.Listened? in
            guard let entry = entries[kept.guid] else { return nil }
            return CoListened.Listened(
                feedKey: PodcastSubscriptions.normalizeFeedURL(kept.feedURL),
                feedURL: kept.feedURL, showTitle: kept.showTitle,
                playedAt: entry.playedAt, isPlayed: entry.isPlayed,
                hasObservedTime: entry.hasObservedTime)
        }
        let (shows, tally) = CoListened.evaluate(listened: listened,
                                                 subscribedFeedKeys: subscribedFeedKeys(),
                                                 hiddenFeedKeys: CoListenedHiddenStore.feedKeys(),
                                                 now: now)
        // The one line that says why the row is what it is; written when
        // the picture changes, not on every render (an empty row that
        // wrote nothing and could not be read on the device).
        let line = "COLISTENED shows=\(tally.shows) kept=\(kept.count) listened=\(tally.listened) unobservedDropped=\(tally.unobservedDropped) windowDropped=\(tally.windowDropped) subscribedDropped=\(tally.subscribedDropped) hiddenDropped=\(tally.hiddenDropped) sessionShows=\(BrowsedEpisodes.shared.sessionShows().count)"
        if line != lastLine {
            lastLine = line
            Logger.rss.notice("\(line, privacy: .public)")
        }
        return shows
    }

    private static var lastLine: String?

    /// The row "Co-listened" of the podcasts tab: the newest episode of
    /// every co-listened show, the most recently heard show first (the
    /// rule's order), from the session half the refresh fetched.
    static func rowItems() -> [LibraryItem] {
        let session = shows()
        return current().compactMap { show -> LibraryItem? in
            guard let fetched = session.first(where: { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == show.feedKey }),
                  let id = PodcastSections.newestPerShow(shows: [fetched], limit: 1).first else { return nil }
            return AppSession.shared.libraryItem(forId: id)
        }
    }

    /// Every subscription of every podcast source, as feed keys. The one
    /// negative filter: a subscribed show is never co-listened.
    static func subscribedFeedKeys() -> Set<String> {
        PodcastShowMerge.normalizedFeeds(PodcastShowSources.ownedShows())
    }

    /// The session shows of the co-listened feeds, for `newestPerShow`. Empty
    /// until the refresh fetched them (a restart empties the session half).
    static func shows() -> [PodcastShow] {
        let keys = Set(current().map(\.feedKey))
        guard !keys.isEmpty else { return [] }
        return BrowsedEpisodes.shared.sessionShows()
            .filter { keys.contains(PodcastSubscriptions.normalizeFeedURL($0.feedURL)) }
    }

    /// The feed key of an episode that belongs to a co-listened show, else nil.
    static func feedKey(forEpisodeId id: String, among shows: [CoListened.Show]) -> String? {
        guard let feed = PodcastSubscriptions.shared.feedURL(forEpisodeId: id) else { return nil }
        let key = PodcastSubscriptions.normalizeFeedURL(feed)
        return shows.contains { $0.feedKey == key } ? key : nil
    }

    /// Fetches the co-listened feeds into the session half, one after the
    /// other like the subscriptions; only shows inside the window, so the
    /// cost grows with the listening, not with the past. A feed that
    /// fails falls out of the row for this run, with a log line.
    static func refresh() async {
        let started = Date()
        let shows = current()
        var fetched = 0
        for show in shows {
            guard let url = PodcastFeedAddress.requestURL(show.feedURL) else { continue }
            if let fresh = await PodcastSubscriptions.fetchAndParse(feedURL: url) {
                BrowsedEpisodes.shared.remember(show: fresh)
                fetched += 1
            } else {
                Logger.rss.notice("COLISTENED feed failed host=\(url.host ?? "-", privacy: .public)")
            }
        }
        Logger.rss.notice("COLISTENED refresh shows=\(shows.count) fetched=\(fetched) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    /// The user's "don't show": hidden on this device, rows recompute.
    static func hide(feedKey: String) {
        CoListenedHiddenStore.hide(feedKey: feedKey)
        NotificationCenter.default.post(name: .coListenedChanged, object: nil)
    }
}
