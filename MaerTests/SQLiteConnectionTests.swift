// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The hull's promises: statements bind by position and read every value
/// type back, a failed transaction leaves nothing behind, errors throw
/// with the statement named, and the schema version is a pragma.
struct SQLiteConnectionTests {
    @Test("Anlegen, schreiben, lesen: jeder Werttyp kommt zurueck, wie er hineinging")
    func roundTrip() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, payload BLOB, note TEXT)")
        let blob = Data([1, 2, 3, 250])
        try await db.run("INSERT INTO t (id, name, score, payload, note) VALUES (?, ?, ?, ?, ?)",
                         [.integer(7), .text("sieben"), .real(7.5), .blob(blob), .null])
        let rows = try await db.query("SELECT id, name, score, payload, note FROM t WHERE id = ?", [.integer(7)])
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .integer(7))
        #expect(rows[0]["name"] == .text("sieben"))
        #expect(rows[0]["score"] == .real(7.5))
        #expect(rows[0]["payload"] == .blob(blob))
        #expect(rows[0]["note"] == .null)
        let changed = try await db.run("UPDATE t SET name = ? WHERE id = ?", [.text("acht"), .integer(7)])
        #expect(changed == 1)
    }

    @Test("Eine Transaktion, die wirft, laesst nichts zurueck; eine gute alles")
    func transactionRollsBack() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        struct Stop: Error {}
        var threw = false
        do {
            try await db.transaction { conn in
                try conn.run("INSERT INTO t (id) VALUES (1)")
                try conn.run("INSERT INTO t (id) VALUES (2)")
                throw Stop()
            }
        } catch is Stop {
            threw = true
        }
        #expect(threw)
        #expect(try await db.query("SELECT count(*) AS n FROM t").first?["n"] == .integer(0))
        try await db.transaction { conn in
            try conn.run("INSERT INTO t (id) VALUES (1)")
            try conn.run("INSERT INTO t (id) VALUES (2)")
        }
        #expect(try await db.query("SELECT count(*) AS n FROM t").first?["n"] == .integer(2))
    }

    @Test("Fehler nennen die Anweisung; die Schema-Version ist ein Pragma und bleibt in der Datei")
    func errorsNameTheStatementAndVersionPersists() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        do {
            try await db.execute("SELEKT nonsense")
            Issue.record("a broken statement must throw")
        } catch let error as SQLiteError {
            if case .step(_, let sql) = error { #expect(sql == "SELEKT nonsense") } else { Issue.record("wrong error \(error)") }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hull-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: file) }
        do {
            let first = try SQLiteConnection(path: file)
            #expect(try await first.userVersion == 0)
            try await first.setUserVersion(3)
            try await first.execute("CREATE TABLE stand (item_id TEXT PRIMARY KEY, position REAL NOT NULL)")
            try await first.run("INSERT INTO stand VALUES (?, ?)", [.text("rss:x"), .real(600)])
        }
        let second = try SQLiteConnection(path: file)
        #expect(try await second.userVersion == 3)
        #expect(try await second.query("SELECT position FROM stand WHERE item_id = ?", [.text("rss:x")]).first?["position"] == .real(600))
    }
}
#endif
