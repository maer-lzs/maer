// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// One listening state as the row backend holds it: the same numbers the
/// defaults entry carries (`[position, updatedAtMs, duration?, form?]`, see
/// `ProgressMark.entry`), so the merge rules over `[Double]` stay untouched
/// and every entry reads back in exactly the shape it went in.
nonisolated struct Stand: Equatable, Sendable {
    var itemId: String
    var position: Double
    var updatedAtMs: Double
    var duration: Double?
    /// Slot 3, `ProgressMark.StartedForm.rawValue`. Kept as the raw number:
    /// the row backend carries the entry, it does not interpret it.
    var form: Double?

    /// The defaults shape, for every reader that still speaks it. A form
    /// needs slot 2 occupied, so it carries a 0 there when no duration is
    /// known, the same way `ProgressMark.entry` builds it.
    var entry: [Double] {
        if let form { return [position, updatedAtMs, duration ?? 0, form] }
        if let duration { return [position, updatedAtMs, duration] }
        return [position, updatedAtMs]
    }

    /// From the defaults shape; nil when the entry carries no moment.
    init?(itemId: String, entry: [Double]) {
        guard entry.count >= 2 else { return nil }
        self.itemId = itemId
        self.position = entry[0]
        self.updatedAtMs = entry[1]
        self.duration = entry.count > 2 ? entry[2] : nil
        self.form = entry.count > 3 ? entry[3] : nil
    }

    init(itemId: String, position: Double, updatedAtMs: Double, duration: Double?, form: Double? = nil) {
        self.itemId = itemId
        self.position = position
        self.updatedAtMs = updatedAtMs
        self.duration = duration
        self.form = form
    }
}

/// The `stand` table: one row per title, the record that Mär-Sync and
/// CloudKit carry as well. Writes are upserts, the import from the defaults
/// runs in one transaction and never shrinks a filled table to nothing.
actor StandStore {
    static let family = "stand"
    static let schemaVersion = 1

    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) async throws {
        self.connection = connection
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS stand (
                item_id TEXT PRIMARY KEY,
                position REAL NOT NULL,
                updated_at_ms REAL NOT NULL,
                duration REAL,
                started_form REAL
            )
            """)
        try await connection.execute("CREATE INDEX IF NOT EXISTS stand_updated ON stand(updated_at_ms)")
        // What this device last pushed, per title: the second family of the
        // stock, in a table of its own so the row the carriers know stays
        // as it is.
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS stand_flushed (
                item_id TEXT PRIMARY KEY,
                position REAL NOT NULL,
                flushed_at_ms REAL NOT NULL
            )
            """)
        if try await connection.schemaVersion(of: Self.family) < Self.schemaVersion {
            try await connection.setSchemaVersion(Self.schemaVersion, of: Self.family)
        }
    }

    func upsert(_ stand: Stand) async throws {
        try await connection.run("""
            INSERT INTO stand (item_id, position, updated_at_ms, duration, started_form) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET position = excluded.position,
                updated_at_ms = excluded.updated_at_ms, duration = excluded.duration,
                started_form = excluded.started_form
            """, [.text(stand.itemId), .real(stand.position), .real(stand.updatedAtMs),
                  stand.duration.map { .real($0) } ?? .null,
                          stand.form.map { .real($0) } ?? .null])
    }

    /// The travelling part of the rows made exactly `backups` and `flushed`
    /// (what `travels` names and they lack goes), with `also` in the same
    /// transaction: the replacement of the stock at a change of account and
    /// its mark (`OwnerMark`), landing together or not at all.
    func replaceTravelling(backups: [String: [Double]], flushed: [String: [Double]],
                           travels: @Sendable (String) -> Bool,
                           also: [SQLiteConnection.Statement]) async throws {
        let standIds = try await connection.query("SELECT item_id FROM stand").compactMap { $0["item_id"]?.string }
        let flushedIds = try await connection.query("SELECT item_id FROM stand_flushed").compactMap { $0["item_id"]?.string }
        var statements: [SQLiteConnection.Statement] = []
        for id in standIds where travels(id) && backups[id].flatMap({ Stand(itemId: id, entry: $0) }) == nil {
            statements.append(.init("DELETE FROM stand WHERE item_id = ?", [.text(id)]))
        }
        for (id, entry) in backups {
            guard let stand = Stand(itemId: id, entry: entry) else { continue }
            let duration: SQLiteValue = stand.duration.map { .real($0) } ?? .null
            let form: SQLiteValue = stand.form.map { .real($0) } ?? .null
            let values: [SQLiteValue] = [.text(stand.itemId), .real(stand.position), .real(stand.updatedAtMs),
                                         duration, form]
            statements.append(.init("""
                INSERT INTO stand (item_id, position, updated_at_ms, duration, started_form) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET position = excluded.position,
                    updated_at_ms = excluded.updated_at_ms, duration = excluded.duration,
                    started_form = excluded.started_form
                """, values))
        }
        for id in flushedIds where travels(id) && (flushed[id]?.count ?? 0) < 2 {
            statements.append(.init("DELETE FROM stand_flushed WHERE item_id = ?", [.text(id)]))
        }
        for (id, entry) in flushed where entry.count >= 2 {
            statements.append(.init("""
                INSERT INTO stand_flushed (item_id, position, flushed_at_ms) VALUES (?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET position = excluded.position, flushed_at_ms = excluded.flushed_at_ms
                """, [.text(id), .real(entry[0]), .real(entry[1])]))
        }
        _ = try await connection.transaction(statements + also)
    }

    /// One title's stand; a row that is there but does not read is said like
    /// in `all()`, and answers nil like a missing one.
    func stand(for itemId: String) async throws -> Stand? {
        guard let row = try await connection.query("SELECT item_id, position, updated_at_ms, duration, started_form FROM stand WHERE item_id = ?",
                                                   [.text(itemId)]).first else { return nil }
        let stand = Self.stand(from: row)
        Self.sayRowsSkipped(stand == nil ? 1 : 0, by: "one")
        return stand
    }

    func all() async throws -> [String: Stand] {
        var out: [String: Stand] = [:]
        var skipped = 0
        for row in try await connection.query("SELECT item_id, position, updated_at_ms, duration, started_form FROM stand") {
            if let stand = Self.stand(from: row) { out[stand.itemId] = stand } else { skipped += 1 }
        }
        Self.sayRowsSkipped(skipped, by: "all")
        return out
    }

    /// A row that does not read (SQLite keeps text in a `REAL` column, and a
    /// `TEXT` key may be NULL) is counted and said, never dropped silently;
    /// what is loaded stays the same.
    private nonisolated static func sayRowsSkipped(_ skipped: Int, by caller: String) {
        guard skipped > 0 else { return }
        Logger.library.error("STAND rows skipped=\(skipped) by=\(caller, privacy: .public)")
    }

    func count() async throws -> Int {
        Int(try await connection.query("SELECT count(*) AS n FROM stand").first?["n"]?.int64 ?? 0)
    }

    func remove(itemId: String) async throws {
        try await connection.run("DELETE FROM stand WHERE item_id = ?", [.text(itemId)])
    }

    /// The one-time import from the defaults entries, in one transaction.
    /// Idempotent (a second run upserts the same rows) and never a shrink:
    /// an empty import over a filled table changes nothing, and a row that
    /// already carries a newer moment is left alone.
    @discardableResult
    func importEntries(_ entries: [String: [Double]]) async throws -> Int {
        let stands = entries.compactMap { Stand(itemId: $0.key, entry: $0.value) }
        guard !stands.isEmpty else {
            let kept = try await count()
            Logger.library.notice("STAND import: nothing to import, table kept (\(kept) rows)")
            return 0
        }
        // One transaction on the connection actor, without a suspension
        // inside it (the other stores share the connection).
        let statements = stands.map { stand in
            SQLiteConnection.Statement("""
                INSERT INTO stand (item_id, position, updated_at_ms, duration, started_form) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET position = excluded.position,
                    updated_at_ms = excluded.updated_at_ms, duration = excluded.duration,
                    started_form = excluded.started_form
                WHERE excluded.updated_at_ms > stand.updated_at_ms
                """, [.text(stand.itemId), .real(stand.position), .real(stand.updatedAtMs),
                      stand.duration.map { .real($0) } ?? .null,
                      stand.form.map { .real($0) } ?? .null])
        }
        let imported = try await connection.transaction(statements)
        Logger.library.notice("STAND import: offered=\(stands.count) written=\(imported)")
        return imported
    }

    /// Both tables read synchronously, in the shape the store holds: for the
    /// start, whose readers ask without an await. EMPTY when the tables do
    /// not exist yet; THROWS when the read fails, so "nothing there" and
    /// "could not read" never look the same.
    nonisolated static func loadNow(reader: SQLiteReader) throws -> ListeningStore.Stock {
        var stock = ListeningStore.Stock()
        let tables = Set(try reader.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0["name"]?.string })
        if tables.contains("stand") {
            for row in try reader.query("SELECT item_id, position, updated_at_ms, duration, started_form FROM stand") {
                if let stand = stand(from: row) { stock.backups[stand.itemId] = stand.entry } else { stock.skippedRows += 1 }
            }
        }
        if tables.contains("stand_flushed") {
            for row in try reader.query("SELECT item_id, position, flushed_at_ms FROM stand_flushed") {
                if let id = row["item_id"]?.string, let position = row["position"]?.double,
                   let at = row["flushed_at_ms"]?.double {
                    stock.flushed[id] = [position, at]
                } else {
                    stock.skippedRows += 1
                }
            }
        }
        sayRowsSkipped(stock.skippedRows, by: "start")
        return stock
    }

    /// Removes every row whose title the stock no longer holds, in one
    /// transaction: a removal the chain had not written yet when the app
    /// ended. Returns how many went.
    @discardableResult
    func retainOnly(_ itemIds: Set<String>) async throws -> Int {
        let gone = try await all().keys.filter { !itemIds.contains($0) }
        guard !gone.isEmpty else { return 0 }
        let statements = gone.map { SQLiteConnection.Statement("DELETE FROM stand WHERE item_id = ?", [.text($0)]) }
        return try await connection.transaction(statements)
    }

    // MARK: - What this device last pushed

    func upsertFlushed(itemId: String, entry: [Double]) async throws {
        guard entry.count >= 2 else { return }
        try await connection.run("""
            INSERT INTO stand_flushed (item_id, position, flushed_at_ms) VALUES (?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET position = excluded.position, flushed_at_ms = excluded.flushed_at_ms
            """, [.text(itemId), .real(entry[0]), .real(entry[1])])
    }

    func removeFlushed(itemId: String) async throws {
        try await connection.run("DELETE FROM stand_flushed WHERE item_id = ?", [.text(itemId)])
    }

    func allFlushed() async throws -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for row in try await connection.query("SELECT item_id, position, flushed_at_ms FROM stand_flushed") {
            if let id = row["item_id"]?.string, let position = row["position"]?.double,
               let at = row["flushed_at_ms"]?.double {
                out[id] = [position, at]
            }
        }
        return out
    }

    /// Brings the flushed table to exactly the stock's entries, in one
    /// transaction. Returns written and removed rows.
    @discardableResult
    func replaceFlushed(with entries: [String: [Double]]) async throws -> (written: Int, removed: Int) {
        let held = try await allFlushed()
        let gone = held.keys.filter { entries[$0] == nil }
        var statements = gone.map { SQLiteConnection.Statement("DELETE FROM stand_flushed WHERE item_id = ?", [.text($0)]) }
        let changed = entries.filter { $0.value.count >= 2 && held[$0.key] != Array($0.value.prefix(2)) }
        statements += changed.map { entry in
            SQLiteConnection.Statement("""
                INSERT INTO stand_flushed (item_id, position, flushed_at_ms) VALUES (?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET position = excluded.position, flushed_at_ms = excluded.flushed_at_ms
                """, [.text(entry.key), .real(entry.value[0]), .real(entry.value[1])])
        }
        guard !statements.isEmpty else { return (0, 0) }
        _ = try await connection.transaction(statements)
        return (changed.count, gone.count)
    }

    /// Nil for a row that does not read; every caller counts it and says it
    /// through `sayRowsSkipped`.
    private nonisolated static func stand(from row: [String: SQLiteValue]) -> Stand? {
        guard let id = row["item_id"]?.string, let position = row["position"]?.double,
              let updated = row["updated_at_ms"]?.double else { return nil }
        return Stand(itemId: id, position: position, updatedAtMs: updated,
                     duration: row["duration"]?.double, form: row["started_form"]?.double)
    }
}
