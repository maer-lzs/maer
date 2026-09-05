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

    func stand(for itemId: String) async throws -> Stand? {
        try await connection.query("SELECT item_id, position, updated_at_ms, duration, started_form FROM stand WHERE item_id = ?",
                                   [.text(itemId)]).first.flatMap(Self.stand(from:))
    }

    func all() async throws -> [String: Stand] {
        var out: [String: Stand] = [:]
        for row in try await connection.query("SELECT item_id, position, updated_at_ms, duration, started_form FROM stand") {
            if let stand = Self.stand(from: row) { out[stand.itemId] = stand }
        }
        return out
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
        // One transaction, statement by statement on the connection actor
        // (the closure form of `transaction` trips the isolation checker on
        // a capture-and-return loop; the explicit form is the same thing).
        try await connection.execute("BEGIN IMMEDIATE")
        var imported = 0
        do {
            for stand in stands {
                imported += try await connection.run("""
                    INSERT INTO stand (item_id, position, updated_at_ms, duration, started_form) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(item_id) DO UPDATE SET position = excluded.position,
                        updated_at_ms = excluded.updated_at_ms, duration = excluded.duration,
                        started_form = excluded.started_form
                    WHERE excluded.updated_at_ms > stand.updated_at_ms
                    """, [.text(stand.itemId), .real(stand.position), .real(stand.updatedAtMs),
                          stand.duration.map { .real($0) } ?? .null,
                          stand.form.map { .real($0) } ?? .null])
            }
            try await connection.execute("COMMIT")
        } catch {
            try? await connection.execute("ROLLBACK")
            throw error
        }
        Logger.library.notice("STAND import: offered=\(stands.count) written=\(imported)")
        return imported
    }

    private static func stand(from row: [String: SQLiteValue]) -> Stand? {
        guard let id = row["item_id"]?.string, let position = row["position"]?.double,
              let updated = row["updated_at_ms"]?.double else { return nil }
        return Stand(itemId: id, position: position, updatedAtMs: updated,
                     duration: row["duration"]?.double, form: row["started_form"]?.double)
    }
}
