// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// A dictionary as rows: one row per key, the value as JSON. The listen log
/// (guid to entry), the two statistics pots (day to seconds, item to
/// seconds) and the Mär playlists (list id to list) are this shape, so
/// they share the store instead of four copies of it. A write is the diff
/// between two dictionaries; the start reads the rows back, synchronously
/// through a reader when a store loads at init time.
actor KeyedRowStore<Value: Codable & Equatable & Sendable> {
    static var family: String { "keyed" }
    static var schemaVersion: Int { 1 }

    /// The tables this store may hold. Named here, not passed as free text,
    /// so a table name never comes from data.
    enum Table: String, Sendable {
        case listenLog = "listen_log"
        case statsDay = "stats_day"
        case statsItem = "stats_item"
        case maerPlaylist = "maer_playlist"
        case playQueue = "play_queue"
        case playbackContext = "playback_context"
    }

    private let connection: SQLiteConnection
    let table: Table

    init(connection: SQLiteConnection, table: Table) async throws {
        self.connection = connection
        self.table = table
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS \(table.rawValue) (
                key TEXT PRIMARY KEY,
                payload BLOB NOT NULL
            )
            """)
        if try await connection.schemaVersion(of: Self.family) < Self.schemaVersion {
            try await connection.setSchemaVersion(Self.schemaVersion, of: Self.family)
        }
    }

    func count() async throws -> Int {
        Int(try await connection.query("SELECT count(*) AS n FROM \(table.rawValue)").first?["n"]?.int64 ?? 0)
    }

    /// What a load found: the rows that decoded, and how many did not.
    struct Load: Sendable {
        let rows: [String: Value]
        let skipped: Int
    }

    /// The whole table; nil when it holds no rows. An unreadable row is
    /// skipped and counted.
    func loadAll() async throws -> [String: Value]? {
        let load = Self.decode(try await connection.query("SELECT key, payload FROM \(table.rawValue)"), table: table)
        return load.rows.isEmpty ? nil : load.rows
    }

    /// The same read at init time, through a reader of its own, for the
    /// stores whose load is synchronous by contract. EMPTY when the table
    /// does not exist yet or holds no rows; THROWS when the read fails, so
    /// "nothing there" and "could not read" never look the same (a failed
    /// read must never end in a whole replace of rows nobody saw).
    nonisolated static func loadNow(table: Table, reader: SQLiteReader) throws -> Load {
        let exists = try reader.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                                      [.text(table.rawValue)])
        guard !exists.isEmpty else { return Load(rows: [:], skipped: 0) }
        return decode(try reader.query("SELECT key, payload FROM \(table.rawValue)"), table: table)
    }

    private nonisolated static func decode(_ rows: [[String: SQLiteValue]], table: Table) -> Load {
        let decoder = JSONDecoder()
        var out: [String: Value] = [:]
        var skipped = 0
        for row in rows {
            guard let key = row["key"]?.string, let data = row["payload"]?.data,
                  let value = try? decoder.decode(Value.self, from: data) else {
                skipped += 1
                continue
            }
            out[key] = value
        }
        if skipped > 0 {
            Logger.library.error("KEYEDROWS load \(table.rawValue, privacy: .public): \(skipped) rows undecodable, skipped")
        }
        return Load(rows: out, skipped: skipped)
    }

    /// Replaces the table with the dictionary, in one transaction.
    @discardableResult
    func replaceAll(_ values: [String: Value]) async throws -> Int {
        let statements = [SQLiteConnection.Statement("DELETE FROM \(table.rawValue)")]
            + (try Self.statements(table: table, upserted: values, removed: []))
        try await connection.transaction(statements)
        return values.count
    }

    /// Writes what changed from `previous` to `current`, in one
    /// transaction. Returns the upserted and removed counts.
    @discardableResult
    func apply(previous: [String: Value], current: [String: Value]) async throws -> (upserted: Int, removed: Int) {
        let diff = KeyedRowDiff.compute(previous: previous, current: current)
        guard !diff.isEmpty else { return (0, 0) }
        try await connection.transaction(try Self.statements(table: table, upserted: diff.upserted, removed: diff.removed))
        return (diff.upserted.count, diff.removed.count)
    }

    /// The statements of a write, encoded up front so the transaction on
    /// the connection runs without a suspension.
    private nonisolated static func statements(table: Table, upserted: [String: Value],
                                               removed: [String]) throws -> [SQLiteConnection.Statement] {
        let encoder = JSONEncoder()
        var out: [SQLiteConnection.Statement] = []
        for key in removed {
            out.append(.init("DELETE FROM \(table.rawValue) WHERE key = ?", [.text(key)]))
        }
        for (key, value) in upserted {
            out.append(.init("""
                INSERT INTO \(table.rawValue) (key, payload) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET payload = excluded.payload
                """, [.text(key), .blob(try encoder.encode(value))]))
        }
        return out
    }
}

/// The diff of two dictionaries: keys whose value is new or changed, and
/// keys that are gone. Pure.
nonisolated enum KeyedRowDiff {
    struct Result<Value: Equatable & Sendable>: Sendable {
        var upserted: [String: Value]
        var removed: [String]
        var isEmpty: Bool { upserted.isEmpty && removed.isEmpty }
    }

    static func compute<Value: Equatable & Sendable>(previous: [String: Value],
                                                    current: [String: Value]) -> Result<Value> {
        var upserted: [String: Value] = [:]
        for (key, value) in current where previous[key] != value {
            upserted[key] = value
        }
        let removed = previous.keys.filter { current[$0] == nil }.sorted()
        return Result(upserted: upserted, removed: removed)
    }
}
