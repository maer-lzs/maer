// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Keeps a store's rows in one table: the start read, the one-time pour of
/// the document of the builds before, and the serial write chain that
/// writes the diff against the last landed state. The store keeps its rule
/// and its memory; the keeper keeps the rows, so the start read and the
/// write chain are written once for every store that moved a document.
///
/// The rows first: a missing file is a fresh install and a missing table is
/// empty, both leave a fresh base. A failed read leaves the base unknown;
/// the store then falls back to the document it set aside and pours
/// nothing, and the first write only upserts, removing nothing it never
/// saw. After the first landed write the base is known and later removals
/// apply. A failed write is logged and leaves the base where it was, so
/// the next write diffs against what really landed.
@MainActor
final class RowKeeper<Value: Codable & Equatable & Sendable> {
    typealias Rows = [String: Value]

    /// What the start read found: the rows, or nil when the table holds
    /// nothing; `failed` when the read itself failed.
    struct Start {
        let rows: Rows?
        let failed: Bool
    }

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
    }

    /// The synchronous start read, once, before the store sets its memory.
    /// Rows that are there but do not decode leave the base unknown, and
    /// the store gets what did decode (never nil, so no document is poured
    /// over rows it could not read).
    func startNow() -> Start {
        do {
            let reader = try database.readerNow()
            let load = try reader.map { try KeyedRowStore<Value>.loadNow(table: table, reader: $0) }
                ?? KeyedRowStore<Value>.Load(rows: [:], skipped: 0)
            guard !load.rows.isEmpty || load.skipped > 0 else {
                base = .fresh
                return Start(rows: nil, failed: false)
            }
            base = RowBase.afterLoad(rows: load.rows.isEmpty ? nil : load.rows, skipped: load.skipped)
            return Start(rows: load.rows, failed: false)
        } catch {
            base = .unknown
            Logger.library.error("\(self.label, privacy: .public) rows read failed reason=\(String(describing: error), privacy: .public) fallback=migrated")
            return Start(rows: nil, failed: true)
        }
    }

    /// The documents into the rows, whole, then each set aside as
    /// `.migrated` (excluded from the backup; removed by the release after
    /// next).
    func pour(_ stock: Rows, settingAside documents: [URL]) {
        chain(what: "migrate") { rows in
            _ = try await rows.replaceAll(stock)
            for document in documents { try DocumentMigration.setAside(document) }
            self.base = .known(stock)
            Logger.library.notice("\(self.label, privacy: .public) migrate: rows=\(stock.count) documents=\(documents.map(\.lastPathComponent).joined(separator: ","), privacy: .public)")
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

    private func chain(what: String, priority: TaskPriority? = nil,
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
