// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The catalogue rows the app showed last, so a start shows them before any
/// fetch and without a network, and a source that fails leaves its row
/// standing. Fetchable again at any time, so the file lives in a folder of
/// its own, kept out of the device backup; the data of the person stays in
/// `maer.sqlite`. A row is replaced only whole, in one transaction.
/// Jamendo has no key: its terms forbid keeping its answers.
actor CatalogRowStore {
    static let family = "catalog"
    static let schemaVersion = 1

    enum Key: String, CaseIterable, Sendable {
        case booksDiscover = "books.discover", booksTab = "books.tab"
        case classical, netlabels, musopen
        case librivoxNew = "librivox.new", librivoxPopular = "librivox.popular"
        case archiveBooks = "archive.books", gutenberg, oldTimeRadio = "old.time.radio"
    }

    private let connection: SQLiteConnection

    init(connection: SQLiteConnection) async throws {
        self.connection = connection
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS catalog_row (
                reihe TEXT NOT NULL,
                ordnung INTEGER NOT NULL,
                id TEXT NOT NULL,
                inhalt BLOB NOT NULL,
                PRIMARY KEY (reihe, ordnung)
            )
            """)
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS catalog_reihe (
                reihe TEXT PRIMARY KEY,
                geholt REAL,
                fehler TEXT,
                fehler_am REAL
            )
            """)
        if try await connection.schemaVersion(of: Self.family) < Self.schemaVersion {
            try await connection.setSchemaVersion(Self.schemaVersion, of: Self.family)
        }
    }

    /// `Application Support/Catalog`, beside the folder of the person's data.
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Catalog", isDirectory: true)
    }

    /// Opens the store once; every later call gets the same one.
    static func open() async throws -> CatalogRowStore {
        try await Opened.shared.store()
    }

    static func open(file: URL) async throws -> CatalogRowStore {
        throw SQLiteError.open("not built")
    }

    /// The one open store of the app.
    private actor Opened {
        static let shared = Opened()
        private var opened: CatalogRowStore?

        func store() async throws -> CatalogRowStore {
            if let opened { return opened }
            guard let directory = CatalogRowStore.directory else { throw SQLiteError.open("no Application Support") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            BackupExclusion.mark(directory, label: "catalog rows")
            let store = try await CatalogRowStore(
                connection: SQLiteConnection(path: directory.appendingPathComponent("catalog.sqlite").path))
            opened = store
            return store
        }
    }

    /// Replaces the row whole: the old tiles go and the new ones come in
    /// one transaction, never a half row.
    func replace(_ key: Key, items: [LibraryItem], atMs: Double) async throws {
        let encoder = JSONEncoder()
        var statements = [SQLiteConnection.Statement("DELETE FROM catalog_row WHERE reihe = ?", [.text(key.rawValue)])]
        for (order, item) in items.enumerated() {
            statements.append(.init("INSERT INTO catalog_row (reihe, ordnung, id, inhalt) VALUES (?, ?, ?, ?)",
                                    [.text(key.rawValue), .integer(Int64(order)), .text(item.id),
                                     .blob(try encoder.encode(item))]))
        }
        statements.append(.init("""
            INSERT INTO catalog_reihe (reihe, geholt, fehler, fehler_am) VALUES (?, ?, NULL, NULL)
            ON CONFLICT(reihe) DO UPDATE SET geholt = excluded.geholt, fehler = NULL, fehler_am = NULL
            """, [.text(key.rawValue), .real(atMs)]))
        try await connection.transaction(statements)
    }

    /// Notes why the last fetch of a row failed; the row stays as it is.
    func noteFailure(_ key: Key, reason: String, atMs: Double) async throws {
        try await connection.run("""
            INSERT INTO catalog_reihe (reihe, geholt, fehler, fehler_am) VALUES (?, NULL, ?, ?)
            ON CONFLICT(reihe) DO UPDATE SET fehler = excluded.fehler, fehler_am = excluded.fehler_am
            """, [.text(key.rawValue), .text(reason), .real(atMs)])
    }

    /// Every kept row in its order. A tile that does not decode is left out
    /// and named in the log; the rest of its row stays.
    func rows() async throws -> [Key: [LibraryItem]] {
        let decoder = JSONDecoder()
        var rows: [Key: [LibraryItem]] = [:]
        for row in try await connection.query("SELECT reihe, id, inhalt FROM catalog_row ORDER BY reihe, ordnung") {
            guard let key = row["reihe"]?.string.flatMap(Key.init(rawValue:)), let data = row["inhalt"]?.data else { continue }
            do {
                rows[key, default: []].append(try decoder.decode(LibraryItem.self, from: data))
            } catch {
                Logger.library.error("CATALOG row \(key.rawValue, privacy: .public) tile unreadable: \(FailureReason.of(error), privacy: .public)")
            }
        }
        return rows
    }

    func failures() async throws -> [Key: String] {
        var failures: [Key: String] = [:]
        for row in try await connection.query("SELECT reihe, fehler FROM catalog_reihe WHERE fehler IS NOT NULL") {
            if let key = row["reihe"]?.string.flatMap(Key.init(rawValue:)), let reason = row["fehler"]?.string {
                failures[key] = reason
            }
        }
        return failures
    }
}
