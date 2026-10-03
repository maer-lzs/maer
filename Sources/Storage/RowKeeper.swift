// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Keeps a store's rows in one table: the start read and the serial write
/// chain that writes the diff against the last landed state. The store
/// keeps its rule and its memory; the keeper keeps the rows, so the start
/// read and the write chain are written once for every store.
///
/// A missing file is a fresh install and a missing table is empty, both
/// leave a fresh base. A failed read leaves the base unknown; the store
/// starts empty, and the first write only upserts, removing nothing it
/// never saw. After the first landed write the base is known and later removals
/// apply. A failed write is logged and leaves the base where it was, so
/// the next write diffs against what really landed.
@MainActor
final class RowKeeper<Value: Codable & Equatable & Sendable> {
    typealias Rows = [String: Value]

    private let database: MaerDatabase
    private let table: KeyedRowStore<Value>.Table
    /// The log prefix of the store, so a line names its owner.
    private let label: String
    /// What the rows hold, as far as this run knows: the last LANDED write
    /// or the start read.
    private(set) var base: RowBase<Rows> = .fresh
    /// The one opening of the rows: every caller awaits the same task.
    private var opening: Task<KeyedRowStore<Value>?, Never>?
    /// The last handed-over write; each write waits for the one before it.
    private var pendingWrite: Task<Void, Never>?

    init(database: MaerDatabase, table: KeyedRowStore<Value>.Table, label: String) {
        self.database = database
        self.table = table
        self.label = label
        RowKeepers.register(self)
    }

    /// The synchronous start read, once, before the store sets its memory:
    /// the rows, or nil when the table holds nothing or the read failed.
    /// Rows that are there but do not decode leave the base unknown, and
    /// the store gets what did decode.
    func startNow() -> Rows? {
        do {
            let reader = try database.readerNow()
            let load = try reader.map { try KeyedRowStore<Value>.loadNow(table: table, reader: $0) }
                ?? KeyedRowStore<Value>.Load(rows: [:], skipped: 0)
            guard !load.rows.isEmpty || load.skipped > 0 else {
                base = .fresh
                return nil
            }
            base = RowBase.afterLoad(rows: load.rows.isEmpty ? nil : load.rows, skipped: load.skipped)
            return load.rows
        } catch {
            base = .unknown
            Logger.library.error("\(self.label, privacy: .public) rows read failed reason=\(String(describing: error), privacy: .public) base=unknown")
            return nil
        }
    }

    /// The whole snapshot; the rows get the diff against the base. A write
    /// that matches the base is skipped by the store.
    func write(_ snapshot: Rows) {
        chain(what: "save", priority: .utility) { rows in
            // The base is read HERE, after the write before landed or failed.
            let base = self.base
            switch base.plan {
            case .diff:
                _ = try await rows.apply(previous: base.knownValue ?? [:], current: snapshot)
            case .upsertOnly:
                _ = try await rows.apply(previous: [:], current: snapshot)
            }
            self.base = .known(snapshot)
        }
    }

    /// Waits for every queued write (tests, teardown).
    func awaitPendingWrites() async {
        await pendingWrite?.value
    }

    private func chain(what: String, priority: TaskPriority?,
                       _ body: @escaping @MainActor (KeyedRowStore<Value>) async throws -> Void) {
        let previous = pendingWrite
        pendingWrite = Task(priority: priority) { [weak self] in
            await previous?.value
            guard let self, let rows = await self.open() else { return }
            do {
                try await body(rows)
            } catch {
                Logger.library.error("\(self.label, privacy: .public) \(what, privacy: .public) failed reason=\(String(describing: error), privacy: .public) base kept")
            }
        }
    }

    private func open() async -> KeyedRowStore<Value>? {
        if let opening { return await opening.value }
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

/// Every keeper that exists, so the app's two ends (going to background,
/// terminating) can wait for every chain with one call before the
/// database's checkpoint. A keeper registers itself on creation and is
/// held weakly; the list forgets what died.
@MainActor
enum RowKeepers {
    private struct Entry {
        weak var keeper: AnyObject?
        let settle: () async -> Void
    }
    private static var entries: [Entry] = []

    static func register<Value>(_ keeper: RowKeeper<Value>) {
        entries.removeAll { $0.keeper == nil }
        entries.append(Entry(keeper: keeper, settle: { [weak keeper] in await keeper?.awaitPendingWrites() }))
    }

    /// The keepers alive right now, for the witness.
    static var count: Int {
        entries.filter { $0.keeper != nil }.count
    }

    /// Waits for every living keeper's chain, and the listening stock's row
    /// chain, which lives in the rows as well; returns how many keepers were
    /// waited on.
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
