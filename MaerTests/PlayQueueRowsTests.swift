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

    @Test("eine frische Installation schreibt die Zeile; eine geleerte Warteschlange bleibt eine leere Zeile")
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
}
#endif
