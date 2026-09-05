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

    @Test("Diff: gleich ist leer; neu und geaendert sind Upserts; weg ist eine Entfernung")
    func diffNamesWhatChanged() {
        let before = ["a": 1, "b": 2, "c": 3]
        #expect(KeyedRowDiff.compute(previous: before, current: before).isEmpty)
        let diff = KeyedRowDiff.compute(previous: before, current: ["a": 1, "b": 20, "d": 4])
        #expect(diff.upserted == ["b": 20, "d": 4])
        #expect(diff.removed == ["c"])
    }

    @Test("Ersetzen, Diff anwenden, Zuruecklesen ueber Actor und Leser; keine Zeilen = nil")
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
        let reader = try database.readerNow()
        #expect(KeyedRowStore<PodcastListenLog.Entry>.loadNow(table: .listenLog, reader: reader) == ["rss:x": later, "rss:z": entry])
        #expect(KeyedRowStore<Int>.loadNow(table: .statsDay, reader: reader) == nil, "a table that does not exist yet reads as nil")
        // A second store on the same connection, another table, another value type.
        let days = try await KeyedRowStore<Int>(connection: try database.connection(), table: .statsDay)
        try await days.replaceAll(["2026-09-05": 600])
        #expect(try await days.count() == 1)
        #expect(KeyedRowStore<Int>.loadNow(table: .statsDay, reader: try database.readerNow()) == ["2026-09-05": 600])
    }
}
#endif
