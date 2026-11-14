// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The queue as one row in `maer.sqlite`: the row is the truth, and an
/// emptied queue is an empty row. Every case runs over a database file and
/// a directory of its own.
@MainActor
struct PlayQueueRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        func store() -> PlayQueue {
            PlayQueue(persists: true, database: database)
        }
        func row() throws -> [String]? {
            guard let reader = try database.readerNow() else { return nil }
            return try KeyedRowStore<[String]>.loadNow(table: .playQueue, reader: reader).rows[PlayQueue.rowKey]
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    @Test("a fresh install writes the row; an emptied queue stays an empty row")
    func freshInstallWritesTheRow() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        #expect(store.isEmpty)
        store.playLast("a"); store.playLast("b")
        await store.awaitPendingWrites()
        #expect(try home.row() == ["a", "b"])
        // A second start reads the row.
        let again = home.store()
        #expect(again.ids == ["a", "b"])
        again.clear()
        await again.awaitPendingWrites()
        #expect(try home.row() == [], "emptied is an empty row, not a missing one")
        #expect(home.store().ids.isEmpty, "the empty row reads back as empty")
    }

    /// A start that could not read the row holds only what the run adds;
    /// the first save reads the row and keeps it behind that, instead of
    /// replacing it. A memory database has no synchronous reader, so its
    /// start read fails while the writer works.
    @Test("after a start that did not read the row, the first save does not replace it")
    func aStartThatDidNotReadReplacesNothing() async throws {
        let database = MaerDatabase(path: ":memory:")
        let rows = try await KeyedRowStore<[String]>(connection: try database.connection(), table: .playQueue)
        try await rows.apply(previous: [:], current: [PlayQueue.rowKey: ["a", "b"]])
        let store = PlayQueue(persists: true, database: database)
        #expect(store.isEmpty, "the precondition: the start did not read the row")
        store.playLast("c")
        store.playLast("a")
        await store.awaitPendingWrites()
        #expect(try await rows.load().rows[PlayQueue.rowKey] == ["c", "a", "b"],
                "the first save replaced the row it never read")
        #expect(store.ids == ["c", "a", "b"])
    }

    @Test("the rule after an unread start: what the run added first, then the row without duplicate and without twin")
    func theRuleAfterAnUnreadStart() {
        let twins: (String) -> [String] = { $0 == "rss:x" ? ["rss:x", "abspod:x"] : [$0] }
        #expect(PlayQueue.afterUnreadStart(run: ["c", "rss:x"], read: ["a", "abspod:x", "c", "radio:r", "b"],
                                           equivalents: twins) == ["c", "rss:x", "a", "b"])
        #expect(PlayQueue.afterUnreadStart(run: [], read: ["a"], equivalents: { [$0] }) == ["a"])
    }
}
#endif
