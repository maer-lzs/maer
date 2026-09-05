// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

/// The one database file of the app and the one connection to it. Every
/// row store (stands, subscriptions) speaks through this connection, so the
/// statements of all of them serialize on one actor and one WAL.
nonisolated final class MaerDatabase: Sendable {
    static let shared = MaerDatabase()

    /// Application Support, beside the listen log.
    static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("maer.sqlite")
    }

    private let connectionState = Mutex<SQLiteConnection?>(nil)
    private let path: String?

    init() { path = nil }

    /// A database at a given path, for witnesses (`":memory:"`).
    init(path: String) { self.path = path }

    /// Whether a connection was opened in this run (a checkpoint has
    /// nothing to do before the first open).
    var isOpen: Bool { connectionState.withLock { $0 != nil } }

    /// The journal written back into the file, on the way to the
    /// background and at termination: `DB checkpoint ms= pages=`.
    func checkpoint() async {
        guard isOpen else { return }
        let started = Date()
        do {
            let done = try await connection().checkpoint()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Logger.library.notice("DB checkpoint ms=\(ms) pages=\(done.framesCheckpointed)/\(done.framesInLog) busy=\(done.busy)")
        } catch {
            Logger.library.error("DB checkpoint failed reason=\(String(describing: error), privacy: .public)")
        }
    }

    /// Opens on first use, once. Throws when the file cannot be opened; the
    /// caller decides what that means for it.
    func connection() throws -> SQLiteConnection {
        try connectionState.withLock { state in
            if let open = state { return open }
            let target: String
            if let path {
                target = path
            } else {
                guard let url = Self.url else { throw SQLiteError.open("no Application Support") }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                target = url.path
            }
            let opened = try SQLiteConnection(path: target)
            state = opened
            return opened
        }
    }

    /// A synchronous, read-only reader of its own on the same file, for
    /// the init-time load of a store whose load is synchronous by contract.
    /// Opens the writer first so the file and its schema exist. Not for a
    /// memory database: that has no file a second connection could share.
    /// Nil while the file holds nothing yet: opening the writer creates an
    /// EMPTY file, the first write fills it, and a read-only reader on an
    /// empty file fails at its first statement. That is not a failed read
    /// but a fresh install (measured in the simulator: the first start
    /// reported "unable to open database file" for every store).
    func readerNow() throws -> SQLiteReader? {
        let writer = try connection()
        guard writer.path != ":memory:" else { throw SQLiteError.open("a memory database has no reader") }
        let size = (try? FileManager.default.attributesOfItem(atPath: writer.path)[.size] as? Int) ?? 0
        guard size > 0 else { return nil }
        return try SQLiteReader(path: writer.path)
    }
}

extension SQLiteConnection {
    /// One version per table family, in a table of its own: `user_version`
    /// is one number per file, and this file carries several families.
    func schemaVersion(of family: String) throws -> Int {
        try execute("CREATE TABLE IF NOT EXISTS schema (family TEXT PRIMARY KEY, version INTEGER NOT NULL)")
        return Int(try query("SELECT version FROM schema WHERE family = ?", [.text(family)])
            .first?["version"]?.int64 ?? 0)
    }

    func setSchemaVersion(_ version: Int, of family: String) throws {
        try execute("CREATE TABLE IF NOT EXISTS schema (family TEXT PRIMARY KEY, version INTEGER NOT NULL)")
        try run("INSERT INTO schema (family, version) VALUES (?, ?) ON CONFLICT(family) DO UPDATE SET version = excluded.version",
                [.text(family), .integer(Int64(version))])
    }
}
