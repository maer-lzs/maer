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
        try Self.exec(opened, "PRAGMA journal_mode=WAL")
        try Self.exec(opened, "PRAGMA foreign_keys=ON")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Statements

    /// A statement without parameters (DDL, pragmas, small writes).
    func execute(_ sql: String) throws {
        guard let db else { throw SQLiteError.open("closed") }
        try Self.exec(db, sql)
    }

    /// A write with positional parameters (`?`). Returns the changed rows.
    @discardableResult
    func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        guard let db else { throw SQLiteError.open("closed") }
        let statement = try prepare(db, sql, params)
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
        let statement = try prepare(db, sql, params)
        defer { sqlite3_finalize(statement) }
        let columns = Int(sqlite3_column_count(statement))
        let names = (0..<columns).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [[String: SQLiteValue]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError.step(String(cString: sqlite3_errmsg(db)), sql: sql)
            }
            var row: [String: SQLiteValue] = [:]
            for column in 0..<columns {
                row[names[column]] = Self.value(statement, Int32(column))
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` inside one transaction; a thrown error rolls it back and
    /// is rethrown. The body runs on the actor, so it may call `run` and
    /// `query` synchronously through `self`.
    func transaction<T: Sendable>(_ body: @Sendable (isolated SQLiteConnection) throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body(self)
            try execute("COMMIT")
            return result
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

    // MARK: - Internals

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw SQLiteError.step(text, sql: sql)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)), sql: sql)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch param {
            case .null: rc = sqlite3_bind_null(prepared, index)
            case .integer(let v): rc = sqlite3_bind_int64(prepared, index, v)
            case .real(let v): rc = sqlite3_bind_double(prepared, index, v)
            case .text(let v): rc = sqlite3_bind_text(prepared, index, v, -1, transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(prepared, index, bytes.baseAddress, Int32(v.count), transient)
                }
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(prepared)
                throw SQLiteError.bind(index: offset + 1, sql: sql)
            }
        }
        return prepared
    }

    private static func value(_ statement: OpaquePointer, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }
}
