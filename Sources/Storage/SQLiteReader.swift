// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import SQLite3

/// A synchronous, read-only connection of its own, for the one moment the
/// actor cannot serve: the init-time load of a store whose load is
/// synchronous by contract (`Ablage.loadNow` has the same reason to exist).
/// WAL lets it read beside the writer. Opened for the read, closed when it
/// goes away; never used for a write.
nonisolated final class SQLiteReader {
    private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open(message)
        }
        db = opened
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        guard let db else { throw SQLiteError.open("closed") }
        return try SQLiteStatements.query(db, sql, params)
    }
}
