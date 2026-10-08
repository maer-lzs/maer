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

    /// The totals keep a chain of their own; it writes to the rows, so the
    /// app's two ends wait for it like for every row chain.
    @Test("awaitAll wartet auch die eigene Kette der Statistik ab")
    func awaitAllSettlesTheTotals() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = RowKeepers.count
        let stats = ListeningStatsStore(carrier: KeyValueStatsCarrier(store: InMemoryCloudStore()), database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory())
        #expect(RowKeepers.count == before + 1, "the totals register their chain on creation")
        stats.addSeconds(120)
        stats.flush()
        await RowKeepers.awaitAll()
        let reader = try #require(try database.readerNow())
        let days = try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: reader).rows
        #expect(days.values.reduce(0, +) == 120, "after awaitAll the totals' last write has landed")
    }

    /// Who opens the database's one connection, and how the app's two ends
    /// wait for what that writes: every row chain registers itself, the
    /// totals register their own chain, the stand rows are waited on by
    /// name, and one reader writes nothing. Both directions: a new opener is
    /// a chain nobody waits for until it is named here.
    static let openers: [String: String] = [
        "RowKeeper.swift": "the keepers write through `RowChain`, which registers itself",
        "LibraryViewModel.swift": "the library rows write through `RowChain` (LIBROWS)",
        "PodcastSubscriptions.swift": "the podcast rows write through `RowChain` (SUBROWS)",
        "ListeningStats.swift": "the totals' own chain registers itself (`RowKeepers.register`)",
        "StandMirror.swift": "the stand rows, waited on by name in `awaitAll`",
        "MaerDatabase.swift": "the Siri book query reads the library rows and writes nothing",
    ]

    @Test("jede Schreibkette in die Datenbank ist angemeldet oder namentlich gewartet, bevor der Checkpoint laeuft", .needsTheSources)
    func everyWriterIsWaitedForBeforeTheCheckpoint() throws {
        var found: Set<String> = []
        var codeOf: [String: String] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            codeOf[file.lastPathComponent] = code
            if code.contains(".connection()") { found.insert(file.lastPathComponent) }
        }
        #expect(found.contains("RowKeeper.swift"), "the fence read the sources")
        #expect(found == Set(Self.openers.keys), "an opener of the connection nobody waits for, or a named one gone: \(found.symmetricDifference(Set(Self.openers.keys)).sorted())")
        #expect(codeOf["RowChain.swift"]?.contains("RowKeepers.register(owner: self)") == true, "a row chain no longer registers")
        #expect(codeOf["ListeningStats.swift"]?.contains("RowKeepers.register(owner: self)") == true, "the totals no longer register")
        let keepers = try #require(codeOf["RowKeeper.swift"])
        let awaitAll = try #require(keepers.range(of: "static func awaitAll()").map { String(keepers[$0.upperBound...].prefix(500)) })
        #expect(awaitAll.contains("StandMirror.shared.awaitPendingWrites()"), "the stand rows are no longer waited on")
        let app = try #require(codeOf["MaerApp.swift"])
        let ends = try #require(app.range(of: "await RowKeepers.awaitAll()"))
        let checkpoint = try #require(app.range(of: "await MaerDatabase.shared.checkpoint()"))
        #expect(ends.upperBound <= checkpoint.lowerBound, "the checkpoint runs before the chains landed")
    }

    @Test("die Erlaubnis zum Leeren gilt im Moment des Aufrufs: nur wenn die Handlung selbst leer liess")
    func thePermissionIsFixedAtTheCall() {
        #expect(RowEmptying.allowed.atCall(memoryIsEmpty: true) == .allowed)
        #expect(RowEmptying.allowed.atCall(memoryIsEmpty: false) == .refused, "a permission granted while rows stood")
        #expect(RowEmptying.refused.atCall(memoryIsEmpty: true) == .refused)
        #expect(RowEmptying.refused.atCall(memoryIsEmpty: false) == .refused)
    }

    @Test("eine verweigerte Leerung spricht nach ihrem Fall: spaeterer Schrieb, abgewertete Erlaubnis, Verdacht")
    func aRefusedWipeSpeaksByItsCase() {
        #expect(WipeRefusal.of(laterQueued: true, narrowedPermission: false) == .laterQueued)
        #expect(WipeRefusal.of(laterQueued: true, narrowedPermission: true) == .laterQueued)
        #expect(WipeRefusal.of(laterQueued: false, narrowedPermission: true) == .narrowedPermission,
                "an intent that only does not cover the list is no suspicion")
        #expect(WipeRefusal.of(laterQueued: false, narrowedPermission: false) == .suspected)
    }

    /// The memory of a witness, shared by the calls and by the chain.
    @MainActor private final class ListMemory { var rows: [String: [String]] = [:] }

    /// A write allowed to empty, handed over while a row still stood, and a
    /// refused change that empties the memory before the first one runs:
    /// the permission does not ride along on the refused emptying.
    @Test("eine Erlaubnis zum Leeren faehrt nicht auf einem verweigerten Leeren mit (Keeper)")
    func aPermissionDoesNotCoverALaterRefusedEmptying() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = ListMemory()
        memory.rows = ["a": ["1"], "b": ["2"]]
        let keeper = RowKeeper<[String]>(database: database, table: .playQueue, label: "PROBE")
        keeper.write(emptying: .refused) { memory.rows }
        await keeper.awaitPendingWrites()
        // Both handed over before the first runs.
        memory.rows.removeValue(forKey: "b")
        keeper.write(emptying: .allowed) { memory.rows }
        memory.rows = [:]
        keeper.write(emptying: .refused) { memory.rows }
        await keeper.awaitPendingWrites()
        let reader = try #require(try database.readerNow())
        let rows = try KeyedRowStore<[String]>.loadNow(table: .playQueue, reader: reader).rows
        #expect(rows["a"] == ["1"], "the refused emptying rode along on the permission: \(rows.keys.sorted())")
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

    /// A store gone before its write ran: the write takes nothing and writes
    /// nothing (the chain says so in a line), and the base stays.
    @Test("ein Speicher, der vor seinem Schrieb fort ist: nichts wird geschrieben, die Grundlage bleibt")
    func aStoreGoneBeforeItsWriteWritesNothing() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        _ = try await store.apply(previous: [:], current: ["kept": 1])
        let keeper = RowKeeper<Int>(database: database, table: .statsDay, label: "WITNESS")
        #expect(keeper.startNow() == ["kept": 1], "the precondition: the row read")
        keeper.write(emptying: .allowed) { nil }
        await keeper.awaitPendingWrites()
        #expect(try rows(database).rows == ["kept": 1], "a write without a store changed the rows")
        #expect(keeper.base.knownValue == ["kept": 1], "the base moved without a write")
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

    /// The adoption of each store with rows of many keys, after a failed
    /// start: the rows read stand in memory and on disk after the next
    /// write, whichever write it is (here: a delete of nothing, a check).
    @Test("Downloads und Sync-Verlauf nehmen nach gescheitertem Start die gelesenen Zeilen auf")
    func eachStoreAdoptsTheRowsItRead() async throws {
        let (database, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        for table in ["download_meta", "sync_history", "sync_last_checked"] {
            try await unreadable(table, in: database)
        }
        let downloads = DownloadManager(documents: directory, database: database)
        await downloads.ensureScanned()
        let history = SyncHistoryStore(database: database)

        let mark = NavidromeRekeyTests.detail("sub:album:read", songs: ["s"])
        try await healed(.downloadMeta, rows: [mark.id: mark], in: database)
        let ring = SyncHistory.entry(service: .gpodder, direction: .up, counters: [], duration: 1, deviceId: "read")
        try await healed(.syncHistory, rows: [ring.id.uuidString: ring], in: database)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try await healed(.syncLastChecked, rows: ["gpodder": stamp], in: database)

        downloads.deleteDownload(itemId: "sub:album:none")
        history.append(SyncHistory.entry(service: .music, direction: .down, counters: [], duration: 1, deviceId: "run"))
        await downloads.awaitPendingWrites()
        await history.awaitPendingWrites()

        let reader = try #require(try database.readerNow())
        #expect(try KeyedRowStore<LibraryItemDetail>.loadNow(table: .downloadMeta, reader: reader).rows[mark.id] != nil,
                "the download mark nobody read left the rows")
        #expect(history.entries.contains { $0.id == ring.id } && history.entries.count == 2, "ring: \(history.entries.count)")
        #expect(history.lastChecked["gpodder"] == stamp, "the stamp read is not in memory")
        #expect(try KeyedRowStore<SyncHistoryEntry>.loadNow(table: .syncHistory, reader: reader).rows.count == 2)
    }

    /// Every keeper and every chain a store builds itself has the store's
    /// adoption: one without it holds every write over unread rows for good.
    @Test("jeder Keeper und jede eigene Kette in den Quellen hat die Uebernahme ihres Speichers", .needsTheSources)
    func everyKeeperHasItsAdoption() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !["RowKeeper.swift", "RowChain.swift"].contains($0.lastPathComponent) }
        var built = 0
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let here = ConcurrencyFenceTests.sites(of: "RowKeeper(database:", in: code)
                + code.matches(of: #/RowChain(<[^\n(]*>)?\(label:/#).count
            let adopted = ConcurrencyFenceTests.sites(of: ".adopt = {", in: code)
            #expect(here == adopted, "\(file.lastPathComponent): \(here) keepers and chains, \(adopted) adoptions")
            built += here
        }
        #expect(built == 11, "nine keepers and two chains of their own counted: \(built)")
    }

    /// The mechanism "read first over unread rows, adopt, then write" stands
    /// in one place, the chain; no store holds a copy of it (where it stood
    /// twice, one fault stood twice). The totals keep their own rule, by
    /// name: their rows are counters, and a read rebuilds them from the rows
    /// plus what the run counted (`ListeningStatsSync.rebuilt`).
    ///
    /// Held at the form, not at a log text: a base from a read
    /// (`RowBase.afterLoad`) is reckoned in the chain, by the totals, and by
    /// the podcast rows, whose start reads in stages and hands the base it
    /// reckoned to its chain (`started(base:skipped:)`). Both ways of a start
    /// say rows that did not decode in the one line of the chain.
    @Test("die Mechanik lesen, uebernehmen, schreiben steht an einer Stelle", .needsTheSources)
    func theMechanismStandsInOnePlace() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "RowChain.swift" }, "the fence read the sources")
        var reckoning: [String] = []
        var ownChains: [String] = []
        var statsCode = ""
        var chainCode = ""
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("RowBase.afterLoad(") { reckoning.append(file.lastPathComponent) }
            if !file.path.contains("/Sources/Storage/"),
               code.contains(#/pending\w*Write = Task/#) { ownChains.append(file.lastPathComponent) }
            if file.lastPathComponent == "ListeningStats.swift" { statsCode = code }
            if file.lastPathComponent == "RowChain.swift" { chainCode = code }
        }
        for head in ["func started(rows: Snapshot?, skipped: Int)", "func started(base: RowBase<Snapshot>, skipped: Int)"] {
            #expect(functionBody(of: head, in: chainCode)?.contains("logSkippedStart(") == true,
                    "a start without the chain's line for rows that did not decode: \(head)")
        }
        #expect(Set(reckoning) == ["RowChain.swift", "ListeningStats.swift", "PodcastSubscriptions.swift"],
                "a base from a read reckoned in a second place: \(reckoning.sorted())")
        // A write chain of its own outside the storage layer: the totals
        // (their rule, above) and the stand carrier, which writes to a
        // carrier, not to rows.
        #expect(Set(ownChains) == ["ListeningStats.swift", "StandCarrier.swift"], "a chain of its own: \(ownChains.sorted())")
        // The totals' chain writes to the rows: the app's two ends wait for it.
        #expect(statsCode.contains("RowKeepers.register(owner: self)"), "the totals' chain is not waited on at the app's ends")
    }
}
#endif
