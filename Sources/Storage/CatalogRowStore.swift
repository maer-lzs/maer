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
    /// 2: the index of the service (`catalog_index`, `catalog_quelle`)
    /// beside the rows of version 1, which stay as they are.
    static let schemaVersion = 2

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
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS catalog_index (
                quelle TEXT NOT NULL,
                id TEXT NOT NULL,
                zeile BLOB NOT NULL,
                PRIMARY KEY (quelle, id)
            )
            """)
        try await connection.execute("""
            CREATE TABLE IF NOT EXISTS catalog_quelle (
                quelle TEXT PRIMARY KEY,
                version INTEGER NOT NULL DEFAULT 0,
                etag TEXT,
                etag_adresse TEXT,
                gelesen_am REAL NOT NULL DEFAULT 0,
                nicht_vor REAL
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

    /// Opens the file and marks it for the backup. A file that is not a
    /// database throws; the rows are then empty until the next fetch.
    static func open(file: URL) async throws -> CatalogRowStore {
        let store = try await CatalogRowStore(connection: SQLiteConnection(path: file.path))
        BackupExclusion.mark(file, label: "catalog rows file")
        return store
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
            let store = try await CatalogRowStore.open(file: directory.appendingPathComponent("catalog.sqlite"))
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

    struct IndexState: Equatable, Sendable {
        let version: Int
        let etag: String?
        let etagAddress: String?
        let readAtMs: Double
        let notBeforeMs: Double?
    }

    /// What this device holds of the index of one source, nil before the
    /// first whole walk or read.
    func indexState(_ source: String) async throws -> IndexState? {
        guard let row = try await connection.query(
            "SELECT version, etag, etag_adresse, gelesen_am, nicht_vor FROM catalog_quelle WHERE quelle = ?",
            [.text(source)]).first else { return nil }
        return IndexState(version: Int(row["version"]?.int64 ?? 0), etag: row["etag"]?.string,
                          etagAddress: row["etag_adresse"]?.string, readAtMs: row["gelesen_am"]?.double ?? 0,
                          notBeforeMs: row["nicht_vor"]?.double)
    }

    /// The rows of one source as the service wrote them, by id.
    func indexRows(_ source: String) async throws -> [String: Data] {
        var rows: [String: Data] = [:]
        for row in try await connection.query("SELECT id, zeile FROM catalog_index WHERE quelle = ?", [.text(source)]) {
            if let id = row["id"]?.string, let data = row["zeile"]?.data { rows[id] = data }
        }
        return rows
    }

    /// The full state replaces the source whole, in one transaction.
    func takeFull(_ source: String, rows: [MaerSyncCatalogRow], version: Int, etag: String?, etagAddress: String?,
                  atMs: Double) async throws {
        var statements = [SQLiteConnection.Statement("DELETE FROM catalog_index WHERE quelle = ?", [.text(source)])]
        for row in rows where !row.deleted {
            statements.append(.init("INSERT OR REPLACE INTO catalog_index (quelle, id, zeile) VALUES (?, ?, ?)",
                                    [.text(source), .text(row.id), .blob(row.json)]))
        }
        statements.append(Self.stateStatement(source, version: version, etag: etag, etagAddress: etagAddress, atMs: atMs))
        try await connection.transaction(statements)
    }

    /// A delta changes and removes rows and moves the version, in one transaction.
    func takeDelta(_ source: String, rows: [MaerSyncCatalogRow], version: Int, etag: String?, etagAddress: String?,
                   atMs: Double) async throws {
        var statements: [SQLiteConnection.Statement] = []
        for row in rows {
            statements.append(row.deleted
                ? .init("DELETE FROM catalog_index WHERE quelle = ? AND id = ?", [.text(source), .text(row.id)])
                : .init("INSERT OR REPLACE INTO catalog_index (quelle, id, zeile) VALUES (?, ?, ?)",
                        [.text(source), .text(row.id), .blob(row.json)]))
        }
        statements.append(Self.stateStatement(source, version: version, etag: etag, etagAddress: etagAddress, atMs: atMs))
        try await connection.transaction(statements)
    }

    private static func stateStatement(_ source: String, version: Int, etag: String?, etagAddress: String?,
                                       atMs: Double) -> SQLiteConnection.Statement {
        .init("""
            INSERT INTO catalog_quelle (quelle, version, etag, etag_adresse, gelesen_am, nicht_vor) VALUES (?, ?, ?, ?, ?, NULL)
            ON CONFLICT(quelle) DO UPDATE SET version = excluded.version, etag = excluded.etag,
                etag_adresse = excluded.etag_adresse, gelesen_am = excluded.gelesen_am, nicht_vor = NULL
            """, [.text(source), .integer(Int64(version)), etag.map { .text($0) } ?? .null,
                  etagAddress.map { .text($0) } ?? .null, .real(atMs)])
    }

    /// When the source was last asked, whatever came, and when not before
    /// the next time; the version and the tag stay.
    func noteIndexRead(_ source: String, atMs: Double, notBeforeMs: Double?) async throws {
        try await connection.run("""
            INSERT INTO catalog_quelle (quelle, gelesen_am, nicht_vor) VALUES (?, ?, ?)
            ON CONFLICT(quelle) DO UPDATE SET gelesen_am = excluded.gelesen_am, nicht_vor = excluded.nicht_vor
            """, [.text(source), .real(atMs), notBeforeMs.map { .real($0) } ?? .null])
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
