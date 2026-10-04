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
        keeper?.write(["k": ["a"]], emptying: .refused)
        keeper?.write(["k": ["a", "b"]], emptying: .refused)
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
        keeper.write(["kept": 3], emptying: .refused)
        await keeper.awaitPendingWrites()
        let after = try rows(database)
        #expect(after.rows == ["kept": 3], "rows: \(after.rows)")
        #expect(after.skipped == 1, "the row nobody could read was buried")
    }

    @Test("ein leerer Schnappschuss ohne Absicht entfernt im Keeper nichts, mit Absicht die gelesenen Zeilen")
    func anEmptySnapshotWithoutIntentLeavesTheRows() async throws {
        let (keeper, database, directory) = try await keeperOverUnreadableRows()
        defer { try? FileManager.default.removeItem(at: directory) }
        keeper.write([:], emptying: .refused)
        await keeper.awaitPendingWrites()
        #expect(try rows(database).rows == ["gone": 1, "kept": 2], "an empty snapshot without intent removed rows")
        keeper.write([:], emptying: .allowed)
        await keeper.awaitPendingWrites()
        let after = try rows(database)
        #expect(after.rows.isEmpty && after.skipped == 1, "intended: the read rows leave, the unread one stays")
    }
}
#endif
