// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import SQLite3

/// The statement mechanics both connections share: the actor that writes
/// and the reader that serves an init-time load. Prepared per call, bound
/// by position, read row by row; errors throw with the statement named.
nonisolated enum SQLiteStatements {
    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw SQLiteError.step(text, sql: sql)
        }
    }

    static func prepare(_ db: OpaquePointer, _ sql: String, _ params: [SQLiteValue]) throws -> OpaquePointer {
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

    /// A read with positional parameters. Rows as column name to value.
    static func query(_ db: OpaquePointer, _ sql: String, _ params: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
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
                row[names[column]] = value(statement, Int32(column))
            }
            rows.append(row)
        }
        return rows
    }

    static func value(_ statement: OpaquePointer, _ column: Int32) -> SQLiteValue {
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
