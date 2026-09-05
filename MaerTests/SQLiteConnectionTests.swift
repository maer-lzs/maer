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

    /// The ONE form of a transaction: a batch of statements, run on the
    /// actor without a suspension inside. A statement that fails rolls the
    /// batch back.
    @Test("Eine Transaktion, die scheitert, laesst nichts zurueck; eine gute alles")
    func transactionRollsBack() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        var threw = false
        do {
            try await db.transaction([.init("INSERT INTO t (id) VALUES (1)"),
                                      .init("INSERT INTO t (id) VALUES (2)"),
                                      .init("INSERT INTO nowhere (id) VALUES (3)")])
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(try await db.query("SELECT count(*) AS n FROM t").first?["n"] == .integer(0))
        let changed = try await db.transaction([.init("INSERT INTO t (id) VALUES (1)"),
                                                .init("INSERT INTO t (id) VALUES (2)")])
        #expect(changed == 2)
        #expect(try await db.query("SELECT count(*) AS n FROM t").first?["n"] == .integer(2))
    }

    /// After the checkpoint the journal is empty and the rows are in the
    /// file, readable through a reader of their own; the reader itself
    /// refuses a write.
    @Test("Der Checkpoint leert das Journal, die Zeilen bleiben lesbar; der Leser schreibt nie")
    func checkpointEmptiesTheJournal() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let database = MaerDatabase(path: path)
        let store = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        try await store.replaceAll(Dictionary(uniqueKeysWithValues: (0..<300).map { ("d\($0)", $0) }))
        func size(_ suffix: String) -> Int {
            (try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int) ?? 0
        }
        #expect(size("-wal") > 0, "the writes sit in the journal first")
        let done = try await database.connection().checkpoint()
        #expect(!done.busy)
        #expect(size("-wal") == 0, "TRUNCATE leaves an empty journal")
        let reader = try #require(try database.readerNow())
        #expect(try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: reader).rows.count == 300)
        #expect(throws: (any Error).self) {
            try reader.query("DELETE FROM stats_day")
        }
    }

    /// Several stores share the one connection; their transactions must
    /// never nest. Measured in the simulator before the batch form: two
    /// writes at once ended in "cannot start a transaction within a
    /// transaction".
    @Test("Zwei Speicher auf einer Verbindung schreiben gleichzeitig, ohne sich zu verschachteln")
    func concurrentStoresDoNotNest() async throws {
        let db = try SQLiteConnection(path: ":memory:")
        let days = try await KeyedRowStore<Int>(connection: db, table: .statsDay)
        let items = try await KeyedRowStore<Int>(connection: db, table: .statsItem)
        let library = try await LibraryRowStore(connection: db)
        let big = Dictionary(uniqueKeysWithValues: (0..<400).map { ("k\($0)", $0) })
        async let a = days.replaceAll(big)
        async let b = items.replaceAll(big)
        async let c = library.replaceAll(LibraryDiskCache(items: [], progress: ["x": BookProgress(fraction: 0.5, isFinished: false, lastUpdate: 1)]))
        let (wa, wb, wc) = try await (a, b, c)
        #expect(wa == 400 && wb == 400 && wc.progress == 1)
        let dayCount = try await days.count()
        let itemCount = try await items.count()
        #expect(dayCount == 400 && itemCount == 400)
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
