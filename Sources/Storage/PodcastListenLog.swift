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
    /// Enrolled where it is built, so a change of account reaches the log
    /// at its moment (`followOwner`); built at start (`followAtStart`).
    static let shared = AccessFollowers.enrolled(PodcastListenLog(upNext: PlayQueue.shared))

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
        /// "heard", but answers no honest WHEN. Optional in the stored shape;
        /// every writer sets it.
        var synthesizedAt: Bool?

        var isPlayed: Bool { unplayedAt.map { playedAt > $0 } ?? true }

        /// Does `playedAt` answer "when"? Only stamped transitions do.
        /// Dormancy ranking asks THIS, never `playedAt > 0`. An entry that
        /// does not say (an older stored shape) answers no honest when.
        var hasObservedTime: Bool { synthesizedAt == false }
    }

    /// guid → entry (dedup; the latest transition wins).
    private(set) var entries: [String: Entry] = [:]
    private var loaded = false
    /// Bulk passes (backfill/rescan) coalesce the per-hit file writes.
    private var suspendPersist = false
    /// The rows, one per guid, and their one write chain (`RowKeeper`); a
    /// witness hands in a database file of its own.
    private let keeper: RowKeeper<Entry>
    private let database: MaerDatabase
    /// Hands the log to the account that holds the device's stock, like
    /// every family on the shelf: what was heard under another account
    /// rests there and comes back with it; nothing is deleted.
    private let follower: ShelfFollower?
    /// The account signed in now; a witness hands in its own.
    private let identity: () -> String?
    /// A hand-over that could not happen (rows unread, a rest not laid),
    /// tried again before every note and at every change of way, and the
    /// notes taken meanwhile, written once the log belongs to the account
    /// they were heard under. In memory only: the log is derived from the
    /// stands, so a note lost to a kill comes back at the next transition.
    private var hold = HandOverHold<@MainActor () -> Void>()
    /// Waiting notes after their hand-over, written in chunks with a yield
    /// between them and one write at the end, like the bulk entry
    /// (`noteReconciled(batched:before:)`). A next hand-over writes what is left
    /// first, so no note lands under the account after.
    private var replayQueue: [@MainActor () -> Void] = []
    private var replaying: Task<Void, Never>?
    /// How many writes of the rows the notes asked for, for the witnesses.
    private(set) var rowWrites = 0
    nonisolated static let shelfFamily = "listen-log"

    /// The Up Next a played mark adopted from elsewhere takes its episode
    /// out of; none for a log built without one.
    private let upNext: PlayQueue?

    init(database: MaerDatabase = .shared, identity: @escaping () -> String? = { AccessFollowers.identity },
         upNext: PlayQueue? = nil) {
        self.database = database
        self.identity = identity
        self.upNext = upNext
        keeper = RowKeeper(database: database, table: .listenLog, label: "LISTENLOG", logsSaves: true)
        let follower = database.restingShelf.map { ShelfFollower(family: Self.shelfFamily, shelf: $0, label: "LISTENLOG") }
        self.follower = follower
        // Rows read after a failed start join the log by its own rule: a
        // tombstone yields only to a newer play (`adopted`), never "the run
        // wins", which would undo a tombstone nobody read.
        keeper.adopt = { [weak self] read in
            guard let self else { return }
            self.entries = Self.adopted(read: read, run: self.entries)
        }
        keeper.mark = { [weak follower] in follower?.mark() }
    }

    // MARK: - Owner (the log follows the account like every family)

    /// What rests for an account: its entries, and its rows this build
    /// cannot decode, as stored (key and payload), so they never stand under
    /// another account and come back unread.
    nonisolated struct Resting: Codable, Equatable {
        var entries: [String: Entry]
        var unread: [String: Data]? = nil
    }

    /// The rows are being written; their unread part is read after.
    private struct RowsStillWriting: Error {}

    /// The rows this build cannot decode, as stored; nil when there are
    /// none. Throws when the read fails, so a hand-over holds.
    private func undecodedRows() throws -> [String: Data]? {
        guard keeper.startIncomplete else { return nil }
        // Read after the chain, never beside it: a hand-over right after a
        // replacement would see the rows before its write landed.
        guard keeper.mayReadBesideTheChain else {
            Logger.rss.notice("LISTENLOG owner held: a write of the rows is on its way")
            throw RowsStillWriting()
        }
        let rows = try keeper.undecodedNow()
        return rows.isEmpty ? nil : rows
    }

    /// Hands the log to `scope` by the shelf's one rule
    /// (`RestingShelf.handOver`): no holder yet is the first account, which
    /// takes what this device heard; another holder's entries rest under it
    /// and the entries resting for `scope` take their place. False while
    /// the hand-over cannot happen (rows unread, a rest not laid); it is
    /// then tried again before the next note, and notes wait for it.
    @discardableResult
    func follow(owner scope: String, previous: String? = nil) -> Bool {
        replayAllNow()
        let handed = handOver(to: scope, previous: previous)
        guard handed else {
            hold.hold(scope: scope, previous: previous)
            return false
        }
        let (waited, elsewhere) = hold.handedOver(to: scope)
        if elsewhere > 0 {
            Logger.rss.notice("LISTENLOG notes wait for another account count=\(elsewhere) handedTo=\(scope, privacy: .private(mask: .hash))")
        }
        guard !waited.isEmpty else { return true }
        Logger.rss.notice("LISTENLOG notes written after the hand-over count=\(waited.count)")
        replayQueue += waited
        guard replaying == nil else { return true }
        replaying = Task { [weak self] in
            while self?.replayNextChunk() == true { await Task.yield() }
        }
        return true
    }

    /// One chunk of the waiting notes; false once none is left, after the
    /// one write of them all.
    private func replayNextChunk() -> Bool {
        guard !replayQueue.isEmpty else {
            replaying = nil
            persist()
            return false
        }
        replayNotes(min(200, replayQueue.count))
        return true
    }

    /// The notes still queued, written now: before a hand-over, so they
    /// land under the account they were heard under.
    private func replayAllNow() {
        guard !replayQueue.isEmpty else { return }
        replayNotes(replayQueue.count)
        persist()
    }

    private func replayNotes(_ count: Int) {
        let chunk = replayQueue.prefix(count)
        replayQueue.removeFirst(chunk.count)
        let outer = suspendPersist
        suspendPersist = true
        chunk.forEach { $0() }
        suspendPersist = outer
    }

    private func handOver(to scope: String, previous: String?) -> Bool {
        guard let follower else { return true }
        loadIfNeeded()
        // Rows the start could not read are read again first: once read,
        // the hand-over goes on here instead of after the next write.
        _ = keeper.readAgainNow()
        let rested = entries.count
        // Unread rows join the log of this run once read (`adopted`): the
        // holder's would come back.
        guard let step = follower.follow(
            to: scope, previous: previous, unread: keeper.startReadFailed, landing: .marked,
            landed: { [database] name in
                try OwnerMark.stands(family: Self.shelfFamily, replacement: name, database: database)
            },
            current: {
                let unread = try undecodedRows()
                Logger.rss.notice("LISTENLOG owner rest taken at=\(Date().timeIntervalSince1970, privacy: .public) entries=\(self.entries.count) unread=\(unread?.count ?? 0)")
                return Resting(entries: entries, unread: unread)
            },
            replace: { rest, _, _ in try replace(with: rest) }) else { return false }
        switch step {
        case .kept: return true
        case .first: Logger.rss.notice("LISTENLOG owner first entries=\(rested)")
        case .unread: Logger.rss.notice("LISTENLOG owner held: rows unread")
        case .moved: Logger.rss.notice("LISTENLOG owner moved rested=\(rested) entries=\(self.entries.count)")
        }
        return step != .unread
    }

    /// The entries of the new owner replace the ones here, in the same
    /// transaction as the mark; the holding settles once the rows hold them.
    private func replace(with incoming: Resting?) throws {
        // What can throw comes first: a replacement that throws touches nothing.
        let leaving = try undecodedRows() ?? [:]
        entries = incoming?.entries ?? [:]
        let carried = keeper.carriedRows(leaving: leaving, coming: incoming?.unread ?? [:], kept: Set(entries.keys))
        keeper.write(emptying: .allowed, also: carried) { [weak self] in self?.entries }
        if !(incoming?.unread ?? [:]).isEmpty { keeper.noteRowsNotRead() }
    }

    /// At start: the log follows the account signed in now, against the
    /// device's stock owner; signed out, it stays with the stock.
    func followAtStart() {
        guard let scope = identity() else { return }
        follow(owner: scope, previous: StockOwner.owner(in: .standard))
    }

    /// A held hand-over, tried again.
    private func followIfHeld() {
        guard let target = hold.target else { return }
        follow(owner: target.scope, previous: target.previous)
    }

    /// Whether a note waits for a held hand-over: tried again first; while
    /// it still holds, the note is kept for after it.
    private func waitsForHandOver(_ note: @escaping @MainActor () -> Void) -> Bool {
        followIfHeld()
        guard hold.keep(note) else { return false }
        Logger.rss.notice("LISTENLOG note waits for the hand-over waiting=\(self.hold.waiting.count)")
        return true
    }

    // MARK: - Recording (the ONE hook; threshold logic stays in
    // PodcastProgressStore.state. Reused, never copied)

    /// Record a LOCAL played-transition candidate: evaluates the CURRENT
    /// stored state via the existing threshold logic and upserts on `.played`.
    /// Cheap + idempotent. Callers may invoke it on every position write.
    /// `synthesized`: the caller is a BULK pass (backfill/rescan) that merely
    /// books what the position store already knew. The resulting timestamp
    /// dates the bookkeeping, not a listen.
    /// `written`: the entry the caller has just stored, so it is not read
    /// straight back.
    func noteIfPlayed(guid: String, duration: Double, episodeTitle: String,
                      showTitle: String, feedURL: String, synthesized: Bool = false,
                      written: [Double]? = nil) {
        let stored = written ?? ListeningStore.backup(guid)
        guard case .played = ProgressMark.state(stored: stored, currentDuration: duration,
                                                 tail: PlayedTail.seconds(forItemId: guid)) else { return }
        // Through ProgressMark, never .last: on a three-value entry .last is
        // the DURATION. The history booked playedAt = 3600 and rendered 1970.
        let ts = ProgressMark.timestamp(stored)
            ?? Date().timeIntervalSince1970 * 1000
        upsertPlayed(guid: guid, episodeTitle: episodeTitle, showTitle: showTitle,
                     feedURL: feedURL, duration: duration, playedAt: ts,
                     synthesized: synthesized)
    }

    /// Explicit "mark unplayed": tombstone the entry (kept, flagged). The
    /// history survives, and only a newer real play-through flips it back.
    /// `at` carries a remote transition's own timestamp (reconcile ordering).
    /// Over rows the start could not read, a guid this memory lacks gets a
    /// tombstone of its own, so the choice survives the adoption of the rows
    /// (it hides the entry until a newer play); with the rows read, a guid
    /// that never played has nothing to mark, and a line says so.
    func markUnplayed(guid: String, at ts: Double? = nil) {
        let stamp = ts ?? Date().timeIntervalSince1970 * 1000
        if waitsForHandOver({ [weak self] in self?.markUnplayed(guid: guid, at: stamp) }) { return }
        loadIfNeeded()
        guard var entry = entries[guid] else {
            guard keeper.startReadFailed else {
                Logger.rss.notice("LISTENLOG mark unplayed: no entry, nothing played to mark")
                return
            }
            entries[guid] = Entry(guid: guid, episodeTitle: "", showTitle: "", feedURL: "", duration: 0,
                                  playedAt: 0, unplayedAt: stamp, synthesizedAt: true)
            Logger.rss.notice("LISTENLOG mark unplayed over unread rows: tombstone kept for the adoption")
            persist()
            return
        }
        entry.unplayedAt = stamp
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
    /// `before`: each guid's entry as it was before the adoption (a missing
    /// key had none). Up Next is written once for the whole history.
    func noteReconciled(batched guids: [String], before: [String: [Double]]) async {
        var heard: [String] = []
        var index = 0
        while index < guids.count {
            let end = min(index + 200, guids.count)
            heard += noteChunk(guids[index..<end], before: before)
            index = end
            await Task.yield()
        }
        if !heard.isEmpty { upNext?.markedPlayed(heard) }
    }

    /// `before`: each guid's entry as it was before the adoption (a missing
    /// key had none). Only an episode that became played leaves Up Next
    /// (`HeardElsewhere`).
    func noteReconciled(guids: some Sequence<String>, before: [String: [Double]]) {
        let heard = noteChunk(guids, before: before)
        if !heard.isEmpty { upNext?.markedPlayed(heard) }
    }

    /// The log's part of an adoption; answers the episodes that became played.
    private func noteChunk(_ guids: some Sequence<String>, before: [String: [Double]]) -> [String] {
        var heard: [String] = []
        for guid in guids {
            let resolved = PodcastSubscriptions.shared.episode(guid: guid)
            let duration = resolved?.episode.duration ?? 0
            switch PodcastProgressStore.shared.state(guid: guid, duration: duration) {
            case .played:
                let was = HeardElsewhere.isPlayed(before[guid], duration: duration,
                                                  tail: PlayedTail.seconds(forItemId: guid))
                if HeardElsewhere.became(wasPlayed: was, isPlayed: true) { heard.append(guid) }
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
        return heard
    }

    /// Targeted re-scan of specific shows (Apple import: metadata is present
    /// there). The backfill body without the one-time flag.
    func rescan(shows: [PodcastShow]) {
        bulkPass { [weak self] in self?.noteAll(shows, stand: { ListeningStore.backup($0) }) }
    }

    /// A bulk pass (backfill, rescan): its notes coalesce into one write.
    /// While a hand-over is held the whole pass waits for it as one note,
    /// and `done` runs only once the pass ran.
    private func bulkPass(_ body: @escaping @MainActor () -> Void, done: (@MainActor () -> Void)? = nil) {
        if waitsForHandOver({ [weak self] in self?.bulkPass(body, done: done) }) { return }
        loadIfNeeded()
        let outer = suspendPersist
        suspendPersist = true
        body()
        suspendPersist = outer
        if !outer { persist() }
        done?()
    }

    /// Every played episode of `shows`, booked as the position store knows it.
    private func noteAll(_ shows: [PodcastShow], stand: (String) -> [Double]?) {
        for show in shows {
            for episode in show.episodes {
                noteIfPlayed(guid: episode.guid, duration: episode.duration,
                             episodeTitle: episode.title, showTitle: show.title,
                             feedURL: show.feedURL, synthesized: true, written: stand(episode.guid))
            }
        }
    }

    private func upsertPlayed(guid: String, episodeTitle: String, showTitle: String,
                              feedURL: String, duration: Double, playedAt: Double,
                              synthesized: Bool = false) {
        if waitsForHandOver({ [weak self] in
            self?.upsertPlayed(guid: guid, episodeTitle: episodeTitle, showTitle: showTitle, feedURL: feedURL,
                               duration: duration, playedAt: playedAt, synthesized: synthesized)
        }) { return }
        loadIfNeeded()
        if var existing = entries[guid] {
            // Latest transition wins; a tombstone yields only to a NEWER play.
            // Titles are no transition: a note that is not newer still fills
            // what an earlier note had to leave empty (a reconciled stand
            // whose episode was not in the stock yet). Before, the promise
            // "later upserts enrich empty fields" held only for a newer play.
            guard playedAt > existing.playedAt || existing.unplayedAt != nil else {
                let enriched = Self.enriched(existing, episodeTitle: episodeTitle, showTitle: showTitle,
                                             feedURL: feedURL)
                if enriched != existing {
                    entries[guid] = enriched
                    persist()
                }
                return
            }
            if let unplayedAt = existing.unplayedAt, playedAt <= unplayedAt { return }
            existing.playedAt = max(existing.playedAt, playedAt)
            existing.synthesizedAt = Self.synthesized(existing.synthesizedAt, then: synthesized)
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

    /// The flag is set only once the pass ran: while a hand-over is held the
    /// notes would wait in memory, and a kill before it would lose the
    /// backfill for good. Without the flag the next start runs it again.
    /// `stand`: the position store's entry for a guid; a witness hands in its own.
    func backfillIfNeeded(shows: [PodcastShow],
                          stand: @escaping (String) -> [Double]? = { ListeningStore.backup($0) }) {
        guard !AppStorageKeys.bool(AppStorageKeys.listenLogBackfilled) else { return }
        bulkPass({ [weak self] in self?.noteAll(shows, stand: stand) }) { [weak self] in
            AppStorageKeys.set(true, for: AppStorageKeys.listenLogBackfilled)
            Logger.rss.notice("listen log backfilled: \(self?.entries.count ?? 0) entries")
        }
    }

    // MARK: - Persistence

    /// The waiting notes written and the last handed-over write (tests).
    func awaitPendingWrites() async {
        await replaying?.value
        await keeper.awaitPendingWrites()
    }

    /// The rows, synchronously through the keeper (no async window here:
    /// the load is lazy-synchronous before every mutation). A read that
    /// failed as a whole leaves the log empty and the keeper holding every
    /// write until the rows are read and adopted.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let started = Date()
        guard let rows = keeper.startNow() else { return }
        entries = rows
        healBookkeepingDates()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Logger.rss.notice("LISTENLOG start: entries=\(rows.count) ms=\(ms)")
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
        // What stays before 2000 is shown without a date; counted, so the
        // device says how many there are.
        let unhealed = entries.values.filter { $0.playedAt < Self.earliestPlausibleMs }.count
        let untitled = entries.values.filter { $0.episodeTitle.isEmpty }.count
        Logger.rss.notice("LISTENLOG dates healed=\(healed) before2000=\(unhealed) untitled=\(untitled) of=\(self.entries.count)")
        if healed > 0 { persist() }
    }

    /// The earliest moment a play can honestly carry, 2000-01-01 in
    /// milliseconds. Every real listen in this log is younger; a value below
    /// it is a wrong scale, never a date.
    nonisolated static let earliestPlausibleMs: Double = 946_684_800_000

    /// A duration is seconds (< 1e5 covers 27 hours), a real moment is
    /// milliseconds since 1970. A moment in SECONDS (a source that wrote the
    /// Unix time, measured as three entries shown as 1970 on the device) is
    /// the same moment times 1000. Anything else below 2000 takes the
    /// position store's own moment, when that is one. nil = leave it.
    nonisolated static func healedPlayedAt(current: Double, stored: [Double]?) -> Double? {
        guard current < earliestPlausibleMs else { return nil }
        if current >= 100_000, current * 1000 >= earliestPlausibleMs { return current * 1000 }
        guard let ts = ProgressMark.timestamp(stored), ts >= earliestPlausibleMs else { return nil }
        return ts
    }

    /// The moment a row shows, or nil when the entry has none that can be
    /// true: a date before 2000 is never shown, the row then says nothing
    /// about WHEN instead of "56 years ago".
    nonisolated static func shownDate(_ entry: Entry) -> Date? {
        guard entry.playedAt >= earliestPlausibleMs else { return nil }
        return Date(timeIntervalSince1970: entry.playedAt / 1000)
    }

    private func persist() {
        guard !suspendPersist else { return }
        rowWrites += 1
        // Only the entries that changed go to the rows, in order: each write
        // waits for the one before it and diffs against the log of the
        // write before. A lost write self-heals on the next transition (the
        // log is derived from localPosition state). The keeper takes the
        // log in its chain, reads first over rows the start could not read
        // and adopts them by the log's rule (`init`). The log never removes
        // an entry (unplayed is a mark on it), so an empty snapshot is never
        // what a write means.
        keeper.write(emptying: .refused) { [weak self] in self?.entries }
    }

    /// The rows read after a failed start with what this run holds, by guid
    /// (`merged` where both hold one).
    nonisolated static func adopted(read: [String: Entry], run: [String: Entry]) -> [String: Entry] {
        read.merging(run) { fromRows, fromRun in merged(read: fromRows, run: fromRun) }
    }

    /// Whether a newer play leaves the entry synthesized: a stamped
    /// transition upgrades a synthesized one (never back), and an entry that
    /// does not say counts as synthesized, the side that claims no when.
    nonisolated static func synthesized(_ existing: Bool?, then synthesized: Bool) -> Bool {
        (existing ?? true) && synthesized
    }

    /// One guid held by the rows and by this run, by the log's own rule: the
    /// later play and the later tombstone both stand, so a tombstone yields
    /// only to a newer play (`isPlayed`), whichever side holds what. The
    /// side with the later play carries its stamp kind; an empty title or
    /// feed and a missing duration are filled from the other side.
    nonisolated static func merged(read: Entry, run: Entry) -> Entry {
        let (later, other) = run.playedAt >= read.playedAt ? (run, read) : (read, run)
        var out = later
        out.unplayedAt = [read.unplayedAt, run.unplayedAt].compactMap { $0 }.max()
        if out.episodeTitle.isEmpty { out.episodeTitle = other.episodeTitle }
        if out.showTitle.isEmpty { out.showTitle = other.showTitle }
        if out.feedURL.isEmpty { out.feedURL = other.feedURL }
        if out.duration <= 0 { out.duration = other.duration }
        return out
    }

    /// The chronological history (pure, tested). Tombstoned entries
    /// (marked unplayed, no newer play) are hidden, newest play first.
    /// MUST live outside #if DEBUG. It landed inside the test-seam
    /// block and broke the RELEASE archive (debug suites can never catch a
    /// DEBUG-gate hole; the release-compile gate now exists for exactly this).
    nonisolated static func historyList(_ entries: [String: Entry]) -> [Entry] {
        entries.values.filter(\.isPlayed).sorted { $0.playedAt > $1.playedAt }
    }

    /// The visible history of the loaded log. Entries without titles take
    /// them from the episode where it resolves now, without a new listen;
    /// what changed is written once.
    func history(resolve: (String) -> (episodeTitle: String, showTitle: String, feedURL: String)? = {
        PodcastSubscriptions.shared.episode(guid: $0).map { ($0.episode.title, $0.show.title, $0.show.feedURL) }
    }) -> [Entry] {
        loadIfNeeded()
        var filled = 0
        for (guid, entry) in entries where entry.episodeTitle.isEmpty || entry.showTitle.isEmpty {
            guard let found = resolve(guid) else { continue }
            let enriched = Self.enriched(entry, episodeTitle: found.episodeTitle, showTitle: found.showTitle,
                                         feedURL: found.feedURL)
            guard enriched != entry else { continue }
            entries[guid] = enriched
            filled += 1
        }
        if filled > 0 {
            persist()
            Logger.rss.notice("LISTENLOG enriched \(filled) entries without titles")
        }
        return Self.historyList(entries)
    }

    /// Empty fields take the given values; fields that hold a value keep it.
    nonisolated static func enriched(_ entry: Entry, episodeTitle: String, showTitle: String,
                                     feedURL: String) -> Entry {
        var out = entry
        if out.episodeTitle.isEmpty { out.episodeTitle = episodeTitle }
        if out.showTitle.isEmpty { out.showTitle = showTitle }
        if out.feedURL.isEmpty { out.feedURL = feedURL }
        return out
    }

    #if DEBUG
    /// Test seam: reset in-memory state (file untouched).
    func _resetForTest() { entries = [:]; loaded = true }
    #endif
}

extension PodcastListenLog: AccessFollower {
    var followerName: String { "listen-log" }

    /// The log follows a change of account at the moment of the change.
    func followOwner(previous: String?) {
        guard let scope = identity() else { return }
        follow(owner: scope, previous: previous)
    }

    /// No carrier: the log stays on this device. A held hand-over is tried
    /// again at every change of way, besides before the next note.
    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        followIfHeld()
    }
}
