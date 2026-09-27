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

    @Test("Schritt 2: der erste Start zieht den Altbestand in die Tabelle, setzt die Marke und raeumt die alten Schluessel erst nach voller Deckung")
    func theFirstStartMovesTheStock() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.onWrite = nil
            ListeningStore.onFlushedWrite = nil
        }
        // The old keys, as a build before this one left them.
        defaults.set([300.0, 1_000.0, 600.0], forKey: "localPosition.rss:move:a")
        defaults.set([0.0, 2_000.0], forKey: "localPosition.rss:move:tomb")
        defaults.set([300.0, 1_500.0], forKey: "flushedPosition.rss:move:a")
        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        #expect(ListeningStore.isMoved(in: defaults), "the marker, once the rows hold the stock")
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

    @Test("Schritt 2: fehlt ein alter Eintrag in der Tabelle, bleiben die alten Schluessel stehen")
    func aMissingEntryKeepsTheOldKeys() async throws {
        let (defaults, name) = suite()
        let (store, loadNow, file) = try await fileTable()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: file)
            ListeningStore.onWrite = nil
            ListeningStore.onFlushedWrite = nil
        }
        // Moved already, but an old key stands that the table does not hold.
        try await store.upsert(Stand(itemId: "rss:keep:a", position: 10, updatedAtMs: 1_000, duration: nil))
        defaults.set(true, forKey: ListeningStore.movedKey)
        defaults.set([10.0, 1_000.0], forKey: "localPosition.rss:keep:a")
        defaults.set([20.0, 1_000.0], forKey: "localPosition.rss:keep:lost")
        let mirror = StandMirror(store: store, loadNow: loadNow)
        mirror.start(defaults: defaults)
        await mirror.awaitPendingWrites()
        #expect(defaults.object(forKey: "localPosition.rss:keep:lost") as? [Double] == [20, 1_000],
                "an old entry the table lacks keeps every old key")
        #expect(defaults.object(forKey: "localPosition.rss:keep:a") != nil, "none goes while one is missing")
        #expect(ListeningStore.backup("rss:keep:a", in: defaults) == [10, 1_000], "the table is the stock")
    }

    @Test("Schritt 2: die Deckung, je Eintrag gleich oder neuer, ein Grabstein zaehlt wie jeder Eintrag")
    func theCoverageRule() {
        let legacy = ListeningStore.Stock(backups: ["a": [10, 1_000], "tomb": [0, 2_000], "radio:x": [5, 1],
                                                    "short": [1]],
                                          flushed: ["a": [10, 1_500]])
        let same = ListeningStore.Stock(backups: ["a": [10, 1_000], "tomb": [0, 2_000]], flushed: ["a": [10, 1_500]])
        #expect(ListeningStore.legacyCovered(legacy: legacy, table: same).covered,
                "equal entries cover; a live stream and a short array carry nothing to lose")
        let newer = ListeningStore.Stock(backups: ["a": [99, 5_000], "tomb": [7, 3_000]], flushed: ["a": [20, 1_600]])
        #expect(ListeningStore.legacyCovered(legacy: legacy, table: newer).covered, "newer entries cover")
        let older = ListeningStore.Stock(backups: ["a": [99, 500], "tomb": [0, 2_000]], flushed: ["a": [10, 1_500]])
        #expect(ListeningStore.legacyCovered(legacy: legacy, table: older).missing == ["a"], "an older entry does not")
        let lacking = ListeningStore.Stock(backups: ["a": [10, 1_000]], flushed: [:])
        #expect(ListeningStore.legacyCovered(legacy: legacy, table: lacking).missing == ["flushed a", "tomb"],
                "a missing tombstone and a missing pushed witness each block")
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
            ListeningStore.onWrite = nil
            ListeningStore.onFlushedWrite = nil
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
}
#endif
