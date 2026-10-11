// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The listening history of books and songs (data layer only): one entry
/// per title id, the time of its latest hearing, newest first on the page.
/// A book comes in when its position crosses into played or when it is
/// marked finished, and leaves the page when that mark is taken back (a
/// tombstone, like the episodes of `PodcastListenLog`). A song comes in once
/// half of it or four minutes have played, whichever comes first, once per
/// hearing (`songHeard`); hearing it again moves its one entry to the top.
///
/// It follows the account like every family on the shelf: what was heard
/// under another account rests there and comes back with it, nothing is
/// deleted. It starts empty: nothing is filled in from before it existed.
@MainActor
final class ListenHistory {
    /// Enrolled where it is built, so a change of account reaches the
    /// history at its moment (`followOwner`); built at start (`followAtStart`).
    static let shared = AccessFollowers.enrolled(ListenHistory())

    nonisolated enum Family: String, Codable, Sendable, CaseIterable {
        case book
        case music
    }

    nonisolated struct Entry: Codable, Equatable, Sendable {
        let id: String
        var family: Family
        var title: String
        /// The author of a book, the artist of a song.
        var subtitle: String
        /// Epoch ms of the latest hearing.
        var heardAt: Double
        /// Epoch ms of a taken back "finished". A tombstone: only a NEWER
        /// hearing brings the entry back.
        var unheardAt: Double?

        var isHeard: Bool { unheardAt.map { heardAt > $0 } ?? true }
    }

    /// Title id to entry; the latest hearing wins.
    private(set) var entries: [String: Entry] = [:]
    private var loaded = false
    /// The rows, one per title, and their one write chain; a witness hands
    /// in a database file of its own.
    private let keeper: RowKeeper<Entry>
    private let database: MaerDatabase
    /// Hands the history to the account that holds the device's stock.
    private let follower: ShelfFollower?
    /// The account signed in now; a witness hands in its own.
    private let identity: () -> String?
    /// A hand-over that could not happen (rows unread, a rest not laid),
    /// tried again before every entry and at every change of way, and the
    /// entries taken meanwhile, written once the history belongs to the
    /// account they were heard under. In memory only, like the listen log.
    private var hold = HandOverHold<@MainActor () -> Void>()
    nonisolated static let shelfFamily = "listen-history"

    init(database: MaerDatabase = .shared, identity: @escaping () -> String? = { AccessFollowers.identity }) {
        self.database = database
        self.identity = identity
        keeper = RowKeeper(database: database, table: .listenHistory, label: "HISTORY", logsSaves: true)
        let follower = database.restingShelf.map { ShelfFollower(family: Self.shelfFamily, shelf: $0, label: "HISTORY") }
        self.follower = follower
        // Rows read after a failed start join by the history's own rule: a
        // tombstone yields only to a newer hearing (`merged`).
        keeper.adopt = { [weak self] read in
            guard let self else { return }
            self.entries = Self.adopted(read: read, run: self.entries)
        }
        keeper.mark = { [weak follower] in follower?.mark() }
    }

    // MARK: - The rules (pure)

    /// The seconds after which a song counts as heard: half of it, at most
    /// four minutes. A song without a known length never counts.
    nonisolated static func songThreshold(duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        return min(duration / 2, 240)
    }

    /// Whether this tick enters the song: its position within the song has
    /// passed the threshold and this hearing has not entered it yet. A
    /// hearing ends when the song changes or its position goes back under
    /// the threshold, so one hearing writes once and a second one moves the
    /// entry to the top. `noted` is the song this hearing entered already.
    nonisolated static func songHeard(song: String, position: Double, duration: Double,
                                      noted: String?) -> (enter: Bool, noted: String?) {
        guard let threshold = songThreshold(duration: duration), position >= threshold else {
            return (false, noted == song ? nil : noted)
        }
        guard noted != song else { return (false, noted) }
        return (true, song)
    }

    /// The page shows its rows in steps: opening it read and sorted 20,000
    /// entries in about 110 ms (measured on the simulator, debug build), so
    /// it draws the first step and the next one once the end appears.
    nonisolated static let pageStep = 200

    /// The glyph of the tile that opens the history, in both tabs.
    nonisolated static let systemImage = "clock.arrow.circlepath"

    /// How many rows the page shows once its last shown row appeared: one
    /// step more, at most all.
    nonisolated static func shownAfterEnd(_ shown: Int, of total: Int) -> Int {
        min(total, shown + pageStep)
    }

    /// The moment a row shows, or nil when it cannot be true (before 2000).
    nonisolated static func shownDate(_ entry: Entry) -> Date? {
        guard entry.heardAt >= PodcastListenLog.earliestPlausibleMs else { return nil }
        return Date(timeIntervalSince1970: entry.heardAt / 1000)
    }

    /// The page of one family: heard entries, newest first.
    nonisolated static func historyList(_ entries: [String: Entry], family: Family) -> [Entry] {
        entries.values.filter { $0.family == family && $0.isHeard }.sorted { $0.heardAt > $1.heardAt }
    }

    /// One id held by the rows and by this run: the later hearing and the
    /// later tombstone both stand, empty texts are filled from the other.
    nonisolated static func merged(read: Entry, run: Entry) -> Entry {
        let (later, other) = run.heardAt >= read.heardAt ? (run, read) : (read, run)
        var out = later
        out.unheardAt = [read.unheardAt, run.unheardAt].compactMap { $0 }.max()
        if out.title.isEmpty { out.title = other.title }
        if out.subtitle.isEmpty { out.subtitle = other.subtitle }
        return out
    }

    nonisolated static func adopted(read: [String: Entry], run: [String: Entry]) -> [String: Entry] {
        read.merging(run) { fromRows, fromRun in merged(read: fromRows, run: fromRun) }
    }

    // MARK: - Owner (the history follows the account like every family)

    /// What rests for an account: its entries, and its rows this build
    /// cannot decode, as stored, so they come back unread.
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
            Logger.library.notice("HISTORY owner held: a write of the rows is on its way")
            throw RowsStillWriting()
        }
        let rows = try keeper.undecodedNow()
        return rows.isEmpty ? nil : rows
    }

    /// Hands the history to `scope` by the shelf's one rule
    /// (`RestingShelf.handOver`). False while the hand-over cannot happen;
    /// it is then tried again before the next entry, and entries wait for it.
    @discardableResult
    func follow(owner scope: String, previous: String? = nil) -> Bool {
        guard handOver(to: scope, previous: previous) else {
            hold.hold(scope: scope, previous: previous)
            return false
        }
        let waited = hold.handedOver()
        if !waited.isEmpty {
            Logger.library.notice("HISTORY entries written after the hand-over count=\(waited.count)")
            waited.forEach { $0() }
        }
        return true
    }

    private func handOver(to scope: String, previous: String?) -> Bool {
        guard let follower else { return true }
        loadIfNeeded()
        // Rows the start could not read are read again first.
        _ = keeper.readAgainNow()
        let rested = entries.count
        guard let step = follower.follow(
            to: scope, previous: previous, unread: keeper.startReadFailed, landing: .marked,
            landed: { [database] name in
                try OwnerMark.stands(family: Self.shelfFamily, replacement: name, database: database)
            },
            current: {
                let unread = try undecodedRows()
                Logger.library.notice("HISTORY owner rest taken at=\(Date().timeIntervalSince1970, privacy: .public) entries=\(self.entries.count) unread=\(unread?.count ?? 0)")
                return Resting(entries: entries, unread: unread)
            },
            replace: { rest, _, _ in try replace(with: rest) }) else { return false }
        switch step {
        case .kept: return true
        case .first: Logger.library.notice("HISTORY owner first entries=\(rested)")
        case .unread: Logger.library.notice("HISTORY owner held: rows unread")
        case .moved: Logger.library.notice("HISTORY owner moved rested=\(rested) entries=\(self.entries.count)")
        }
        return step != .unread
    }

    /// The entries of the new owner replace the ones here, in the same
    /// transaction as the mark.
    private func replace(with incoming: Resting?) throws {
        // What can throw comes first: a replacement that throws touches nothing.
        let leaving = try undecodedRows() ?? [:]
        entries = incoming?.entries ?? [:]
        let carried = keeper.carriedRows(leaving: leaving, coming: incoming?.unread ?? [:], kept: Set(entries.keys))
        keeper.write(emptying: .allowed, also: carried) { [weak self] in self?.entries }
        if !(incoming?.unread ?? [:]).isEmpty { keeper.noteRowsNotRead() }
    }

    /// At start: the history follows the account signed in now, against
    /// the device's stock owner; signed out, it stays with the stock.
    func followAtStart() {
        guard let scope = identity() else { return }
        follow(owner: scope, previous: StockOwner.owner(in: .standard))
    }

    /// A held hand-over, tried again.
    private func followIfHeld() {
        guard let target = hold.target else { return }
        follow(owner: target.scope, previous: target.previous)
    }

    /// Whether an entry waits for a held hand-over: tried again first;
    /// while it still holds, the entry is kept for after it.
    private func waitsForHandOver(_ entry: @escaping @MainActor () -> Void) -> Bool {
        followIfHeld()
        guard hold.keep(entry) else { return false }
        Logger.library.notice("HISTORY entry waits for the hand-over waiting=\(self.hold.waiting.count)")
        return true
    }

    // MARK: - Recording

    /// A hearing of `id` at `at` (epoch ms): its one entry takes the time
    /// and moves to the top; a tombstone yields only to a newer hearing.
    func noteHeard(id: String, family: Family, title: String, subtitle: String,
                   at: Double = Date().timeIntervalSince1970 * 1000) {
        if waitsForHandOver({ [weak self] in
            self?.noteHeard(id: id, family: family, title: title, subtitle: subtitle, at: at)
        }) { return }
        loadIfNeeded()
        let heard = Entry(id: id, family: family, title: title, subtitle: subtitle, heardAt: at)
        let next = entries[id].map { Self.merged(read: $0, run: heard) } ?? heard
        guard next != entries[id] else { return }
        entries[id] = next
        persist()
    }

    /// "Finished" taken back: the entry stays, flagged, and leaves the page
    /// until a newer hearing.
    func markUnheard(id: String, at: Double = Date().timeIntervalSince1970 * 1000) {
        if waitsForHandOver({ [weak self] in self?.markUnheard(id: id, at: at) }) { return }
        loadIfNeeded()
        guard var entry = entries[id] else { return }
        entry.unheardAt = max(entry.unheardAt ?? 0, at)
        entries[id] = entry
        persist()
    }

    /// A book marked finished comes in, a finish taken back leaves the page.
    func noteFinished(_ finished: Bool, id: String, title: String, subtitle: String) {
        if finished {
            noteHeard(id: id, family: .book, title: title, subtitle: subtitle)
        } else {
            markUnheard(id: id)
        }
    }

    /// The page of one family.
    func history(_ family: Family) -> [Entry] {
        loadIfNeeded()
        return Self.historyList(entries, family: family)
    }

    // MARK: - Persistence

    func awaitPendingWrites() async {
        await keeper.awaitPendingWrites()
    }

    /// The rows, synchronously through the keeper, before every mutation.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let started = Date()
        guard let rows = keeper.startNow() else { return }
        entries = rows
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Logger.library.notice("HISTORY start: entries=\(rows.count) ms=\(ms)")
    }

    /// Only the entries that changed go to the rows. The history never
    /// removes an entry (taken back is a mark on it), so an empty snapshot
    /// is never what a write means.
    private func persist() {
        keeper.write(emptying: .refused) { [weak self] in self?.entries }
    }
}

extension ListenHistory: AccessFollower {
    var followerName: String { "listen-history" }

    /// The history follows a change of account at the moment of the change.
    func followOwner(previous: String?) {
        guard let scope = identity() else { return }
        follow(owner: scope, previous: previous)
    }

    /// No carrier: the history stays on this device. A held hand-over is
    /// tried again at every change of way, besides before the next entry.
    func followAccess(signedIn: Bool, identityChanged: Bool, by caller: String) {
        followIfHeld()
    }
}
