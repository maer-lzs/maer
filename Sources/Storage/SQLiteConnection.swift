// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import SQLite3

/// A value as SQLite carries it. The hull speaks this and nothing else.
nonisolated enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var int64: Int64? { if case .integer(let v) = self { return v } else { return nil } }
    var double: Double? {
        switch self {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }
    var string: String? { if case .text(let v) = self { return v } else { return nil } }
    var data: Data? { if case .blob(let v) = self { return v } else { return nil } }
}

nonisolated enum SQLiteError: Error, Equatable {
    case open(String)
    case prepare(String, sql: String)
    case bind(index: Int, sql: String)
    case step(String, sql: String)
}

/// The thin hull over the system's SQLite (Rule 4: no dependency). One
/// actor per database file: every statement runs serialized, prepared per
/// call, bound by position, read row by row. Errors are thrown, never
/// swallowed. WAL journal, foreign keys on. `userVersion` carries the
/// schema version for additive migrations.
actor SQLiteConnection {
    // nonisolated(unsafe): the handle is touched outside the actor only in
    // `deinit`, when no other reference to the connection exists any more.
    nonisolated(unsafe) private var db: OpaquePointer?
    let path: String

    /// Opens (creating) the database at `path`. `":memory:"` for tests.
    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open(message)
        }
        db = opened
        try SQLiteStatements.exec(opened, "PRAGMA journal_mode=WAL")
        try SQLiteStatements.exec(opened, "PRAGMA foreign_keys=ON")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Statements

    /// A statement without parameters (DDL, pragmas, small writes).
    func execute(_ sql: String) throws {
        guard let db else { throw SQLiteError.open("closed") }
        try SQLiteStatements.exec(db, sql)
    }

    /// A write with positional parameters (`?`). Returns the changed rows.
    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        guard let db else { throw SQLiteError.open("closed") }
        let statement = try SQLiteStatements.prepare(db, sql, params)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        return Int(sqlite3_changes(db))
    }

    /// A read with positional parameters. Rows as column name to value.
    func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        guard let db else { throw SQLiteError.open("closed") }
        return try SQLiteStatements.query(db, sql, params)
    }

    /// A statement with its bound parameters, for a batch.
    struct Statement: Sendable {
        let sql: String
        let params: [SQLiteValue]
        init(_ sql: String, _ params: [SQLiteValue] = []) {
            self.sql = sql
            self.params = params
        }
    }

    /// Runs the statements as ONE transaction, on the actor, with no
    /// suspension between them: several stores share this connection, and
    /// a transaction that awaited between its statements let another
    /// store's BEGIN land inside it (measured in the simulator: "cannot
    /// start a transaction within a transaction"). A thrown error rolls
    /// back and is rethrown. Returns the sum of changed rows.
    @discardableResult
    func transaction(_ statements: [Statement]) throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            var changed = 0
            for statement in statements {
                changed += try run(statement.sql, statement.params)
            }
            try execute("COMMIT")
            return changed
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// The schema version for additive migrations.
    var userVersion: Int {
        get throws {
            let rows = try query("PRAGMA user_version")
            return Int(rows.first?["user_version"]?.int64 ?? 0)
        }
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }
}
