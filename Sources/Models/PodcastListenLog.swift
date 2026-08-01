// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// The show-INDEPENDENT listen log (the owner 26.07., data layer only — no UI):
/// one persistent entry per episode guid that ever transitioned to `.played`,
/// carrying enough metadata (episode/show title, feed, duration) to stay
/// enumerable after an unsubscribe or feed rotation — the two gaps of the
/// UserDefaults-only state. PERSON level (the owner 8b354d7): the log stores
/// person facts — local transitions AND reconciled iCloud/gpodder positions
/// feed it (noteReconciled); the log FILE itself is not synced (localPosition
/// already is; each device derives the same facts — endgame candidate: sync
/// the log itself, see report). Own file (thousands of entries possible).
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
    /// Bulk passes (backfill/rescan) coalesce the per-hit file writes.
    private var suspendPersist = false

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
    /// `at` carries a remote transition's own timestamp (reconcile ordering).
    func markUnplayed(guid: String, at ts: Double? = nil) {
        loadIfNeeded()
        guard var entry = entries[guid] else { return }
        entry.unplayedAt = ts ?? Date().timeIntervalSince1970 * 1000
        entries[guid] = entry
        persist()
    }

    /// Personen-Ebene (owner decision 8b354d7): reconciled transitions —
    /// iCloud/gpodder-applied positions — feed the log too; the log stores
    /// person FACTS, not device events. Metadata resolves via the subscribed
    /// shows; a guid whose show was never subscribed HERE gets a MINIMAL
    /// entry (empty titles, feed unknown) — deliberately kept rather than
    /// dropped, because later upserts enrich empty fields in place and the
    /// fact "heard" must not depend on this device's subscription history.
    func noteReconciled(guids: some Sequence<String>) {
        for guid in guids {
            let resolved = PodcastSubscriptions.shared.episode(guid: guid)
            let duration = resolved?.episode.duration ?? 0
            switch PodcastProgressStore.shared.state(guid: guid, duration: duration) {
            case .played:
                noteIfPlayed(guid: guid, duration: duration,
                             episodeTitle: resolved?.episode.title ?? "",
                             showTitle: resolved?.show.title ?? "",
                             feedURL: resolved?.show.feedURL ?? "")
            case .unplayed:
                // A remote unplayed-tombstone ([0, ts]) must tombstone HERE
                // too — otherwise devices diverge in the other direction.
                if let arr = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(guid)) as? [Double],
                   arr.count == 2, arr[0] <= 0 {
                    markUnplayed(guid: guid, at: arr[1])
                }
            case .inProgress:
                break
            }
        }
    }

    /// Targeted re-scan of specific shows (Apple import: metadata is present
    /// there) — the backfill body without the one-time flag.
    func rescan(shows: [PodcastShow]) {
        loadIfNeeded()
        suspendPersist = true
        defer { suspendPersist = false; persist() }
        for show in shows {
            for episode in show.episodes {
                noteIfPlayed(guid: episode.guid, duration: episode.duration,
                             episodeTitle: episode.title, showTitle: show.title,
                             feedURL: show.feedURL)
            }
        }
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
        suspendPersist = true
        defer { suspendPersist = false; persist() }
        for show in shows {
            for episode in show.episodes {
                noteIfPlayed(guid: episode.guid, duration: episode.duration,
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
        guard !suspendPersist else { return }
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

    /// V6: the chronological history (pure, tested) — tombstoned entries
    /// (marked unplayed, no newer play) are hidden, newest play first.
    nonisolated static func historyList(_ entries: [String: Entry]) -> [Entry] {
        entries.values.filter(\.isPlayed).sorted { $0.playedAt > $1.playedAt }
    }

    /// The visible history of the loaded log.
    func history() -> [Entry] {
        loadIfNeeded()
        return Self.historyList(entries)
    }
    #endif
}
