// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The playback context as one row in `maer.sqlite`: a fresh install writes
/// the row and never a document; the document of the builds before is
/// poured into the row once and set aside (`.migrated`, out of the backup);
/// from then on the row is the truth, a cleared context is an empty row and
/// no document is poured over it again. Every case runs over a database
/// file and a directory of its own.
@MainActor
struct PlaybackContextRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var document: URL { directory.appendingPathComponent("playback_context.json") }
        func store() -> PlaybackContext {
            PlaybackContext(fileURL: document, persists: true, database: database)
        }
        func row() throws -> PlaybackContext.Stored? {
            guard let reader = try database.readerNow() else { return nil }
            return try KeyedRowStore<PlaybackContext.Stored>.loadNow(table: .playbackContext, reader: reader)
                .rows[PlaybackContext.rowKey]
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    @Test("eine frische Installation schreibt die Zeile und nie ein Dokument; ein geleerter Kontext bleibt eine leere Zeile")
    func freshInstallWritesTheRow() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        #expect(store.isEmpty)
        store.replace(ids: ["a", "b"], source: "Album A")
        await store.awaitPendingWrites()
        #expect(try home.row() == PlaybackContext.Stored(version: 1, sourceTitle: "Album A", ids: ["a", "b"]))
        #expect(!FileManager.default.fileExists(atPath: home.document.path), "the document is history")
        // A second start reads the row, source and all.
        let again = home.store()
        #expect(again.ids == ["a", "b"])
        #expect(again.sourceTitle == "Album A")
        again.clear()
        await again.awaitPendingWrites()
        #expect(try home.row() == PlaybackContext.Stored(version: 1, sourceTitle: nil, ids: []),
                "cleared is an empty row, not a missing one")
        // A document dropped beside an empty row is never poured over it.
        try JSONEncoder().encode(PlaybackContext.Stored(version: 1, sourceTitle: "Ghost", ids: ["ghost"]))
            .write(to: home.document)
        let third = home.store()
        #expect(third.isEmpty, "the row wins, even empty")
        #expect(FileManager.default.fileExists(atPath: home.document.path), "and the stale copy is left alone")
    }

    @Test("das Dokument wird einmal in die Zeile gegossen und beiseitegelegt; danach zaehlt nur die Zeile")
    func theDocumentIsPouredOnceAndSetAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try JSONEncoder().encode(PlaybackContext.Stored(version: 1, sourceTitle: "Album X", ids: ["x", "y"]))
            .write(to: home.document)

        let store = home.store()
        #expect(store.ids == ["x", "y"])
        #expect(store.sourceTitle == "Album X")
        await store.awaitPendingWrites()
        #expect(try home.row() == PlaybackContext.Stored(version: 1, sourceTitle: "Album X", ids: ["x", "y"]))
        let aside = home.document.appendingPathExtension("migrated")
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: aside.path), "set aside, never deleted")
        #expect(DocumentMigration.isExcludedFromBackup(aside))

        // A change is a diff on the one row.
        store.remove("x")
        await store.awaitPendingWrites()
        #expect(try home.row() == PlaybackContext.Stored(version: 1, sourceTitle: "Album X", ids: ["y"]))
        // A stale copy beside the row changes nothing on the next start.
        try JSONEncoder().encode(PlaybackContext.Stored(version: 1, sourceTitle: "Ghost", ids: ["ghost"]))
            .write(to: home.document)
        let again = home.store()
        #expect(again.ids == ["y"], "the row wins")
        #expect(again.sourceTitle == "Album X")
    }

    @Test("ein unlesbares Dokument ist nicht leer: es bleibt beiseite, die Zeile beginnt frisch; eine Instanz ohne Persistenz fasst nichts an")
    func anUnreadableDocumentIsKeptAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try Data("not json".utf8).write(to: home.document)

        // Not persisting: neither the document nor the database is touched.
        let memory = PlaybackContext(fileURL: home.document)
        #expect(memory.isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.document.path), "left as it was")
        // Asked on disk, not through `readerNow()`: that opens the writer
        // first and would create the very file it is asked about.
        #expect(!FileManager.default.fileExists(atPath: home.directory.appendingPathComponent("maer.sqlite").path),
                "no database file was created")

        let store = home.store()
        #expect(store.isEmpty, "unreadable is not a context")
        store.replace(ids: ["n"], source: "New")
        await store.awaitPendingWrites()
        #expect(try home.row() == PlaybackContext.Stored(version: 1, sourceTitle: "New", ids: ["n"]))
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: home.document.appendingPathExtension("corrupt").path),
                "the unreadable file is preserved by the seam, never migrated")
    }
}
#endif
