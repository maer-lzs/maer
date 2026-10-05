// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The keepers' one door for the app's two ends: every keeper registers
/// itself, `RowKeepers.awaitAll` waits for every living chain, and what
/// died is forgotten.
@MainActor
struct RowKeeperTests {
    private func database() throws -> (MaerDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path), directory)
    }

    @Test("awaitAll wartet jede lebende Kette ab, ein Keeper meldet sich beim Entstehen an, ein toter faellt raus")
    func awaitAllSettlesEveryLivingKeeper() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = RowKeepers.count
        var keeper: RowKeeper<[String]>? = RowKeeper(database: database, table: .playQueue, label: "PROBE")
        #expect(RowKeepers.count == before + 1, "a keeper registers itself on creation")
        keeper?.write(emptying: .refused) { ["k": ["a"]] }
        keeper?.write(emptying: .refused) { ["k": ["a", "b"]] }
        let waited = await RowKeepers.awaitAll()
        #expect(waited >= 1)
        let reader = try #require(try database.readerNow())
        #expect(try KeyedRowStore<[String]>.loadNow(table: .playQueue, reader: reader).rows["k"] == ["a", "b"],
                "after awaitAll the last write has landed")
        keeper = nil
        #expect(RowKeepers.count == before, "a dead keeper is forgotten")
    }

    /// Rows with one row nobody can read: the start read leaves the base
    /// unknown with the rows it read.
    private func keeperOverUnreadableRows() async throws -> (RowKeeper<Int>, MaerDatabase, URL) {
        let (database, directory) = try database()
        let store = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        try await store.replaceAll(["gone": 1, "kept": 2])
        _ = try await database.connection().run("INSERT INTO stats_day (key, payload) VALUES (?, ?)",
                                                [.text("foreign"), .blob(Data("spaeter".utf8))])
        let keeper = RowKeeper<Int>(database: database, table: .statsDay, label: "PROBE")
        #expect(keeper.startNow() == ["gone": 1, "kept": 2], "the precondition: two rows read")
        #expect(keeper.base.plan == .removeSeen, "the precondition: one row unread, the base unknown")
        return (keeper, database, directory)
    }

    private func rows(_ database: MaerDatabase) throws -> KeyedRowStore<Int>.Load {
        try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: try #require(try database.readerNow()))
    }

    @Test("bei unbekannter Grundlage entfernt der Keeper eine gelesene Zeile, die fehlt, und laesst die ungelesene stehen")
    func aReadRowThatIsGoneLeavesTheRows() async throws {
        let (keeper, database, directory) = try await keeperOverUnreadableRows()
        defer { try? FileManager.default.removeItem(at: directory) }
        keeper.write(emptying: .refused) { ["kept": 3] }
        await keeper.awaitPendingWrites()
        let after = try rows(database)
        #expect(after.rows == ["kept": 3], "rows: \(after.rows)")
        #expect(after.skipped == 1, "the row nobody could read was buried")
    }

    @Test("ein leerer Schnappschuss ohne Absicht entfernt im Keeper nichts, mit Absicht die gelesenen Zeilen")
    func anEmptySnapshotWithoutIntentLeavesTheRows() async throws {
        let (keeper, database, directory) = try await keeperOverUnreadableRows()
        defer { try? FileManager.default.removeItem(at: directory) }
        keeper.write(emptying: .refused) { [:] }
        await keeper.awaitPendingWrites()
        #expect(try rows(database).rows == ["gone": 1, "kept": 2], "an empty snapshot without intent removed rows")
        keeper.write(emptying: .allowed) { [:] }
        await keeper.awaitPendingWrites()
        let after = try rows(database)
        #expect(after.rows.isEmpty && after.skipped == 1, "intended: the read rows leave, the unread one stays")
    }

    // MARK: - Over rows the start could not read

    /// A table whose columns are not `key` and `payload`: the start read
    /// fails as a whole, as a read error does, and the file is no fresh
    /// install.
    private func unreadable(_ table: String, in database: MaerDatabase) async throws {
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE \(table) (other TEXT)")
        try await connection.execute("INSERT INTO \(table) (other) VALUES ('x')")
        _ = try await connection.checkpoint()
    }

    /// The table readable again, with the given rows.
    private func healed<Value: Codable & Equatable & Sendable>(_ table: KeyedRowStore<Value>.Table, rows: [String: Value],
                                                               in database: MaerDatabase) async throws {
        let connection = try database.connection()
        try await connection.execute("DROP TABLE \(table.rawValue)")
        let store = try await KeyedRowStore<Value>(connection: connection, table: table)
        _ = try await store.apply(previous: [:], current: rows)
    }

    private final class Memory {
        var rows: [String: Int] = [:]
        var adopted: [[String: Int]] = []
    }

    @Test("ueber ungelesenen Zeilen schreibt der Keeper nicht; gelesen nimmt der Speicher sie auf, dann wird geschrieben")
    func aWriteOverUnreadRowsReadsFirst() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await unreadable("stats_day", in: database)
        let keeper = RowKeeper<Int>(database: database, table: .statsDay, label: "WITNESS")
        #expect(keeper.startNow() == nil)
        #expect(keeper.startReadFailed, "the precondition: the start read failed")
        let memory = Memory()
        memory.rows = ["run": 5]
        keeper.adopt = { read in
            memory.adopted.append(read)
            memory.rows = RowKeeper.union(read: read, run: memory.rows)
        }
        keeper.write(emptying: .refused) { memory.rows }
        await keeper.awaitPendingWrites()
        #expect(keeper.startReadFailed && memory.adopted.isEmpty, "a write went over rows nobody could read")

        try await healed(.statsDay, rows: ["read": 3, "run": 1], in: database)
        keeper.write(emptying: .refused) { memory.rows }
        await keeper.awaitPendingWrites()
        #expect(memory.adopted == [["read": 3, "run": 1]], "the store did not take the rows read")
        #expect(memory.rows == ["read": 3, "run": 5], "the run wins per key, the read rows join")
        #expect(try rows(database).rows == ["read": 3, "run": 5], "the rows hold the memory after the adoption")
        #expect(!keeper.startReadFailed, "a read that succeeded ends the mark")
    }

    @Test("ein Keeper ohne Uebernahme haelt jeden Schrieb ueber ungelesenen Zeilen an")
    func aKeeperWithoutAdoptionHolds() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await unreadable("stats_day", in: database)
        let keeper = RowKeeper<Int>(database: database, table: .statsDay, label: "WITNESS")
        _ = keeper.startNow()
        try await healed(.statsDay, rows: ["read": 3], in: database)
        keeper.write(emptying: .refused) { ["run": 5] }
        await keeper.awaitPendingWrites()
        #expect(try rows(database).rows == ["read": 3], "a keeper without its store's rule wrote over the rows")
        #expect(keeper.startReadFailed)
    }

    /// Two writes queued in one go before the adoption, the rows readable by
    /// then: the second write takes the memory after the adoption, so no row
    /// the first one read leaves.
    @Test("zwei Schriebe in einem Zug vor der Uebernahme: der zweite entfernt keine gelesene Zeile")
    func aWriteQueuedBeforeTheAdoptionKeepsTheReadRows() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await unreadable("stats_day", in: database)
        let keeper = RowKeeper<Int>(database: database, table: .statsDay, label: "WITNESS")
        _ = keeper.startNow()
        let memory = Memory()
        keeper.adopt = { read in memory.rows = RowKeeper.union(read: read, run: memory.rows) }
        try await healed(.statsDay, rows: ["read": 3], in: database)
        memory.rows["first"] = 1
        keeper.write(emptying: .refused) { memory.rows }
        memory.rows["second"] = 2
        keeper.write(emptying: .refused) { memory.rows }
        await keeper.awaitPendingWrites()
        let after = try rows(database).rows
        #expect(after == ["read": 3, "first": 1, "second": 2], "a write queued before the adoption removed rows it read: \(after)")
    }

    /// The positions that never reached the server, after a failed start:
    /// what this run queues waits until the rows are read, and then both
    /// stay, in memory and in the rows.
    @Test("die Sync-Warteschlange nach gescheitertem Start: gelesen bleiben die alten Eintraege neben den neuen")
    func theSyncQueueKeepsTheEntriesItCouldNotRead() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await unreadable("pending_sync", in: database)
        let storage = SyncQueueRowStorage(database: database)
        #expect(storage.startReadFailed, "the precondition: the start read failed")
        let queue = SyncQueue(storage: storage)
        await queue.enqueue(itemId: "new", currentTime: 10, duration: 100, isFinished: false)
        try await healed(.pendingSync, rows: ["old": SyncQueue.PendingUpdate(currentTime: 50, duration: 100,
                                                                             isFinished: false, queuedAt: 1_000)],
                         in: database)
        await queue.enqueue(itemId: "newer", currentTime: 20, duration: 100, isFinished: false)
        await storage.awaitPendingWrites()
        #expect(Set(storage.load().keys) == ["old", "new", "newer"], "memory: \(storage.load().keys.sorted())")
        let reader = try #require(try database.readerNow())
        let rows = try KeyedRowStore<SyncQueue.PendingUpdate>.loadNow(table: .pendingSync, reader: reader).rows
        #expect(Set(rows.keys) == ["old", "new", "newer"], "rows: \(rows.keys.sorted())")
    }

    /// Every keeper in the sources has its store's adoption: a keeper
    /// without one holds every write over unread rows for good.
    @Test("jeder Keeper in den Quellen hat die Uebernahme seines Speichers", .needsTheSources)
    func everyKeeperHasItsAdoption() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "RowKeeper.swift" }
        var keepers = 0
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let built = ConcurrencyFenceTests.sites(of: "RowKeeper(database:", in: code)
            let adopted = ConcurrencyFenceTests.sites(of: ".adopt = {", in: code)
            #expect(built == adopted, "\(file.lastPathComponent): \(built) keepers, \(adopted) adoptions")
            keepers += built
        }
        #expect(keepers == 7, "the keepers counted: \(keepers)")
    }
}
#endif
