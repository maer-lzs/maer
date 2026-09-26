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
        #expect(counting.array(forKey: AppStorageKeys.localPosition("rss:stock:a")) as? [Double]
                == ListeningStore.backup("rss:stock:a", in: counting), "the defaults are still written")
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

    @Test("Niemand liest localPosition. oder flushedPosition. aus den Voreinstellungen, ausser dem Laden des Bestands", .needsTheSources)
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
    }
}
#endif
