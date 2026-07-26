// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// The show-INDEPENDENT listen log (the owner 26.07., data layer only — no UI):
/// one persistent entry per episode guid that ever transitioned to `.played`,
/// carrying enough metadata (episode/show title, feed, duration) to stay
/// enumerable after an unsubscribe or feed rotation — the two gaps of the
/// UserDefaults-only state. Deliberately NOT iCloud-synced: `localPosition`
/// already syncs, the log grows on each device from its LOCAL transitions.
/// Own file (grows to thousands of entries — not UserDefaults).
@MainActor
final class PodcastListenLog {
    static let shared = PodcastListenLog()

    nonisolated struct Entry: Codable, Equatable {
        let guid: String
        var episodeTitle: String
        var showTitle: String
        var feedURL: String
        var duration: Double
        /// Epoch ms of the play-through (the position's own timestamp).
        var playedAt: Double
        /// Epoch ms of an explicit "mark unplayed" — a tombstone: only a
        /// NEWER play-through flips it back (an old reconciled position
        /// must not resurrect "played").
        var unplayedAt: Double?

        var isPlayed: Bool { unplayedAt.map { playedAt > $0 } ?? true }
    }

    /// guid → entry (dedup; the latest transition wins).
    private(set) var entries: [String: Entry] = [:]
    private var loaded = false

    private init() {}

    // MARK: - Recording (the ONE hook; threshold logic stays in
    // PodcastProgressStore.state — reused, never copied)

    /// Record a LOCAL played-transition candidate: evaluates the CURRENT
    /// stored state via the existing threshold logic and upserts on `.played`.
    /// Cheap + idempotent — callers may invoke it on every position write.
    func noteIfPlayed(guid: String, duration: Double, episodeTitle: String,
                      showTitle: String, feedURL: String) {
        guard case .played = PodcastProgressStore.shared.state(guid: guid, duration: duration) else { return }
        let ts = (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(guid)) as? [Double])?
            .last ?? Date().timeIntervalSince1970 * 1000
        upsertPlayed(guid: guid, episodeTitle: episodeTitle, showTitle: showTitle,
                     feedURL: feedURL, duration: duration, playedAt: ts)
    }

    /// Explicit "mark unplayed": tombstone the entry (kept, flagged) — the
    /// history survives, and only a newer real play-through flips it back.
    func markUnplayed(guid: String) {
        loadIfNeeded()
        guard var entry = entries[guid] else { return }
        entry.unplayedAt = Date().timeIntervalSince1970 * 1000
        entries[guid] = entry
        persist()
    }

    private func upsertPlayed(guid: String, episodeTitle: String, showTitle: String,
                              feedURL: String, duration: Double, playedAt: Double) {
        loadIfNeeded()
        if var existing = entries[guid] {
            // Latest transition wins; a tombstone yields only to a NEWER play.
            guard playedAt > existing.playedAt || existing.unplayedAt != nil else { return }
            if let unplayedAt = existing.unplayedAt, playedAt <= unplayedAt { return }
            existing.playedAt = max(existing.playedAt, playedAt)
            existing.episodeTitle = episodeTitle.isEmpty ? existing.episodeTitle : episodeTitle
            existing.showTitle = showTitle.isEmpty ? existing.showTitle : showTitle
            existing.feedURL = feedURL.isEmpty ? existing.feedURL : feedURL
            existing.duration = duration > 0 ? duration : existing.duration
            entries[guid] = existing
        } else {
            entries[guid] = Entry(guid: guid, episodeTitle: episodeTitle, showTitle: showTitle,
                                  feedURL: feedURL, duration: duration, playedAt: playedAt,
                                  unplayedAt: nil)
        }
        persist()
    }

    // MARK: - Backfill (once): today's shows seed the log so the history of
    // the current subscriptions is not lost to a later unsubscribe.

    func backfillIfNeeded(shows: [PodcastShow]) {
        guard !UserDefaults.standard.bool(forKey: AppStorageKeys.listenLogBackfilled) else { return }
        loadIfNeeded()
        for show in shows {
            for episode in show.episodes {
                noteIfPlayed(guid: episode.guid, duration: episode.duration ?? 0,
                             episodeTitle: episode.title, showTitle: show.title,
                             feedURL: show.feedURL)
            }
        }
        UserDefaults.standard.set(true, forKey: AppStorageKeys.listenLogBackfilled)
        Logger.rss.notice("listen log backfilled: \(self.entries.count) entries")
    }

    // MARK: - Persistence (own JSON file in Application Support)

    private nonisolated static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("podcast-listen-log.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Best-effort atomic write; a lost write self-heals on the next
        // transition (the log is derived from localPosition state).
        try? data.write(to: url, options: .atomic)
    }

    #if DEBUG
    /// Test seam: reset in-memory state (file untouched).
    func _resetForTest() { entries = [:]; loaded = true }
    #endif
}
