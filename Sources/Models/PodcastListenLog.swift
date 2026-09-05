// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The show-INDEPENDENT listen log (data layer only. No UI):
/// one persistent entry per episode guid that ever transitioned to `.played`,
/// carrying enough metadata (episode/show title, feed, duration) to stay
/// enumerable after an unsubscribe or feed rotation. The two gaps of the
/// UserDefaults-only state. PERSON level: the log stores
/// person facts. Local transitions AND reconciled iCloud/gpodder positions
/// feed it (noteReconciled); the log FILE itself is not synced (localPosition
/// already is; each device derives the same facts. Endgame candidate: sync
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
        /// Epoch ms of an explicit "mark unplayed". A tombstone: only a
        /// NEWER play-through flips it back (an old reconciled position
        /// must not resurrect "played").
        var unplayedAt: Double?
        /// `playedAt` is BOOKKEEPING, not an observed listen time.
        /// Set by the BULK passes (backfill/rescan), which only write down
        /// what the position store already knew. The entry keeps the fact
        /// "heard", but answers no honest WHEN. Optional for entries written
        /// before the flag existed; those are migrated on load.
        var synthesizedAt: Bool?

        var isPlayed: Bool { unplayedAt.map { playedAt > $0 } ?? true }

        /// Does `playedAt` answer "when"? Only stamped transitions do.
        /// Dormancy ranking asks THIS, never `playedAt > 0`.
        var hasObservedTime: Bool { !(synthesizedAt ?? false) }
    }

    /// guid → entry (dedup; the latest transition wins).
    private(set) var entries: [String: Entry] = [:]
    private var loaded = false
    /// Bulk passes (backfill/rescan) coalesce the per-hit file writes.
    private var suspendPersist = false

    private init() {}

    // MARK: - Recording (the ONE hook; threshold logic stays in
    // PodcastProgressStore.state. Reused, never copied)

    /// Record a LOCAL played-transition candidate: evaluates the CURRENT
    /// stored state via the existing threshold logic and upserts on `.played`.
    /// Cheap + idempotent. Callers may invoke it on every position write.
    /// `synthesized`: the caller is a BULK pass (backfill/rescan) that merely
    /// books what the position store already knew. The resulting timestamp
    /// dates the bookkeeping, not a listen.
    func noteIfPlayed(guid: String, duration: Double, episodeTitle: String,
                      showTitle: String, feedURL: String, synthesized: Bool = false) {
        guard case .played = PodcastProgressStore.shared.state(guid: guid, duration: duration) else { return }
        // Through ProgressMark, never .last: on a three-value entry .last is
        // the DURATION. The history booked playedAt = 3600 and rendered 1970.
        let ts = ProgressMark.timestamp(
            ListeningStore.backup(guid))
            ?? Date().timeIntervalSince1970 * 1000
        upsertPlayed(guid: guid, episodeTitle: episodeTitle, showTitle: showTitle,
                     feedURL: feedURL, duration: duration, playedAt: ts,
                     synthesized: synthesized)
    }

    /// Explicit "mark unplayed": tombstone the entry (kept, flagged). The
    /// history survives, and only a newer real play-through flips it back.
    /// `at` carries a remote transition's own timestamp (reconcile ordering).
    func markUnplayed(guid: String, at ts: Double? = nil) {
        loadIfNeeded()
        guard var entry = entries[guid] else { return }
        entry.unplayedAt = ts ?? Date().timeIntervalSince1970 * 1000
        entries[guid] = entry
        persist()
    }

    /// Person level: reconciled transitions.
    /// iCloud/gpodder-applied positions. Feed the log too; the log stores
    /// person FACTS, not device events. Metadata resolves via the subscribed
    /// shows; a guid whose show was never subscribed HERE gets a MINIMAL
    /// entry (empty titles, feed unknown). Deliberately kept rather than
    /// dropped, because later upserts enrich empty fields in place and the
    /// fact "heard" must not depend on this device's subscription history.
    /// The gpodder-scale entry point: after a fresh sign-in the whole
    /// action history arrives at once (thousands of guids). Same work as
    /// below, chunked with yields so the main actor breathes between
    /// chunks instead of standing for the entire history; that stand was
    /// a measured watchdog kill on the settings surface.
    func noteReconciled(batched guids: [String]) async {
        var index = 0
        while index < guids.count {
            let end = min(index + 200, guids.count)
            noteReconciled(guids: guids[index..<end])
            index = end
            await Task.yield()
        }
    }

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
                // too. Otherwise devices diverge in the other direction.
                if let arr = ListeningStore.backup(guid),
                   arr.count >= 2, arr[0] <= 0 {
                    markUnplayed(guid: guid, at: arr[1])
                }
            case .inProgress:
                break
            }
        }
    }

    /// Targeted re-scan of specific shows (Apple import: metadata is present
    /// there). The backfill body without the one-time flag.
    func rescan(shows: [PodcastShow]) {
        loadIfNeeded()
        suspendPersist = true
        defer { suspendPersist = false; persist() }
        for show in shows {
            for episode in show.episodes {
                noteIfPlayed(guid: episode.guid, duration: episode.duration,
                             episodeTitle: episode.title, showTitle: show.title,
                             feedURL: show.feedURL, synthesized: true)
            }
        }
    }

    private func upsertPlayed(guid: String, episodeTitle: String, showTitle: String,
                              feedURL: String, duration: Double, playedAt: Double,
                              synthesized: Bool = false) {
        loadIfNeeded()
        if var existing = entries[guid] {
            // Latest transition wins; a tombstone yields only to a NEWER play.
            guard playedAt > existing.playedAt || existing.unplayedAt != nil else { return }
            if let unplayedAt = existing.unplayedAt, playedAt <= unplayedAt { return }
            existing.playedAt = max(existing.playedAt, playedAt)
            // A stamped transition upgrades a synthesized one (never back).
            existing.synthesizedAt = (existing.synthesizedAt ?? false) && synthesized
            existing.episodeTitle = episodeTitle.isEmpty ? existing.episodeTitle : episodeTitle
            existing.showTitle = showTitle.isEmpty ? existing.showTitle : showTitle
            existing.feedURL = feedURL.isEmpty ? existing.feedURL : feedURL
            existing.duration = duration > 0 ? duration : existing.duration
            entries[guid] = existing
        } else {
            entries[guid] = Entry(guid: guid, episodeTitle: episodeTitle, showTitle: showTitle,
                                  feedURL: feedURL, duration: duration, playedAt: playedAt,
                                  unplayedAt: nil, synthesizedAt: synthesized)
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
                             feedURL: show.feedURL, synthesized: true)
            }
        }
        UserDefaults.standard.set(true, forKey: AppStorageKeys.listenLogBackfilled)
        Logger.rss.notice("listen log backfilled: \(self.entries.count) entries")
    }

    // MARK: - Persistence (own JSON file in Application Support)

    /// The seam to disk (Application Support, one document).
    private nonisolated static var ablage: Ablage? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { Ablage(directory: $0) }
    }
    private static let documentName = "podcast-listen-log.json"
    private static var documentURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(documentName)
    }

    /// The rows the log lives in. The document is read only when the rows
    /// hold nothing, and then poured into them once.
    private var rowStore: KeyedRowStore<Entry>?
    private var rowsOpened = false
    /// What the rows hold, as far as this run knows: the last LANDED write
    /// or the start read. Advances only when a write landed; a failed start
    /// read leaves it unknown, and then no write replaces the rows whole.
    private var rowBase: RowBase<[String: Entry]> = .fresh
    private var pendingWrite: Task<Void, Never>?

    private func openRows() async -> KeyedRowStore<Entry>? {
        if rowsOpened { return rowStore }
        rowsOpened = true
        do {
            rowStore = try await KeyedRowStore<Entry>(connection: try MaerDatabase.shared.connection(), table: .listenLog)
        } catch {
            Logger.rss.error("LISTENLOG rows open failed reason=\(String(describing: error), privacy: .public)")
        }
        return rowStore
    }

    /// The last handed-over write (tests).
    func awaitPendingWrites() async {
        await pendingWrite?.value
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let started = Date()
        // Rows first, synchronously through a reader (no async window
        // here: the load is lazy-synchronous before every mutation).
        do {
            let reader = try MaerDatabase.shared.readerNow()
            let rows = try KeyedRowStore<Entry>.loadNow(table: .listenLog, reader: reader)
            if !rows.isEmpty {
                entries = rows
                rowBase = .known(rows)
                migrateSynthesizedFlag()
                healBookkeepingDates()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Logger.rss.notice("LISTENLOG start: entries=\(rows.count) ms=\(ms)")
                return
            }
            rowBase = .fresh
        } catch {
            // The rows could not be READ (not: hold nothing). This run reads
            // the document that was set aside, once, and migrates nothing;
            // the rows stay unknown, so the first write upserts and removes
            // nothing, and they heal on the next successful open.
            rowBase = .unknown
            let fallback = Self.ablage?.loadNow([String: Entry].self, name: Self.documentName).value
                ?? Self.ablage?.loadNow([String: Entry].self, name: Self.documentName + ".migrated").value
            if let fallback {
                entries = fallback
                migrateSynthesizedFlag()
                healBookkeepingDates()
            }
            Logger.rss.error("LISTENLOG rows read failed reason=\(String(describing: error), privacy: .public) fallback=migrated entries=\(fallback?.count ?? 0)")
            return
        }
        // The document: corrupt is kept aside by the seam and never buried
        // by an empty persist. Read once more after the move, then poured
        // into the rows and set aside as .migrated.
        guard let decoded = Self.ablage?.loadNow([String: Entry].self, name: Self.documentName).value else { return }
        entries = decoded
        migrateSynthesizedFlag()
        healBookkeepingDates()
        let stock = entries
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, let rows = await self.openRows() else { return }
            do {
                let written = try await rows.replaceAll(stock)
                if let url = Self.documentURL { try DocumentMigration.setAside(url) }
                self.rowBase = .known(stock)
                Logger.rss.notice("LISTENLOG migrate: entries=\(written)")
            } catch {
                Logger.rss.error("LISTENLOG migrate failed reason=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The eighth `.last` occurrence booked `playedAt = duration`. Seconds
    /// scale, rendered as 1970. The REAL moment is not lost: the position
    /// store still carries the entry's timestamp, so this is a read, not an
    /// invention. Runs at every load, in memory; a healed value is
    /// millisecond-scale and never matches the criterion again.
    private func healBookkeepingDates() {
        var healed = 0
        for (guid, entry) in entries {
            guard let corrected = Self.healedPlayedAt(
                current: entry.playedAt,
                stored: ListeningStore.backup(guid)) else { continue }
            var fixed = entry
            fixed.playedAt = corrected
            entries[guid] = fixed
            healed += 1
        }
        if healed > 0 {
            persist()
            Logger.rss.notice("LISTENLOG healed \(healed) bookkeeping dates from the position store")
        }
    }

    /// A duration is seconds (< 1e5 covers 27 hours), a real moment is
    /// milliseconds since 1970. The scales cannot collide. nil = leave it.
    nonisolated static func healedPlayedAt(current: Double, stored: [Double]?) -> Double? {
        guard current < 100_000, let ts = ProgressMark.timestamp(stored), ts >= 100_000 else { return nil }
        return ts
    }

    /// Entries written before the flag existed cannot be told apart
    /// anymore. And the log's whole first generation IS the backfill. They
    /// are therefore marked time-unknown (conservative: a show loses its week
    /// count for a while, but nothing is falsely "recently heard"). Runs once
    /// per load, in memory; the next persist carries it along.
    private func migrateSynthesizedFlag() {
        let stale = entries.filter { $0.value.synthesizedAt == nil }
        guard !stale.isEmpty else { return }
        for guid in stale.keys { entries[guid]?.synthesizedAt = true }
        Logger.rss.notice("listen log: \(stale.count) pre-flag entries marked as time-unknown")
    }

    private func persist() {
        guard !suspendPersist else { return }
        // Only the entries that changed go to the rows, in order: each write
        // waits for the one before it and diffs against the log of the
        // write before. A lost write self-heals on the next transition (the
        // log is derived from localPosition state).
        let snapshot = entries
        let previous = pendingWrite
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, let rows = await self.openRows() else { return }
            // The base is read HERE, after the write before landed or
            // failed: a failed write leaves it, so this diff still starts
            // from what the rows really hold.
            let base = self.rowBase
            do {
                switch base.plan {
                case .diff:
                    let written = try await rows.apply(previous: base.knownValue ?? [:], current: snapshot)
                    if written.upserted + written.removed > 0 {
                        Logger.rss.notice("LISTENLOG save: upserted=\(written.upserted) removed=\(written.removed)")
                    }
                case .whole:
                    let written = try await rows.replaceAll(snapshot)
                    Logger.rss.notice("LISTENLOG save: whole=\(written)")
                case .upsertOnly:
                    let written = try await rows.apply(previous: [:], current: snapshot)
                    Logger.rss.notice("LISTENLOG save: upsertOnly=\(written.upserted) (rows unknown)")
                }
                self.rowBase = .known(snapshot)
            } catch {
                Logger.rss.error("LISTENLOG save failed reason=\(String(describing: error), privacy: .public) base kept")
            }
        }
    }

    /// The chronological history (pure, tested). Tombstoned entries
    /// (marked unplayed, no newer play) are hidden, newest play first.
    /// MUST live outside #if DEBUG. It landed inside the test-seam
    /// block and broke the RELEASE archive (debug suites can never catch a
    /// DEBUG-gate hole; the release-compile gate now exists for exactly this).
    nonisolated static func historyList(_ entries: [String: Entry]) -> [Entry] {
        entries.values.filter(\.isPlayed).sorted { $0.playedAt > $1.playedAt }
    }

    /// The visible history of the loaded log.
    func history() -> [Entry] {
        loadIfNeeded()
        return Self.historyList(entries)
    }

    #if DEBUG
    /// Test seam: reset in-memory state (file untouched).
    func _resetForTest() { entries = [:]; loaded = true }
    #endif
}
