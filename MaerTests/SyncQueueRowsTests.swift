// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The offline progress queue as rows in `maer.sqlite`, one per title: the
/// queue reads itself back right after every write, and a removed entry
/// does not come back on the next start. Every case runs over a database
/// file and a directory of its own.
@MainActor
struct SyncQueueRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        func storage() -> SyncQueueRowStorage {
            SyncQueueRowStorage(database: database)
        }
        func rows() throws -> [String: SyncQueue.PendingUpdate] {
            guard let reader = try database.readerNow() else { return [:] }
            return try KeyedRowStore<SyncQueue.PendingUpdate>.loadNow(table: .pendingSync, reader: reader).rows
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("syncqueue-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    @Test("eine frische Installation schreibt Zeilen; ein Eintrag ist gelandet, wenn enqueue zurueckkehrt")
    func freshInstallWritesRows() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let storage = home.storage()
        let queue = SyncQueue(storage: storage)
        #expect(queue.allPending().isEmpty)
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        await queue.enqueue(itemId: "b", currentTime: 5, duration: 50, isFinished: true)
        #expect(queue.hasPendingUpdate(itemId: "a"))
        // The contract: the rows hold the entry the moment the call returns,
        // without waiting on the storage. A kill from here on loses nothing.
        let rows = try home.rows()
        #expect(Set(rows.keys) == ["a", "b"])
        #expect(rows["a"]?.currentTime == 100)
        #expect(rows["b"]?.isFinished == true)

        // A second start reads the rows, values and all.
        let again = SyncQueue(storage: home.storage())
        #expect(again.allPending() == queue.allPending())
    }

    @Test("ein entfernter Eintrag verlaesst die Zeile, bevor der naechste Start ihn zurueckholen koennte")
    func aRemovedEntryLeavesTheRows() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let storage = home.storage()
        let queue = SyncQueue(storage: storage)
        await queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        await queue.enqueue(itemId: "b", currentTime: 5, duration: 50, isFinished: true)
        let seen = await queue.pendingUpdate(itemId: "a")
        await queue.remove(itemId: "a", ifStill: seen)
        // Landed when the call returned, like the enqueue.
        #expect(Set(try home.rows().keys) == ["b"], "a sent entry must not be sent again after a restart")
        let again = SyncQueue(storage: home.storage())
        #expect(Set(again.allPending().keys) == ["b"])
    }
}
#endif
