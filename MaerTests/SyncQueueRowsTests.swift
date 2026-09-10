// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The offline progress queue as rows in `maer.sqlite`, one per title: a
/// fresh install writes rows and never a document; the queue reads itself
/// back right after every write; a removed entry does not come back on the
/// next start; the document of the builds before is poured into the rows
/// once and set aside (`.migrated`, out of the backup); an unreadable
/// document stays `.corrupt` and is never poured. Every case runs over a
/// database file and a directory of its own.
@MainActor
struct SyncQueueRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var document: URL { directory.appendingPathComponent("pending_sync.json") }
        func storage() -> SyncQueueRowStorage {
            SyncQueueRowStorage(database: database, ablage: Ablage(directory: directory))
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

    @Test("eine frische Installation schreibt Zeilen und nie ein Dokument; die Queue liest sich sofort zurueck")
    func freshInstallWritesRows() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let storage = home.storage()
        let queue = SyncQueue(storage: storage)
        #expect(!queue.hasPendingUpdates)
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        queue.enqueue(itemId: "b", currentTime: 5, duration: 50, isFinished: true)
        // Synchronous by contract: the answer is there before any row landed.
        #expect(queue.hasPendingUpdate(itemId: "a"))
        await storage.awaitPendingWrites()
        let rows = try home.rows()
        #expect(Set(rows.keys) == ["a", "b"])
        #expect(rows["a"]?.currentTime == 100)
        #expect(rows["b"]?.isFinished == true)
        #expect(!FileManager.default.fileExists(atPath: home.document.path), "the document is history")

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
        queue.enqueue(itemId: "a", currentTime: 100, duration: 1000, isFinished: false)
        queue.enqueue(itemId: "b", currentTime: 5, duration: 50, isFinished: true)
        queue.remove(itemId: "a")
        await storage.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == ["b"], "a sent entry must not be sent again after a restart")
        let again = SyncQueue(storage: home.storage())
        #expect(Set(again.allPending().keys) == ["b"])
    }

    @Test("das Dokument wird einmal in die Zeilen gegossen und beiseitegelegt; danach zaehlen nur die Zeilen")
    func theDocumentIsPouredOnceAndSetAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let stock: [String: SyncQueue.PendingUpdate] = [
            "x": .init(currentTime: 10, duration: 100, isFinished: false, queuedAt: 1),
            "y": .init(currentTime: 20, duration: 200, isFinished: true)
        ]
        try JSONEncoder().encode(stock).write(to: home.document)

        let storage = home.storage()
        let queue = SyncQueue(storage: storage)
        #expect(queue.allPending() == stock)
        await storage.awaitPendingWrites()
        #expect(try home.rows() == stock)
        let aside = home.document.appendingPathExtension("migrated")
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: aside.path), "set aside, never deleted")
        #expect(DocumentMigration.isExcludedFromBackup(aside))

        // A change is a diff on the rows: one upsert, one removal.
        queue.enqueue(itemId: "z", currentTime: 1, duration: 2, isFinished: false)
        queue.remove(itemId: "x")
        await storage.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == ["y", "z"])
        // A stale copy beside the rows changes nothing on the next start.
        try JSONEncoder().encode(["ghost": SyncQueue.PendingUpdate(currentTime: 0, duration: 0, isFinished: false)])
            .write(to: home.document)
        let again = SyncQueue(storage: home.storage())
        #expect(Set(again.allPending().keys) == ["y", "z"], "the rows win")
        #expect(FileManager.default.fileExists(atPath: home.document.path), "and the stale copy is left alone")
    }

    @Test("ein unlesbares Dokument ist nicht leer: es bleibt beiseite, die Zeilen beginnen frisch")
    func anUnreadableDocumentIsKeptAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try Data("not json".utf8).write(to: home.document)
        let storage = home.storage()
        let queue = SyncQueue(storage: storage)
        #expect(!queue.hasPendingUpdates, "unreadable is not a queue")
        queue.enqueue(itemId: "n", currentTime: 1, duration: 2, isFinished: false)
        await storage.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == ["n"])
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: home.document.appendingPathExtension("corrupt").path),
                "the unreadable file is preserved by the seam, never migrated")
    }
}
#endif
