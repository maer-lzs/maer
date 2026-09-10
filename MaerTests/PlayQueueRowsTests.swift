// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The queue as one row in `maer.sqlite`: a fresh install writes the row
/// and never a document; the document of the builds before is poured into
/// the row once and set aside (`.migrated`, out of the backup); from then
/// on the row is the truth, an emptied queue is an empty row and no
/// document is poured over it again. Every case runs over a database file
/// and a directory of its own.
@MainActor
struct PlayQueueRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var document: URL { directory.appendingPathComponent("play_queue.json") }
        var legacy: URL { directory.appendingPathComponent("podcast_queue.json") }
        func store() -> PlayQueue {
            PlayQueue(fileURL: document, migrateFrom: legacy, persists: true, database: database)
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

    @Test("eine frische Installation schreibt die Zeile und nie ein Dokument; eine geleerte Warteschlange bleibt eine leere Zeile")
    func freshInstallWritesTheRow() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        #expect(store.isEmpty)
        store.playLast("a"); store.playLast("b")
        await store.awaitPendingWrites()
        #expect(try home.row() == ["a", "b"])
        #expect(!FileManager.default.fileExists(atPath: home.document.path), "the document is history")
        // A second start reads the row.
        let again = home.store()
        #expect(again.ids == ["a", "b"])
        again.clear()
        await again.awaitPendingWrites()
        #expect(try home.row() == [], "emptied is an empty row, not a missing one")
        // A document dropped beside an empty row is never poured over it.
        try JSONEncoder().encode(["ghost"]).write(to: home.document)
        let third = home.store()
        #expect(third.ids.isEmpty, "the row wins, even empty")
        #expect(FileManager.default.fileExists(atPath: home.document.path), "and the stale copy is left alone")
    }

    @Test("das Dokument wird einmal in die Zeile gegossen und beiseitegelegt; danach zaehlt nur die Zeile")
    func theDocumentIsPouredOnceAndSetAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try JSONEncoder().encode(["x", "y"]).write(to: home.document)

        let store = home.store()
        #expect(store.ids == ["x", "y"])
        await store.awaitPendingWrites()
        #expect(try home.row() == ["x", "y"])
        let aside = home.document.appendingPathExtension("migrated")
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: aside.path), "set aside, never deleted")
        #expect(DocumentMigration.isExcludedFromBackup(aside))

        // A change is a diff on the one row.
        store.playNext("z")
        await store.awaitPendingWrites()
        #expect(try home.row() == ["z", "x", "y"])
        // A stale copy beside the row changes nothing on the next start.
        try JSONEncoder().encode(["ghost"]).write(to: home.document)
        let again = home.store()
        #expect(again.ids == ["z", "x", "y"], "the row wins")
    }

    @Test("die Warteschlange der Builds davor wird nur gelesen, wenn das eigene Dokument fehlt")
    func theLegacyQueueYieldsToTheCurrentDocument() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try JSONEncoder().encode(["old"]).write(to: home.legacy)
        try JSONEncoder().encode(["new"]).write(to: home.document)
        let store = home.store()
        #expect(store.ids == ["new"])
        await store.awaitPendingWrites()
        #expect(try home.row() == ["new"])
        #expect(FileManager.default.fileExists(atPath: home.document.appendingPathExtension("migrated").path))
        #expect(FileManager.default.fileExists(atPath: home.legacy.path), "the podcast-only file was not read, so it is left alone")
    }
}
#endif
