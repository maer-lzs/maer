// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The keyed store: a dictionary goes in and comes back, a write is the
/// diff of two dictionaries, the init-time reader sees what the actor
/// wrote, and "no rows" reads as nil.
struct KeyedRowStoreTests {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("keyed-\(UUID().uuidString).sqlite").path
    }

    @Test("Diff: equal is empty; new and changed are upserts; gone is a removal")
    func diffNamesWhatChanged() {
        let before = ["a": 1, "b": 2, "c": 3]
        #expect(KeyedRowDiff.compute(previous: before, current: before).isEmpty)
        let diff = KeyedRowDiff.compute(previous: before, current: ["a": 1, "b": 20, "d": 4])
        #expect(diff.upserted == ["b": 20, "d": 4])
        #expect(diff.removed == ["c"])
    }

    @Test("Replace, apply diff, read back through actor and reader; no rows = nil")
    func roundTripThroughActorAndReader() async throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = MaerDatabase(path: path)
        let store = try await KeyedRowStore<PodcastListenLog.Entry>(connection: try database.connection(), table: .listenLog)
        #expect(try await store.loadAll() == nil, "no rows is no log")
        let entry = PodcastListenLog.Entry(guid: "rss:x", episodeTitle: "E", showTitle: "S", feedURL: "https://example.org/f.xml",
                                           duration: 100, playedAt: 1_700_000_000_000, unplayedAt: nil, synthesizedAt: false)
        var later = entry
        later.unplayedAt = 1_700_000_001_000
        #expect(try await store.replaceAll(["rss:x": entry, "rss:y": later]) == 2)
        let written = try await store.apply(previous: ["rss:x": entry, "rss:y": later],
                                            current: ["rss:x": later, "rss:z": entry])
        #expect(written.upserted == 2 && written.removed == 1)
        #expect(try await store.loadAll() == ["rss:x": later, "rss:z": entry])
        // The init-time reader sees the same rows through a connection of its own.
        let reader = try #require(try database.readerNow())
        #expect(try KeyedRowStore<PodcastListenLog.Entry>.loadNow(table: .listenLog, reader: reader).rows == ["rss:x": later, "rss:z": entry])
        #expect(try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: reader).rows == [:], "a table that does not exist yet reads as empty")
        // A second store on the same connection, another table, another value type.
        let days = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        try await days.replaceAll(["2026-09-05": 600])
        #expect(try await days.count() == 1)
        #expect(try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: try #require(try database.readerNow())).rows == ["2026-09-05": 600])
        // A row nobody can read is counted, and the base it yields is
        // unknown, never fresh: the first write must not remove it.
        try await database.connection().run("INSERT INTO stats_day (key, payload) VALUES (?, ?)",
                                            [.text("broken"), .blob(Data("nonsense".utf8))])
        let load = try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: try #require(try database.readerNow()))
        #expect(load.rows == ["2026-09-05": 600] && load.skipped == 1)
        if case .unknown = RowBase<[String: Int]>.afterLoad(rows: load.rows, skipped: load.skipped) {} else {
            Issue.record("a skipped row must leave the rows unknown")
        }
    }

    /// "Nothing there" and "could not read" are two things: a file that is
    /// no database THROWS at the reader, it never reads as empty rows.
    @Test("A read error is no empty stock: the reader throws")
    func unreadableFileThrows() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("this is not a database, just bytes that fill the header".utf8).write(to: URL(fileURLWithPath: path))
        let reader = try SQLiteReader(path: path)
        #expect(throws: (any Error).self) {
            try KeyedRowStore<Int>.loadNow(table: .statsDay, reader: reader)
        }
    }
}
#endif
