// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// "Co-listened": a show nobody subscribed to, whose episodes were played
/// through anyway. Some people listen without subscribing, and their
/// "Latest Episodes" should not pretend those shows do not exist.
///
/// Derived, never stored: a pure function over the kept browsed episodes,
/// the listen log, the user's hidden list and now. Nothing here reaches the
/// subscription stock, gpodder, OPML, notifications or auto-download; a
/// co-listened show is a view, not an subscription through the back door.
nonisolated enum CoListened {
    /// A show stays co-listened for sixty days after its last observed
    /// play-through, then leaves by itself. The window is the only limit:
    /// whoever listens without subscribing sees every show heard through
    /// in it (decided 06.09.2026, no cap).
    static let windowDays: Double = 60

    /// What the rule saw and why rows fell out, for the one log line a
    /// surface writes when it stays empty.
    struct Tally: Equatable, Sendable {
        var listened = 0
        var shows = 0
        var unobservedDropped = 0
        var windowDropped = 0
        var subscribedDropped = 0
        var hiddenDropped = 0
    }

    /// One episode the caller already joined: the kept row and its log entry.
    struct Listened: Sendable, Equatable {
        /// The normalised feed address (the caller normalises; the rule
        /// compares keys, it does not know addresses).
        let feedKey: String
        let feedURL: String
        let showTitle: String
        /// Epoch ms of the play-through.
        let playedAt: Double
        /// A tombstoned entry ("mark unplayed") is not a play-through.
        let isPlayed: Bool
        /// Bookkeeping passes date the bookkeeping, not a listen; they do
        /// not count.
        let hasObservedTime: Bool
    }

    struct Show: Sendable, Equatable {
        let feedKey: String
        let feedURL: String
        let showTitle: String
        /// Epoch ms of the newest observed play-through.
        let lastPlayedAt: Double
    }

    /// The co-listened shows: one observed play-through inside the window,
    /// not subscribed, not hidden, newest first.
    static func shows(listened: [Listened], subscribedFeedKeys: Set<String>,
                      hiddenFeedKeys: Set<String>, now: Double) -> [Show] {
        evaluate(listened: listened, subscribedFeedKeys: subscribedFeedKeys,
                 hiddenFeedKeys: hiddenFeedKeys, now: now).shows
    }

    /// The same, with the tally of what fell out and why.
    static func evaluate(listened: [Listened], subscribedFeedKeys: Set<String>,
                         hiddenFeedKeys: Set<String>, now: Double) -> (shows: [Show], tally: Tally) {
        let since = now - windowDays * 24 * 3600 * 1000
        var newest: [String: Show] = [:]
        var tally = Tally(listened: listened.count)
        for row in listened {
            guard row.isPlayed, row.hasObservedTime, !row.feedKey.isEmpty else { tally.unobservedDropped += 1; continue }
            guard row.playedAt >= since else { tally.windowDropped += 1; continue }
            guard !subscribedFeedKeys.contains(row.feedKey) else { tally.subscribedDropped += 1; continue }
            guard !hiddenFeedKeys.contains(row.feedKey) else { tally.hiddenDropped += 1; continue }
            if let known = newest[row.feedKey], known.lastPlayedAt >= row.playedAt { continue }
            newest[row.feedKey] = Show(feedKey: row.feedKey, feedURL: row.feedURL,
                                       showTitle: row.showTitle, lastPlayedAt: row.playedAt)
        }
        let shows = newest.values.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
        tally.shows = shows.count
        return (shows, tally)
    }
}

/// The user's "don't show this show again" list: feed keys, on this device.
/// A user choice, kept like the other device-class choices.
nonisolated enum CoListenedHiddenStore {
    private static let key = AppStorageKeys.coListenedHidden

    static func feedKeys() -> Set<String> {
        Set(AppStorageKeys.stringArray(key) ?? [])
    }

    static func hide(feedKey: String) {
        var keys = feedKeys()
        keys.insert(feedKey)
        AppStorageKeys.set(Array(keys).sorted(), for: key)
    }

    #if DEBUG
    static func _resetForTest() { AppStorageKeys.remove(key) }
    #endif
}

extension Notification.Name {
    /// A co-listened show was hidden or subscribed; the rows recompute.
    static let coListenedChanged = Notification.Name("coListenedChanged")
}
