// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The library cache as rows: one row per item in list order, one row per
/// progress entry. A refresh writes the rows it changed (`LibraryRowDiff`),
/// never the whole cache; the cold start reads the rows back. Each row
/// carries its record as JSON, like the podcast rows.
actor LibraryRowStore {
    static let family = "library"
    static let schemaVersion = 1

    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) async throws {
        self.connection = connection
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS library_item (
                id TEXT PRIMARY KEY,
                position INTEGER NOT NULL,
                payload BLOB NOT NULL
            )
            """)
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS book_progress (
                item_id TEXT PRIMARY KEY,
                payload BLOB NOT NULL
            )
            """)
        if try await connection.schemaVersion(of: Self.family) < Self.schemaVersion {
            try await connection.setSchemaVersion(Self.schemaVersion, of: Self.family)
        }
    }

    struct Counts: Equatable, Sendable {
        var items: Int
        var progress: Int
    }

    func counts() async throws -> Counts {
        let items = Int(try await connection.query("SELECT count(*) AS n FROM library_item").first?["n"]?.int64 ?? 0)
        let progress = Int(try await connection.query("SELECT count(*) AS n FROM book_progress").first?["n"]?.int64 ?? 0)
        return Counts(items: items, progress: progress)
    }

    /// The cache as the rows hold it; nil when the rows hold nothing, so a
    /// caller can tell "no cache yet" from "an empty library". A row that
    /// does not decode is skipped and counted.
    func loadAll() async throws -> LibraryDiskCache? {
        try await loadAllCounted().cache
    }

    /// The same load, with the count of rows that did not decode: a store
    /// that finds skipped rows treats its rows as unknown, never as empty.
    func loadAllCounted() async throws -> (cache: LibraryDiskCache?, skipped: Int) {
        let decoder = JSONDecoder()
        var items: [LibraryItem] = []
        var progress: [String: BookProgress] = [:]
        var skipped = 0
        for row in try await connection.query("SELECT payload FROM library_item ORDER BY position") {
            guard let data = row["payload"]?.data, let item = try? decoder.decode(LibraryItem.self, from: data) else {
                skipped += 1
                continue
            }
            items.append(item)
        }
        for row in try await connection.query("SELECT item_id, payload FROM book_progress") {
            guard let id = row["item_id"]?.string, let data = row["payload"]?.data,
                  let entry = try? decoder.decode(BookProgress.self, from: data) else {
                skipped += 1
                continue
            }
            progress[id] = entry
        }
        if skipped > 0 {
            Logger.library.error("LIBROWS load: \(skipped) rows undecodable, skipped")
        }
        guard !items.isEmpty || !progress.isEmpty else { return (nil, skipped) }
        return (LibraryDiskCache(items: items, progress: progress), skipped)
    }

    /// Applies a diff in one transaction.
    @discardableResult
    func apply(_ diff: LibraryRowDiff) async throws -> Counts {
        guard !diff.isEmpty else { return Counts(items: 0, progress: 0) }
        try await connection.transaction(try Self.statements(diff))
        return Counts(items: diff.itemsUpserted.count, progress: diff.progressUpserted.count)
    }

    /// The statements of a diff, encoded up front so the transaction on
    /// the connection runs without a suspension.
    private nonisolated static func statements(_ diff: LibraryRowDiff) throws -> [SQLiteConnection.Statement] {
        let encoder = JSONEncoder()
        var out: [SQLiteConnection.Statement] = []
        for id in diff.itemsRemoved {
            out.append(.init("DELETE FROM library_item WHERE id = ?", [.text(id)]))
        }
        for id in diff.progressRemoved {
            out.append(.init("DELETE FROM book_progress WHERE item_id = ?", [.text(id)]))
        }
        for row in diff.itemsUpserted {
            out.append(.init("""
                INSERT INTO library_item (id, position, payload) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET position = excluded.position, payload = excluded.payload
                """, [.text(row.item.id), .integer(Int64(row.position)), .blob(try encoder.encode(row.item))]))
        }
        for row in diff.progressUpserted {
            out.append(.init("""
                INSERT INTO book_progress (item_id, payload) VALUES (?, ?)
                ON CONFLICT(item_id) DO UPDATE SET payload = excluded.payload
                """, [.text(row.itemId), .blob(try encoder.encode(row.progress))]))
        }
        return out
    }
}
