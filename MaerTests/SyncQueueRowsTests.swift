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

    /// A server that answers the writes of three titles with 404, 403 and a
    /// passing failure.
    private final class RefusingServer: ProgressSyncAPI {
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
            switch itemId {
            case "gone": throw APIError.http(404, "gone")
            case "forbidden": throw APIError.http(403, "forbidden")
            default: throw APIError.http(503, "busy")
            }
        }
    }

    @Test("die Schlange laesst nur einen Titel fallen, den der Server nicht kennt; 403 und ein voruebergehender Fehler bleiben")
    func onlyAnAbsentTitleLeavesTheQueue() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let queue = SyncQueue(storage: home.storage())
        for id in ["gone", "forbidden", "busy"] {
            await queue.enqueue(itemId: id, currentTime: 900, duration: 900, isFinished: true)
        }
        let server = RefusingServer()
        await queue.flush { _ in ProgressTarget(key: "server", client: server) }
        #expect(!queue.hasPendingUpdate(itemId: "gone"), "a title the server does not know is sent again on every flush")
        #expect(queue.hasPendingUpdate(itemId: "forbidden"), "a 403, maybe from in front of the server, lost its entry")
        #expect(queue.hasPendingUpdate(itemId: "busy"), "a passing failure lost its entry")
        #expect(Set(try home.rows().keys) == ["busy", "forbidden"])
    }
}
#endif
