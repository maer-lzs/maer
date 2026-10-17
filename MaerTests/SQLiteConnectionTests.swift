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

    /// The page count the checkpoint line carries: a deletion leaves the
    /// file its pages and makes them free pages, which is what the line
    /// is there to show.
    @Test("Die Seitenzahl nennt die freien Seiten, die ein Loeschen in der Datei laesst")
    func pagesNameTheFreeOnes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pages-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let db = try MaerDatabase(path: path).connection()
        try await db.execute("CREATE TABLE big(x TEXT)")
        let text = String(repeating: "x", count: 4000)
        _ = try await db.transaction((0..<100).map { _ in SQLiteConnection.Statement("INSERT INTO big(x) VALUES (?)", [.text(text)]) })
        _ = try await db.checkpoint()
        let full = try await db.pages()
        #expect(full.total >= 100, "a hundred rows of four kilobytes take at least a hundred pages: \(full)")
        #expect(full.free < 10)
        _ = try await db.run("DELETE FROM big")
        _ = try await db.checkpoint()
        let after = try await db.pages()
        #expect(after.total == full.total, "a deletion leaves the file its pages")
        #expect(after.free >= 90, "the deleted rows' pages are free pages: \(after)")
    }

    @Test("jede Verbindung begrenzt das Journal, das nach dem Zurueckschreiben auf der Platte bleibt")
    func theJournalIsLimited() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let db = try SQLiteConnection(path: path)
        let limit = try await db.query("PRAGMA journal_size_limit").first?["journal_size_limit"]?.int64
        #expect(limit == Int64(SQLiteConnection.journalSizeLimit), "the journal keeps any size: \(String(describing: limit))")
        #expect(SQLiteConnection.journalSizeLimit == 4 * 1024 * 1024)
    }

    /// For the question of a VACUUM: what the move of the shownotes leaves
    /// in the file, at 1,000 episodes with about 3 KB of notes each, each
    /// count after `wal_checkpoint(TRUNCATE)`: before, after the move with
    /// the pages per table where SQLite can count them (`dbstat`), and after
    /// one VACUUM. Printed as `NOTESMOVE`; the case holds only that the
    /// move ran.
    @Test("Messung: Seiten und freie Seiten vor und nach dem Umzug der Shownotes bei 1.000 Folgen")
    func whatTheNotesMoveLeaves() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("notesmove-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let db = try MaerDatabase(path: path).connection()
        for statement in PodcastNotesTests.versionOneOpen { try await db.execute(statement) }
        try await db.setSchemaVersion(1, of: PodcastRowStore.family)
        let encoder = JSONEncoder()
        let show = PodcastShow(id: "m", title: "m", author: nil, artworkURL: nil, description: nil,
                               feedURL: "https://notes.example/m.xml", episodes: [])
        let notes = String(repeating: "Shownotes mit Links und Kapiteln. ", count: 90)
        var rows = [SQLiteConnection.Statement("INSERT INTO show (id, position, payload) VALUES ('m', 0, ?)",
                                               [.blob(try encoder.encode(show))])]
        for n in 0..<1_000 {
            var episode = PodcastEpisode(guid: "rss:m:\(n)", title: "Folge \(n)", audioURL: "https://notes.example/\(n).mp3",
                                         pubDate: Double(n), duration: 600)
            episode.description = notes + "\(n)"
            rows.append(.init("INSERT INTO episode (guid, show_id, position, pub_date, payload) VALUES (?, 'm', ?, ?, ?)",
                              [.text(episode.guid), .integer(Int64(n)), .real(Double(n)), .blob(try encoder.encode(episode))]))
        }
        _ = try await db.transaction(rows)
        func tablePages() async -> String {
            (try? await db.query("SELECT name, COUNT(*) AS pages FROM dbstat GROUP BY name ORDER BY name"))?
                .map { "\($0["name"]?.string ?? "?"):\($0["pages"]?.int64 ?? 0)" }.joined(separator: ",") ?? "unread"
        }
        _ = try await db.checkpoint()
        let before = try await db.pages()
        let tablesBefore = await tablePages()
        let started = Date()
        // The move without its own VACUUM: the pages it leaves, then one VACUUM below.
        let store = try await PodcastRowStore(connection: db, vacuum: "SELECT 1")
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        _ = try await db.checkpoint()
        let after = try await db.pages()
        let tables = await tablePages()
        let vacuumStarted = Date()
        try await db.execute("VACUUM")
        let vacuumMs = Int(Date().timeIntervalSince(vacuumStarted) * 1000)
        _ = try await db.checkpoint()
        let vacuumed = try await db.pages()
        print("NOTESMOVE episodes=1000 pages_before=\(before.total) free_before=\(before.free) tables_before=\(tablesBefore) pages_after=\(after.total) free_after=\(after.free) move_ms=\(ms) tables_after=\(tables) pages_vacuum=\(vacuumed.total) free_vacuum=\(vacuumed.free) vacuum_ms=\(vacuumMs)")
        #expect(try await store.notes(guid: "rss:m:7") == notes + "7", "the precondition: the move ran")
    }

    /// The page count is its own measurement: when it cannot be read, the
    /// checkpoint line says that, never "checkpoint failed".
    @Test("Eine Seitenzahl, die nicht gelesen wird, sagt das selbst und nicht der Checkpoint")
    func anUnreadPageCountSaysSo() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("field-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let readable = MaerDatabase(path: path)
        _ = try readable.connection()
        let field = await MaerDatabase.pagesField(of: readable)
        #expect(field.hasPrefix("file=") && field.contains(" free="), "\(field)")
        let missing = MaerDatabase(path: "/nonexistent-\(UUID().uuidString)/x.sqlite")
        #expect(await MaerDatabase.pagesField(of: missing).hasPrefix("file=unread reason="))
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

    @Test("Fehler nennen die Anweisung; was geschrieben ist, bleibt in der Datei")
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
            try await first.execute("CREATE TABLE stand (item_id TEXT PRIMARY KEY, position REAL NOT NULL)")
            try await first.run("INSERT INTO stand VALUES (?, ?)", [.text("rss:x"), .real(600)])
        }
        let second = try SQLiteConnection(path: file)
        #expect(try await second.query("SELECT position FROM stand WHERE item_id = ?", [.text("rss:x")]).first?["position"] == .real(600))
    }
}
#endif
