// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// The listening stock is held in memory: read once from the defaults,
/// asked from memory afterwards, and the row copy follows it exactly.
@Suite(.serialized)
struct PositionStockTests {
    private func suite() -> (UserDefaults, String) {
        let name = "position-stock-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Der Bestand wird einmal gelesen; ein Wiedergabe-Tick liest danach keinen Positions-Schluessel")
    func aTickReadsNoPositionKey() throws {
        let name = "position-counting-\(UUID().uuidString)"
        let counting = try #require(ForeignMarksTests.CountingDefaults(suiteName: name))
        defer { counting.removePersistentDomain(forName: name) }
        ListeningStore.store("rss:stock:a", entry: [30, 1_000, 600], in: counting)
        counting.asked.withLock { $0.removeAll() }
        for tick in 0..<100 {
            ListeningStore.record("rss:stock:a", position: Double(40 + tick), duration: 600,
                                  atMs: Double(2_000 + tick), in: counting)
            _ = ListeningStore.mark("rss:stock:a", in: counting)
            _ = ListeningStore.flushed("rss:stock:a", in: counting)
        }
        _ = counting.object(forKey: "instrument.check")
        let asked = counting.asked.withLock { $0 }
        #expect(asked.contains("instrument.check"), "the counter hears a read at all")
        let positionReads = asked.filter { $0.hasPrefix("localPosition.") || $0.hasPrefix("flushedPosition.") }
        #expect(positionReads.isEmpty, "no position key read after the first load: \(positionReads.prefix(5))")
        #expect(ListeningStore.backup("rss:stock:a", in: counting)?.first == 139)
        #expect(counting.object(forKey: AppStorageKeys.localPosition("rss:stock:a")) == nil,
                "the defaults are no longer written")
    }

    /// A database in a file of its own, with the synchronous read the app's
    /// start uses, for the move.
    private func fileTable() async throws -> (StandStore, @Sendable () throws -> ListeningStore.Stock?, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stand-move-\(UUID().uuidString).sqlite")
        let store = try await StandStore(connection: try SQLiteConnection(path: file.path))
        let path = file.path
        return (store, { try StandStore.loadNow(reader: try SQLiteReader(path: path)) }, file)
    }

    /// A row the build cannot read (text in the position column) is counted
    /// at the start, not dropped silently, and the id move names the stands
    /// as a step that missed rows; a whole table misses none.
    @Test("eine Zeile, die nicht liest, wird gezaehlt statt still verworfen, und der Umzug nennt die Hoerstaende")
    func anUnreadStandRowIsCounted() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let (_, loadNow, file) = try await fileTable()
        defer { try? FileManager.default.removeItem(at: file) }
        let connection = try SQLiteConnection(path: file.path)
        try await connection.run("INSERT INTO stand (item_id, position, updated_at_ms) VALUES (?, ?, ?)",
                                 [.text("rss:a"), .real(12), .real(1)])
        try await connection.run("INSERT INTO stand (item_id, position, updated_at_ms) VALUES (?, ?, ?)",
                                 [.text("rss:b"), .text("nicht"), .real(1)])
        let stock = try #require(try loadNow())
        #expect(stock.backups.keys.sorted() == ["rss:a"], "what reads is loaded as before")
        #expect(stock.skippedRows == 1, "the unread row was dropped silently")
        defaults.set(true, forKey: ListeningStore.movedKey)
        ListeningStore.installTable(for: defaults, load: loadNow)
        #expect(ListeningStore.startMissedRows(in: defaults), "the move does not name the stands")
        // The same table without the unread row: nothing missed.
        try await connection.run("DELETE FROM stand WHERE item_id = ?", [.text("rss:b")])
        ListeningStore.installTable(for: defaults, load: loadNow)
        #expect(!ListeningStore.startMissedRows(in: defaults))
    }

    @Test("der erste Start zieht den Altbestand in die Tabelle, setzt die Marke und raeumt die alten Schluessel erst nach voller Deckung")
    func theFirstStartMovesTheStock() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        // The old keys, as a build before this one left them.
        defaults.set([300.0, 1_000.0, 600.0], forKey: "localPosition.rss:move:a")
        defaults.set([0.0, 2_000.0], forKey: "localPosition.rss:move:tomb")
        defaults.set([300.0, 1_500.0], forKey: "flushedPosition.rss:move:a")
        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        #expect(ListeningStore.isMoved(in: defaults), "the marker, once the rows hold the stock")
        #expect(ListeningStore.isMoveStarted(in: defaults), "and the record that the move began")
        let rows = try await store.all()
        #expect(rows["rss:move:a"]?.entry == [300, 1_000, 600])
        #expect(rows["rss:move:tomb"]?.entry == [0, 2_000], "a tombstone moves like any entry")
        #expect(try await store.allFlushed() == ["rss:move:a": [300, 1_500]])
        #expect(defaults.object(forKey: "localPosition.rss:move:a") == nil
                && defaults.object(forKey: "localPosition.rss:move:tomb") == nil
                && defaults.object(forKey: "flushedPosition.rss:move:a") == nil, "the old keys are gone")

        // The next start: the table is the stock, nothing reads the old keys.
        ListeningStore.store("rss:move:b", entry: [40, 3_000], in: defaults)
        await mirror.awaitPendingWrites()
        let next = StandMirror(store: store, loadNow: loadNow)
        next.start(defaults: defaults)
        await next.awaitPendingWrites()
        #expect(ListeningStore.backup("rss:move:a", in: defaults) == [300, 1_000, 600])
        #expect(ListeningStore.backup("rss:move:b", in: defaults) == [40, 3_000], "a write after the move stands after the next start")
        #expect(ListeningStore.flushed("rss:move:a", in: defaults) == [300, 1_500])
        #expect(defaults.object(forKey: "localPosition.rss:move:b") == nil, "and it never went to the defaults")
    }

    @Test("fehlt ein alter Eintrag in der Tabelle, bleibt genau sein Schluessel stehen; die gedeckten gehen")
    func aMissingEntryKeepsItsOwnKey() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        // Moved already, and the retirement was cut short: old keys stand,
        // one of them for an entry the table no longer holds (it was
        // removed after the move).
        try await store.upsert(Stand(itemId: "rss:keep:a", position: 10, updatedAtMs: 1_000, duration: nil))
        _ = try await store.replaceFlushed(with: ["rss:keep:a": [10, 1_500]])
        defaults.set(true, forKey: ListeningStore.movedKey)
        defaults.set([10.0, 1_000.0], forKey: "localPosition.rss:keep:a")
        defaults.set([10.0, 1_500.0], forKey: "flushedPosition.rss:keep:a")
        defaults.set([20.0, 1_000.0], forKey: "localPosition.rss:keep:lost")
        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        #expect(defaults.object(forKey: "localPosition.rss:keep:lost") as? [Double] == [20, 1_000],
                "an old entry the table lacks keeps its key")
        #expect(defaults.object(forKey: "localPosition.rss:keep:a") == nil
                && defaults.object(forKey: "flushedPosition.rss:keep:a") == nil,
                "a covered entry's keys go although another one is missing")
        #expect(ListeningStore.backup("rss:keep:a", in: defaults) == [10, 1_000], "the table is the stock")
        #expect(ListeningStore.backup("rss:keep:lost", in: defaults) == nil, "a kept key does not come back into the stock")
    }

    @Test("bricht der erste Start vor der Marke ab, verliert der naechste nichts, was dazwischen geschrieben wurde")
    func aBrokenFirstStartLosesNothing() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        // What a first start leaves when it breaks off before its marker:
        // the record that the move began, the old keys, and rows written in
        // that start, one newer than its old key and one the keys never had.
        defaults.set(true, forKey: ListeningStore.moveStartedKey)
        defaults.set([10.0, 1_000.0], forKey: "localPosition.rss:win:a")
        defaults.set([10.0, 1_500.0], forKey: "flushedPosition.rss:win:a")
        try await store.upsert(Stand(itemId: "rss:win:a", position: 50, updatedAtMs: 5_000, duration: nil))
        try await store.upsert(Stand(itemId: "rss:win:b", position: 20, updatedAtMs: 3_000, duration: nil))
        _ = try await store.replaceFlushed(with: ["rss:win:a": [50, 5_500], "rss:win:b": [20, 3_500]])
        #expect(!ListeningStore.isMoved(in: defaults), "the marker never landed")

        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        #expect(ListeningStore.backup("rss:win:b", in: defaults) == [20, 3_000], "the stock holds what the broken start wrote")
        #expect(ListeningStore.backup("rss:win:a", in: defaults) == [50, 5_000], "and the newer of the two")
        await mirror.awaitPendingWrites()
        let rows = try await store.all()
        #expect(rows["rss:win:b"]?.entry == [20, 3_000], "no row goes")
        #expect(rows["rss:win:a"]?.entry == [50, 5_000])
        #expect(try await store.allFlushed() == ["rss:win:a": [50, 5_500], "rss:win:b": [20, 3_500]])
        #expect(ListeningStore.isMoved(in: defaults))
        #expect(defaults.object(forKey: "localPosition.rss:win:a") == nil
                && defaults.object(forKey: "flushedPosition.rss:win:a") == nil, "the old keys are covered by newer rows and go")
    }

    @Test("bricht der erste Start vor der Marke ab und scheitert beim naechsten das Lesen der Tabelle, bleiben ihre Zeilen, die Marke kommt nicht, die Schluessel bleiben")
    func aResumeOverAFailedReadKeepsTheRows() async throws {
        let (defaults, name) = suite()
        let (store, _, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        // The same broken first start; this time the synchronous read of the
        // table fails, while the chain's own connection still writes.
        defaults.set(true, forKey: ListeningStore.moveStartedKey)
        defaults.set([10.0, 1_000.0], forKey: "localPosition.rss:win:a")
        try await store.upsert(Stand(itemId: "rss:win:a", position: 50, updatedAtMs: 5_000, duration: nil))
        try await store.upsert(Stand(itemId: "rss:win:b", position: 20, updatedAtMs: 3_000, duration: nil))
        struct Unreadable: Error {}

        let mirror = StandMirror(store: store, loadNow: { throw Unreadable() })
        mirror.start(defaults: defaults)
        #expect(ListeningStore.readFailed(in: defaults), "the precondition: the stock answered from the old keys")
        #expect(ListeningStore.backup("rss:win:b", in: defaults) == nil, "the precondition: the old keys lack the broken start's row")
        await mirror.awaitPendingWrites()
        let rows = try await store.all()
        #expect(rows["rss:win:b"]?.entry == [20, 3_000], "the repair took a row the old keys lack")
        #expect(rows["rss:win:a"]?.entry == [50, 5_000], "the repair wrote an older key over a newer row")
        #expect(!ListeningStore.isMoved(in: defaults), "the marker came over a stock that is not whole")
        #expect(defaults.object(forKey: "localPosition.rss:win:a") != nil, "an old key went over an unread table")
    }

    @Test("liest der Start die Marke des Umzugs nicht, obwohl die Tabelle Zeilen hat, geht keine Zeile, und die Marke wartet")
    func aMisreadMoveMarkEmptiesNothing() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        // A moved device whose marks read unset at this start: no old keys,
        // rows in both tables.
        try await store.upsert(Stand(itemId: "rss:kept:a", position: 50, updatedAtMs: 5_000, duration: nil))
        _ = try await store.replaceFlushed(with: ["rss:kept:a": [50, 5_500]])
        #expect(!ListeningStore.isMoved(in: defaults) && !ListeningStore.isMoveStarted(in: defaults), "the precondition: both marks read unset")

        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        #expect(try await store.all()["rss:kept:a"]?.entry == [50, 5_000], "the start emptied the stand table")
        #expect(try await store.allFlushed() == ["rss:kept:a": [50, 5_500]], "the start emptied the flushed table")
        #expect(!ListeningStore.isMoved(in: defaults), "the mark came over a table the start did not read")
        // A write of this run adds nothing older and removes nothing.
        ListeningStore.store("rss:kept:a", entry: [10, 1_000], in: defaults)
        ListeningStore.clearBackup("rss:kept:a", in: defaults)
        await mirror.awaitPendingWrites()
        #expect(try await store.all()["rss:kept:a"]?.entry == [50, 5_000], "a write of this run went over the row")
    }

    @Test("eine Reparatur ueber alten Schluesseln laesst eine Zeile stehen, die kein alter Schluessel nennt")
    func theRepairKeepsARowNoOldKeyNames() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        // Old keys hold one title, the table holds it and another one.
        // The key is set in the defaults themselves: the start drops the
        // stock held in memory and reads the old keys from there.
        defaults.set([20.0, 2_000.0], forKey: AppStorageKeys.localPosition("rss:old:a"))
        try await store.upsert(Stand(itemId: "rss:old:a", position: 10, updatedAtMs: 1_000, duration: nil))
        try await store.upsert(Stand(itemId: "rss:new:b", position: 70, updatedAtMs: 7_000, duration: nil))
        #expect(!ListeningStore.isMoved(in: defaults) && !ListeningStore.isMoveStarted(in: defaults), "the precondition: both marks read unset")

        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        let rows = try await store.all()
        #expect(rows["rss:old:a"]?.entry == [20, 2_000], "the precondition: the repair ran and wrote the old key's entry")
        #expect(ListeningStore.isMoved(in: defaults), "the precondition: the repair ended")
        #expect(rows["rss:new:b"]?.entry == [70, 7_000], "the repair removed a row no old key names")
    }

    @Test("eine Zeile aus dem Konto mit alter Zeit, die waehrend der Reparatur eintrifft, bleibt")
    func aRowThatArrivesDuringTheRepairStays() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        defaults.set([20.0, 2_000.0], forKey: AppStorageKeys.localPosition("rss:old:a"))
        try await store.upsert(Stand(itemId: "rss:old:a", position: 10, updatedAtMs: 1_000, duration: nil))
        try await store.upsert(Stand(itemId: "rss:gone:d", position: 5, updatedAtMs: 500, duration: nil))
        // The account's row lies in the table and the read at the start
        // does not hold it: it arrives after that read, with an old moment.
        try await store.upsert(Stand(itemId: "rss:acct:c", position: 30, updatedAtMs: 500, duration: nil))
        let readBefore: @Sendable () throws -> ListeningStore.Stock? = {
            var stock = try loadNow()
            stock?.backups["rss:acct:c"] = nil
            return stock
        }

        let mirror = StandMirror(store: store, loadNow: readBefore)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        let rows = try await store.all()
        #expect(ListeningStore.isMoved(in: defaults), "the precondition: the repair ended")
        #expect(rows["rss:gone:d"] == nil, "the precondition: the repair removes a row that was there and has no old key")
        #expect(rows["rss:acct:c"]?.entry == [30, 500], "the repair took a row that arrived after its read")
    }

    @Test("scheitert nach dem Umzug das Lesen der Tabelle, schreibt ein Einzelschrieb nur Neueres und entfernt nichts")
    func aFailedReadWritesOnlyNewer() async throws {
        let (defaults, name) = suite()
        let (store, _, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        defaults.set(true, forKey: ListeningStore.movedKey)
        try await store.upsert(Stand(itemId: "rss:row:a", position: 50, updatedAtMs: 5_000, duration: nil))
        try await store.upsert(Stand(itemId: "rss:row:b", position: 20, updatedAtMs: 3_000, duration: nil))
        try await store.upsertFlushed(itemId: "rss:row:a", entry: [50, 5_500])
        struct Unreadable: Error {}

        let mirror = StandMirror(store: store, loadNow: { throw Unreadable() })
        mirror.start(defaults: defaults)
        #expect(ListeningStore.readFailed(in: defaults), "the precondition: the table did not read at the start")
        ListeningStore.store("rss:row:a", entry: [10, 1_000], in: defaults)
        ListeningStore.store("rss:row:b", entry: [90, 9_000], in: defaults)
        ListeningStore.clearBackup("rss:row:b", in: defaults)
        ListeningStore.store("rss:row:c", entry: [7, 7_000], in: defaults)
        await mirror.awaitPendingWrites()
        let rows = try await store.all()
        #expect(rows["rss:row:a"]?.entry == [50, 5_000], "an older stand went over the row")
        #expect(rows["rss:row:b"]?.entry == [90, 9_000], "a newer stand did not land, or the removal went through")
        #expect(rows["rss:row:c"]?.entry == [7, 7_000], "a new title did not land")
        #expect(try await store.allFlushed()["rss:row:a"] == [50, 5_500])
    }

    @Test("die Deckung, je Eintrag gleich oder neuer, ein Grabstein zaehlt wie jeder Eintrag")
    func theCoverageRule() {
        let legacy = ListeningStore.Stock(backups: ["a": [10, 1_000], "tomb": [0, 2_000], "radio:x": [5, 1],
                                                    "short": [1]],
                                          flushed: ["a": [10, 1_500]])
        let same = ListeningStore.Stock(backups: ["a": [10, 1_000], "tomb": [0, 2_000]], flushed: ["a": [10, 1_500]])
        let equal = ListeningStore.legacyCovered(legacy: legacy, table: same)
        #expect(equal.missing.isEmpty && equal.retire == legacy,
                "equal entries cover; a live stream and a short array carry nothing to lose and go too")
        let newer = ListeningStore.Stock(backups: ["a": [99, 5_000], "tomb": [7, 3_000]], flushed: ["a": [20, 1_600]])
        #expect(ListeningStore.legacyCovered(legacy: legacy, table: newer).retire == legacy, "newer entries cover")
        let older = ListeningStore.Stock(backups: ["a": [99, 500], "tomb": [0, 2_000]], flushed: ["a": [10, 1_500]])
        let behind = ListeningStore.legacyCovered(legacy: legacy, table: older)
        #expect(behind.missing == ["a"], "an older entry does not")
        #expect(behind.retire.backups["a"] == nil && behind.retire.backups["tomb"] != nil
                && behind.retire.flushed["a"] != nil, "and only its own key stays")
        let lacking = ListeningStore.Stock(backups: ["a": [10, 1_000]], flushed: [:])
        let short = ListeningStore.legacyCovered(legacy: legacy, table: lacking)
        #expect(short.missing == ["flushed a", "tomb"], "a missing tombstone and a missing pushed witness each stay")
        #expect(short.retire.backups.keys.sorted() == ["a", "radio:x", "short"] && short.retire.flushed.isEmpty)

        // Resuming a broken move: per entry the newer, on a tie the old key's.
        let merged = ListeningStore.merged(ListeningStore.Stock(backups: ["a": [10, 1_000], "t": [5, 2_000]],
                                                                flushed: ["a": [10, 1_500]]),
                                           ListeningStore.Stock(backups: ["a": [50, 5_000], "b": [20, 3_000], "t": [6, 2_000]],
                                                                flushed: ["a": [9, 1_400], "b": [20, 3_500]]))
        #expect(merged.backups == ["a": [50, 5_000], "b": [20, 3_000], "t": [5, 2_000]])
        #expect(merged.flushed == ["a": [10, 1_500], "b": [20, 3_500]])
    }

    @Test("Ein Bestand in der alten Form wird ohne Verlust gelesen, auch ganze Zahlen und das zuletzt Gesendete")
    func theOldFormLoadsWhole() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // As builds up to 44 wrote it: two, three and four values, whole
        // numbers stored as integers, the pushed witness beside it.
        defaults.set([120.0, 1_700_000_000_000.0], forKey: "localPosition.rss:old:two")
        defaults.set([300.0, 1_700_000_001_000.0, 3_600.0], forKey: "localPosition.abs:old:three")
        defaults.set([0.0, 1_700_000_002_000.0, 0.0, 2.0], forKey: "localPosition.jam:old:four")
        defaults.set([NSNumber(value: 45), NSNumber(value: 1_700_000_003_000)], forKey: "localPosition.sub:old:ints")
        // A number the Double bridge refuses (not exactly representable):
        // the sync read such an entry through NSNumber, so the stock must too.
        defaults.set([NSNumber(value: 45), NSNumber(value: Int64.max)], forKey: "localPosition.sub:old:huge")
        defaults.set([90.0, 1_700_000_004_000.0], forKey: "flushedPosition.rss:old:two")
        defaults.set([1.0, 2.0], forKey: "radioSomething.unrelated")
        let positions = ListeningStore.positions(in: defaults)
        #expect(positions.count == 5, "\(positions.keys.sorted())")
        #expect(positions["sub:old:huge"]?.first == 45, "read through NSNumber, not dropped")
        #expect(positions["rss:old:two"] == [120, 1_700_000_000_000])
        #expect(positions["abs:old:three"] == [300, 1_700_000_001_000, 3_600])
        #expect(positions["jam:old:four"] == [0, 1_700_000_002_000, 0, 2])
        #expect(positions["sub:old:ints"] == [45, 1_700_000_003_000], "integers read as numbers, as the sync read them")
        #expect(ListeningStore.flushed("rss:old:two", in: defaults) == [90, 1_700_000_004_000])
        #expect(ListeningStore.mark("rss:old:two", in: defaults)?.source == .backup)
    }

    @Test("Der Start bringt die Zeilen genau auf den Bestand: ein Grabstein ist ein Eintrag, eine Zeile ohne Schluessel geht")
    func theRowsFollowTheStockAtStart() async throws {
        let (defaults, name) = suite()
        defer {
            defaults.removePersistentDomain(forName: name)
            ListeningStore.listen(to: defaults, nil)
        }
        let store = try await StandStore(connection: try SQLiteConnection(path: ":memory:"))
        // The table as an earlier run left it.
        try await store.upsert(Stand(itemId: "rss:start:tomb", position: 500, updatedAtMs: 1_000, duration: 600))
        try await store.upsert(Stand(itemId: "rss:start:gone", position: 50, updatedAtMs: 1_000, duration: nil))
        try await store.upsertFlushed(itemId: "rss:start:gone", entry: [50, 1_000])
        // The defaults, written first: the episode was marked unplayed
        // later, the other title was removed before its row went.
        defaults.set([0.0, 2_000.0], forKey: "localPosition.rss:start:tomb")
        defaults.set([10.0, 3_000.0], forKey: "localPosition.rss:start:new")
        defaults.set([10.0, 3_100.0], forKey: "flushedPosition.rss:start:new")
        let mirror = StandMirror(store: store)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        let rows = try await store.all()
        #expect(rows["rss:start:tomb"]?.entry == [0, 2_000], "the newer tombstone wins over the older row")
        #expect(ListeningStore.backup("rss:start:tomb", in: defaults) == [0, 2_000])
        #expect(rows["rss:start:gone"] == nil, "a row whose title the stock no longer holds goes")
        #expect(rows["rss:start:new"]?.entry == [10, 3_000])
        #expect(try await store.allFlushed() == ["rss:start:new": [10, 3_100]], "the pushed witnesses follow too")
        // And every write afterwards arrives in both tables.
        ListeningStore.noteFlushed("rss:start:new", position: 20, atMs: 4_000, in: defaults)
        ListeningStore.forgetUserDeleted("rss:start:tomb", in: defaults)
        await mirror.awaitPendingWrites()
        #expect(try await store.allFlushed()["rss:start:new"] == [20, 4_000])
        #expect(try await store.all()["rss:start:tomb"] == nil)
    }

    // MARK: - The fence

    /// Reads of a position key from the defaults: exactly one, the load of
    /// the stock. Anywhere else the keys are only named where they are
    /// defined or classified.
    static let namedOnly: [String: String] = [
        "AppStorageKeys.swift": "defines the two keys",
        "UserChoiceSync.swift": "classifies the key families, reads no value",
        "DerivedStores.swift": "lists the user-owned prefixes for a fence, reads no value",
    ]

    @Test("Niemand liest oder schreibt localPosition. oder flushedPosition., ausser dem Laden und dem Raeumen der alten Schluessel", .needsTheSources)
    func noOneReadsPositionKeys() throws {
        let files = ProjectFileIntegrityTests.sourceFiles()
        try #require(files.contains { $0.lastPathComponent == "ListeningStore.swift" },
                     "the finder sees the store whose stock this protects")
        let spellings = ["AppStorageKeys.localPosition(", "AppStorageKeys.flushedPosition(",
                         "\"localPosition.", "\"flushedPosition."]
        var outside: [String: Int] = [:]
        for file in files where file.lastPathComponent != "ListeningStore.swift" {
            let source = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let hits = spellings.reduce(0) { $0 + source.components(separatedBy: $1).count - 1 }
            if hits > 0 { outside[file.lastPathComponent] = hits }
        }
        #expect(Set(outside.keys) == Set(Self.namedOnly.keys), "named only where defined or classified: \(outside)")

        let storeFile = try #require(files.first { $0.lastPathComponent == "ListeningStore.swift" })
        let store = SyncContractFenceTests.stripped(try String(contentsOf: storeFile, encoding: .utf8))
        for read in ["array(forKey:", "object(forKey:", "string(forKey:", "data(forKey:"] {
            #expect(!store.contains(read), "the store reads no single key: \(read)")
        }
        #expect(store.components(separatedBy: "dictionaryRepresentation()").count - 1 == 1,
                "one read of the whole domain")
        let load = try #require(store.range(of: "private static func loadFromDefaults"))
        let scan = try #require(store.range(of: "dictionaryRepresentation()"))
        let nextFunc = store.range(of: "static func", range: load.upperBound..<store.endIndex)
        #expect(scan.lowerBound > load.lowerBound && scan.lowerBound < (nextFunc?.lowerBound ?? store.endIndex),
                "and it is the load of the stock")

        // Since the move, nothing writes the keys; the one removal is the
        // retirement of the old keys.
        let lines = store.split(separator: "\n").map(String.init)
        let writes = lines.filter { $0.contains(".set(") && ($0.contains("AppStorageKeys.localPosition(")
                                                             || $0.contains("AppStorageKeys.flushedPosition(")) }
        #expect(writes.isEmpty, "no position key is written: \(writes)")
        let removals = lines.filter { $0.contains("removeObject(") && ($0.contains("AppStorageKeys.localPosition(")
                                                                       || $0.contains("AppStorageKeys.flushedPosition(")) }
        #expect(removals.count == 2, "one removal per family: \(removals)")
        let retire = try #require(store.range(of: "static func retireLegacyKeys"))
        let afterRetire = store.range(of: "static func", range: retire.upperBound..<store.endIndex)?.lowerBound ?? store.endIndex
        for removal in removals {
            let at = try #require(store.range(of: removal))
            #expect(at.lowerBound > retire.lowerBound && at.lowerBound < afterRetire, "only in the retirement: \(removal)")
        }
    }

    /// A defaults object that counts its walks over the whole domain.
    nonisolated final class WalkCountingDefaults: UserDefaults {
        let walks = Mutex(0)
        override func dictionaryRepresentation() -> [String: Any] {
            walks.withLock { $0 += 1 }
            return super.dictionaryRepresentation()
        }
    }

    /// After the move a stock with rows, and a mirror that starts on it.
    private func movedStock(_ name: String, rows: [String: [Double]]) async throws
        -> (WalkCountingDefaults, StandStore, @Sendable () throws -> ListeningStore.Stock?, URL) {
        let defaults = try #require(WalkCountingDefaults(suiteName: name))
        let (store, loadNow, file) = try await fileTable()
        for (id, entry) in rows { try await store.upsert(try #require(Stand(itemId: id, entry: entry))) }
        defaults.set(true, forKey: ListeningStore.movedKey)
        defaults.set(true, forKey: ListeningStore.moveStartedKey)
        return (defaults, store, loadNow, file)
    }

    @Test("nach dem Umzug liest das Laden des Bestands die Domaene nicht, nur die Kette liest die alten Schluessel einmal")
    func afterTheMoveTheStartWalksNothing() async throws {
        let name = "position-walks-\(UUID().uuidString)"
        let (defaults, store, loadNow, file) = try await movedStock(name, rows: ["rss:walk:a": [100, 1_000]])
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        ListeningStore.installTable(for: defaults, load: loadNow)
        defaults.walks.withLock { $0 = 0 }
        #expect(ListeningStore.positions(in: defaults)["rss:walk:a"] == [100, 1_000], "the stock is the table")
        #expect(defaults.walks.withLock { $0 } == 0, "loading the stock walked the domain")
        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        #expect(defaults.walks.withLock { $0 } == 1, "the old keys are read once, on the chain")
    }

    @Test("ein spaeter Altschluessel geht in den Bestand, wenn er neuer ist als die Zeile; bei Gleichstand gewinnt die Zeile und sein Schluessel bleibt")
    func aLateOldKeyNewerThanItsRowIsAdopted() async throws {
        let name = "position-late-\(UUID().uuidString)"
        let (defaults, store, loadNow, file) = try await movedStock(name, rows: ["rss:late:newer": [100, 1_000],
                                                                            "rss:late:tie": [100, 1_000]])
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        // What a build that writes old keys left after the move.
        defaults.set([250.0, 2_000.0], forKey: AppStorageKeys.localPosition("rss:late:newer"))
        defaults.set([180.0, 1_000.0], forKey: AppStorageKeys.localPosition("rss:late:tie"))
        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        await mirror.awaitPendingWrites()
        #expect(ListeningStore.backup("rss:late:newer", in: defaults) == [250, 2_000], "the later listening is not in the stock")
        #expect(try await store.stand(for: "rss:late:newer")?.entry == [250, 2_000], "the row did not follow")
        #expect(ListeningStore.backup("rss:late:tie", in: defaults) == [100, 1_000], "on a tie the row wins")
        #expect(try await store.stand(for: "rss:late:tie")?.entry == [100, 1_000])
        #expect(defaults.object(forKey: AppStorageKeys.localPosition("rss:late:newer")) == nil, "the adopted key stays")
        // Another entry at the same moment is not covered: its key stays,
        // as before.
        #expect(defaults.object(forKey: AppStorageKeys.localPosition("rss:late:tie")) as? [Double] == [180, 1_000],
                "the key of a tie went")
    }

    @Test("ein Altschluessel ohne Zeile kommt nur zurueck, wenn er nach dem letzten Gang geschrieben wurde; ein frueherer belebt keinen geraeumten Stand und behaelt seinen Schluessel")
    func anOldKeyWithoutARowComesBackOnlyWhenWrittenSince() async throws {
        let name = "position-norow-\(UUID().uuidString)"
        let (defaults, store, loadNow, file) = try await movedStock(name, rows: [:])
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.listen(to: defaults, nil)
        }
        defaults.set(5_000.0, forKey: ListeningStore.legacyWalkKey)
        defaults.set([300.0, 6_000.0], forKey: AppStorageKeys.localPosition("rss:norow:since"))
        defaults.set([400.0, 4_000.0], forKey: AppStorageKeys.localPosition("rss:norow:before"))
        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        await mirror.awaitPendingWrites()
        #expect(ListeningStore.backup("rss:norow:since", in: defaults) == [300, 6_000], "listening written since is lost")
        #expect(try await store.stand(for: "rss:norow:since")?.entry == [300, 6_000])
        #expect(ListeningStore.backup("rss:norow:before", in: defaults) == nil, "a removed state came back")
        #expect(try await store.stand(for: "rss:norow:before") == nil)
        #expect(defaults.object(forKey: AppStorageKeys.localPosition("rss:norow:since")) == nil, "the adopted key stays")
        #expect(defaults.object(forKey: AppStorageKeys.localPosition("rss:norow:before")) as? [Double] == [400, 4_000],
                "a key the table lacks went")
        #expect((defaults.object(forKey: ListeningStore.legacyWalkKey) as? Double ?? 0) > 5_000, "the walk is not noted")
    }

    @Test("die Regel der spaeten Altschluessel als Tabelle")
    func theLateRuleAsATable() {
        let table: [String: [Double]] = ["rss:r:row": [10, 1_000]]
        let legacy: [String: [Double]] = ["rss:r:row": [20, 1_001], "rss:r:new": [5, 3_000],
                                          "rss:r:old": [5, 1_500], "radio:live": [5, 9_000]]
        let withWalk = ListeningStore.lateAdoption(legacy: legacy, table: table, lastWalkMs: 2_000)
        #expect(withWalk == ["rss:r:row": [20, 1_001], "rss:r:new": [5, 3_000]])
        let noWalk = ListeningStore.lateAdoption(legacy: legacy, table: table, lastWalkMs: nil)
        #expect(noWalk == ["rss:r:row": [20, 1_001]], "before any walk nothing without a row comes back")
        let tie = ListeningStore.lateAdoption(legacy: ["rss:r:row": [99, 1_000]], table: table, lastWalkMs: nil)
        #expect(tie.isEmpty, "on a tie the row wins")
    }
}
#endif
