// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The index of imported local files as rows in `maer.sqlite`, one per
/// item: the document of the builds before is poured into the rows once and
/// set aside (`.migrated`, out of the backup); from then on the rows are the
/// truth, newest first; a deleted item leaves its row; an unreadable
/// document stays `.corrupt` and is never poured. Every case runs over a
/// database file and a directory of its own.
@MainActor
struct LocalLibraryRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var document: URL { directory.appendingPathComponent("local_library.json") }
        func store() -> LocalLibrary {
            LocalLibrary(database: database, ablage: Ablage(directory: directory),
                         audioDir: directory.appendingPathComponent("LocalAudio", isDirectory: true))
        }
        func rows() throws -> [String: LocalLibrary.Entry] {
            guard let reader = try database.readerNow() else { return [:] }
            return try KeyedRowStore<LocalLibrary.Entry>.loadNow(table: .localLibrary, reader: reader).rows
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("locallib-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    private func entry(_ n: Int, addedAt: Double) -> LocalLibrary.Entry {
        LocalLibrary.Entry(id: "local:item-\(n)", title: "Book \(n)", author: nil, duration: 100,
                           addedAt: addedAt, trackFiles: ["a.m4a"], chapters: [], hasCover: false)
    }

    @Test("das Dokument wird einmal in die Zeilen gegossen und beiseitegelegt; danach zaehlen nur die Zeilen, neueste zuerst")
    func theDocumentIsPouredOnceAndSetAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let older = entry(1, addedAt: 1_000)
        let newer = entry(2, addedAt: 2_000)
        try JSONEncoder().encode([older, newer]).write(to: home.document)

        let store = home.store()
        #expect(store.entries.map(\.id) == [newer.id, older.id], "newest first, whatever the document's order")
        await store.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == [older.id, newer.id])
        let aside = home.document.appendingPathExtension("migrated")
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: aside.path), "set aside, never deleted")
        #expect(DocumentMigration.isExcludedFromBackup(aside))

        // A deleted item leaves its row.
        store.delete(id: older.id)
        await store.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == [newer.id])
        // A stale copy beside the rows changes nothing on the next start.
        try JSONEncoder().encode([entry(9, addedAt: 9_000)]).write(to: home.document)
        let again = home.store()
        #expect(again.entries.map(\.id) == [newer.id], "the rows win")
        #expect(again.entries.first?.title == "Book 2")
        #expect(FileManager.default.fileExists(atPath: home.document.path), "and the stale copy is left alone")
    }

    @Test("ein unlesbares Dokument ist nicht leer: es bleibt beiseite, die Zeilen beginnen frisch und nichts wird eingegossen")
    func anUnreadableDocumentIsKeptAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try Data("not json".utf8).write(to: home.document)
        let store = home.store()
        #expect(store.entries.isEmpty, "unreadable is not a library")
        await store.awaitPendingWrites()
        #expect(try home.rows().isEmpty, "nothing was poured")
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: home.document.appendingPathExtension("corrupt").path),
                "the unreadable file is preserved by the seam, never migrated")
    }
}
#endif
