// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import SQLite3

/// A synchronous connection of its own that only reads, for the one moment the
/// actor cannot serve: the init-time load of a store whose load is
/// synchronous by contract (`Ablage.loadNow` has the same reason to exist).
/// WAL lets it read beside the writer. Opened for the read, closed when it
/// goes away; never used for a write.
nonisolated final class SQLiteReader {
    private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        // Read-write, never CREATE, and never a write: a read-only handle
        // on a WAL database cannot create the `-shm` file, and before the
        // first write (or after a clean close) it is not there, so the
        // first statement failed with "unable to open database file"
        // (measured in the simulator on every fresh start). The handle
        // only ever runs SELECT; the writer is the one place that writes.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
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
