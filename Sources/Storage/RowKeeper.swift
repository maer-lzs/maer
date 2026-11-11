// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Keeps a store's rows in one keyed table: the start read and the write
/// chain (`RowChain`, the one chain of every row store) with the diff of a
/// keyed table. The store keeps its rule and its memory; the keeper keeps
/// the rows, so the start read and the write are written once for every
/// keyed store.
///
/// A missing file is a fresh install and a missing table is empty, both
/// leave a fresh base. A read that could not read every row leaves the base
/// unknown with what it did read; a write then removes a row it read and
/// that is gone, never one nobody could read. A read that failed as a whole
/// read nothing: no write goes until the rows are read and the store took
/// them (`RowChain`, `adopt`). After the first landed write the base is
/// known and later removals apply. A failed write is logged and leaves the
/// base where it was, so the next write diffs against what really landed.
@MainActor
final class RowKeeper<Value: Codable & Equatable & Sendable> {
    typealias Rows = [String: Value]

    private let database: MaerDatabase
    private let table: KeyedRowStore<Value>.Table
    /// The log prefix of the store, so a line names its owner.
    private let label: String
    /// Whether a landed write that changed rows speaks a line (the stores
    /// that logged their saves before they had a keeper).
    private let logsSaves: Bool
    /// The one write chain.
    private let chain: RowChain<Rows>
    /// The one opening of the rows: every caller awaits the same task. An
    /// opening that failed is not kept: the next write opens again.
    private var opening: Task<KeyedRowStore<Value>?, Never>?

    init(database: MaerDatabase, table: KeyedRowStore<Value>.Table, label: String, logsSaves: Bool = false) {
        self.database = database
        self.table = table
        self.label = label
        self.logsSaves = logsSaves
        self.chain = RowChain(label: label)
    }

    /// The rows this build cannot decode, as stored (key and payload);
    /// empty without a file. Throws when the read fails.
    func undecodedNow() throws -> [String: Data] {
        guard let reader = try database.readerNow() else { return [:] }
        return try KeyedRowStore<Value>.undecodedNow(table: table, reader: reader)
    }

    /// The statements that carry rows as stored at a hand-over, for a write
    /// of this keeper (`write(…also:)`): `leaving` leave the table, `coming`
    /// come back unread, never over a row the new stock holds (`kept`).
    nonisolated static func carriedRows(table: KeyedRowStore<Value>.Table, leaving: [String: Data],
                                        coming: [String: Data], kept: Set<String>) -> [SQLiteConnection.Statement] {
        let name = table.rawValue
        let gone = leaving.keys.filter { !kept.contains($0) }.sorted()
            .map { SQLiteConnection.Statement("DELETE FROM \(name) WHERE key = ?", [.text($0)]) }
        let back = coming.filter { !kept.contains($0.key) }.sorted { $0.key < $1.key }
            .map { SQLiteConnection.Statement("INSERT OR REPLACE INTO \(name) (key, payload) VALUES (?, ?)",
                                              [.text($0.key), .blob($0.value)]) }
        return gone + back
    }

    /// The same, for this keeper's table.
    func carriedRows(leaving: [String: Data], coming: [String: Data], kept: Set<String>) -> [SQLiteConnection.Statement] {
        Self.carriedRows(table: table, leaving: leaving, coming: coming, kept: kept)
    }

    /// What the rows hold, as far as this run knows.
    var base: RowBase<Rows> { chain.base }
    /// Whether the start read failed as a whole (`RowChain.startReadFailed`).
    var startReadFailed: Bool { chain.startReadFailed }
    /// Whether the rows may be read beside the chain now
    /// (`RowChain.mayReadBesideTheChain`).
    var mayReadBesideTheChain: Bool { chain.mayReadBesideTheChain }
    /// How the last refused wipe spoke (`RowChain.lastRefusal`).
    var lastRefusal: WipeRefusal? { chain.lastRefusal }
    /// Whether the start missed rows (`RowChain.startIncomplete`).
    var startIncomplete: Bool { chain.startIncomplete }
    /// Rows came back that this build does not read (`RowChain.noteRowsNotRead`).
    func noteRowsNotRead() { chain.noteRowsNotRead() }
    /// The store's adoption of rows read after a failed start: it takes the
    /// rows into its memory by its rule (`union` unless it has its own).
    /// Every store sets it at its start; a keeper without it holds every
    /// write over unread rows.
    var adopt: (@MainActor (Rows) -> Void)? {
        get { chain.adopt }
        set { chain.adopt = newValue }
    }
    /// What must land with the write that runs, in its transaction, and
    /// what hears that it landed (`ShelfFollower.mark` while a replacement
    /// of the stock is open); asked when the write runs.
    var mark: (@MainActor () -> (statements: [SQLiteConnection.Statement], landed: @MainActor () -> Void)?)?

    /// The synchronous start read, once, before the store sets its memory:
    /// the rows, or nil when the table holds nothing or the read failed.
    /// Rows that are there but do not decode leave the base unknown, and
    /// the store gets what did decode.
    func startNow() -> Rows? {
        started(with: Result { try Self.readNow(database: database, table: table) })
    }

    /// The start read alone, without the main actor: a store that may not
    /// read on the main thread runs it on a background task and hands the
    /// result to `started(with:)`.
    nonisolated static func readNow(database: MaerDatabase,
                                    table: KeyedRowStore<Value>.Table) throws -> KeyedRowStore<Value>.Load {
        let reader = try database.readerNow()
        return try reader.map { try KeyedRowStore<Value>.loadNow(table: table, reader: $0) }
            ?? KeyedRowStore<Value>.Load(rows: [:], skipped: 0)
    }

    /// A start read taken: the chain learns its base, the store gets the
    /// rows (nil when the table holds nothing or the read failed).
    func started(with read: Result<KeyedRowStore<Value>.Load, Error>) -> Rows? {
        switch read {
        case .success(let load):
            chain.started(rows: load.rows.isEmpty ? nil : load.rows, skipped: load.skipped)
            return load.rows.isEmpty ? nil : load.rows
        case .failure(let error):
            chain.startReadFailedAsAWhole(reason: String(describing: error))
            return nil
        }
    }

    /// After a start read that failed as a whole, the rows read again at
    /// once, beside the chain while no write is on its way (a hand-over that
    /// waits for them cannot wait for the next write, which would carry the
    /// new account's word into the old stock). Read rows go to the store by
    /// its adoption, as after a read on save. True when the rows are read.
    func readAgainNow() -> Bool {
        guard chain.startReadFailed else { return true }
        guard let adopt, chain.mayReadBesideTheChain else { return false }
        do {
            let reader = try database.readerNow()
            let load = try reader.map { try KeyedRowStore<Value>.loadNow(table: table, reader: $0) }
                ?? KeyedRowStore<Value>.Load(rows: [:], skipped: 0)
            chain.started(rows: load.rows.isEmpty ? nil : load.rows, skipped: load.skipped)
            if !load.rows.isEmpty { adopt(load.rows) }
            Logger.library.notice("\(self.label, privacy: .public) rows read again: rows=\(load.rows.count) skipped=\(load.skipped)")
            return true
        } catch {
            Logger.library.notice("\(self.label, privacy: .public) rows still not read reason=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The store's memory, taken by `take` when the write runs in the chain;
    /// the rows get the diff against the base (known rows, or the rows the
    /// start read that are gone). `emptying` says whether an empty snapshot
    /// is the action of this write, fixed at the call (`atCall`); when it is
    /// not, an empty snapshot that would remove rows is refused, and it
    /// speaks as `WipeRefusal` says. `take` answers nil once the store is gone.
    func write(emptying requested: RowEmptying, also: [SQLiteConnection.Statement] = [],
               _ take: @escaping @MainActor () -> Rows?) {
        let emptying = requested.atCall(memoryIsEmpty: take()?.isEmpty ?? true)
        chain.write(narrowing: requested == .allowed && emptying == .refused, read: { [weak self] in
            guard let self, let rows = await self.open() else { throw RowsNotOpen() }
            let load = try await rows.load()
            return (load.rows.isEmpty ? nil : load.rows, load.skipped)
        }, take: take, apply: { [weak self] snapshot, base, refusal in
            guard let self else { return .skipped }
            guard let rows = await self.open() else {
                Logger.library.error("\(self.label, privacy: .public) save held: the rows do not open now, the next write opens again")
                return .skipped
            }
            if base.refuses(snapshot, emptying) {
                let count = base.removable?.count ?? 0
                switch refusal {
                case .laterQueued:
                    Logger.library.notice("\(self.label, privacy: .public) wipe refused, a later write is queued: empty snapshot over \(count) rows")
                case .narrowedPermission:
                    Logger.library.notice("\(self.label, privacy: .public) wipe refused: a removal given while rows stood does not cover this empty snapshot over \(count) rows")
                case .suspected:
                    Logger.library.error("\(self.label, privacy: .public) wipe REFUSED: empty snapshot over \(count) rows plan=\(String(describing: base.plan), privacy: .public)")
                }
                return .refused(refusal)
            }
            let mark = self.mark?()
            // `also`: statements of the store that land in the same
            // transaction (rows carried as they are at a hand-over).
            let written = try await rows.apply(previous: base.previous(for: snapshot), current: snapshot,
                                               also: also + (mark?.statements ?? []))
            mark?.landed()
            if self.logsSaves, base.plan != .diff || written.upserted + written.removed > 0 {
                Logger.library.notice("\(self.label, privacy: .public) save: upserted=\(written.upserted) removed=\(written.removed) plan=\(String(describing: base.plan), privacy: .public)")
            }
            return .landed
        })
    }

    /// The rows could not be opened; a read after a failed start holds.
    private struct RowsNotOpen: Error {}

    /// The adoption most stores take: the rows read, with what this run holds
    /// over them, the run winning per key (it is the newer word). A key this
    /// run removed before the read comes back if the rows hold it: the union
    /// cannot tell a removal from a key the run never had. Before the read
    /// the run holds only what it added, so only a key it added and removed
    /// again that an unread row also holds is met.
    nonisolated static func union(read: Rows, run: Rows) -> Rows {
        read.merging(run) { _, fromRun in fromRun }
    }

    /// Waits for every queued write (tests, teardown).
    func awaitPendingWrites() async {
        await chain.awaitPendingWrites()
    }

    /// The rows, opened once; nil while they do not open. A failure at one
    /// moment (before the first unlock) is not one for the run: the next
    /// caller opens again instead of ending every write of the run.
    private func open() async -> KeyedRowStore<Value>? {
        if let opening, let opened = await opening.value { return opened }
        let task = Task<KeyedRowStore<Value>?, Never> { [database, table, label] in
            do {
                return try await KeyedRowStore<Value>(connection: try database.connection(), table: table)
            } catch {
                Logger.library.error("\(label, privacy: .public) rows open failed reason=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        opening = task
        return await task.value
    }
}

/// Every write chain into the rows that exists, so the app's two ends
/// (going to background, terminating) can wait for every chain with one
/// call before the database's checkpoint: each `RowChain` (under every
/// keeper, the podcast rows, the library rows) registers itself on
/// creation, the totals register their own chain (`ListeningStatsStore`),
/// and the chain of the stand rows is waited on by name (`StandMirror`,
/// nonisolated). Held weakly; the list
/// forgets what died.
@MainActor
enum RowKeepers {
    private struct Entry {
        weak var keeper: AnyObject?
        let settle: () async -> Void
    }
    private static var entries: [Entry] = []

    /// A write chain, waited on at the app's two ends.
    static func register(owner: AnyObject, settle: @escaping () async -> Void) {
        entries.removeAll { $0.keeper == nil }
        entries.append(Entry(keeper: owner, settle: settle))
    }

    /// The keepers alive right now, for the witness.
    static var count: Int {
        entries.filter { $0.keeper != nil }.count
    }

    /// Waits for every registered chain that lives, and the chain of the
    /// stand rows; returns how many registered
    /// chains were waited on.
    @discardableResult
    static func awaitAll() async -> Int {
        entries.removeAll { $0.keeper == nil }
        var waited = 0
        for entry in entries where entry.keeper != nil {
            await entry.settle()
            waited += 1
        }
        await StandMirror.shared.awaitPendingWrites()
        return waited
    }
}
