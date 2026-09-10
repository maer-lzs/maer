// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Mär playlists live as rows, one per list. The document is read only
/// when the rows hold nothing, poured into them once and set aside as
/// `.migrated`, out of the backup; from then on the rows are the truth and
/// a document beside them is never read again. Every case runs over a
/// database file and a directory of its own.
@MainActor
struct MaerPlaylistRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var ablage: Ablage { Ablage(directory: directory) }
        var document: URL { directory.appendingPathComponent("maer_playlists.json") }
        func store() -> MaerPlaylists { MaerPlaylists(database: database, ablage: ablage) }
        func rows() throws -> [String: MaerPlaylists.Playlist] {
            guard let reader = try database.readerNow() else { return [:] }
            return try KeyedRowStore<MaerPlaylists.Playlist>.loadNow(table: .maerPlaylist, reader: reader).rows
        }
    }

    private func home() throws -> Home {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playlist-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Home(directory: directory)
    }

    /// The document as the builds before the rows wrote it: an array of
    /// lists, the older entry without the fields that came later.
    private static let oldDocument = """
    [
      {"id": "zeta", "name": "Zeta", "updatedAt": 1700000000, "itemIds": ["jam:1", "lva:x"],
       "titles": {"jam:1": "Sonata"}, "removed": {"jam:9": 1699999999}, "added": {"jam:1": 1700000000}},
      {"id": "alpha", "name": "alpha", "updatedAt": 1600000000, "itemIds": ["lv:176"]}
    ]
    """

    @Test("eine frische Installation schreibt Zeilen und nie ein Dokument")
    func freshInstallWritesRows() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        #expect(store.playlists.isEmpty)
        let list = store.create(name: "Mix", itemIds: ["jam:1", "lva:x"])
        await store.awaitPendingWrites()
        #expect(try home.rows().keys.sorted() == [list.id])
        #expect(!FileManager.default.fileExists(atPath: home.document.path), "the document is history")
        // A second start reads the rows.
        let again = home.store()
        #expect(again.playlists.map(\.id) == [list.id])
        #expect(again.playlist(id: list.id)?.itemIds == ["jam:1", "lva:x"])
    }

    @Test("das Dokument wird einmal in die Zeilen gegossen und beiseitegelegt; danach zaehlen nur die Zeilen")
    func theDocumentIsPouredOnceAndSetAside() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        try Data(Self.oldDocument.utf8).write(to: home.document)

        let store = home.store()
        #expect(store.playlists.map(\.id) == ["zeta", "alpha"], "the document's own order, at the start that migrates")
        #expect(store.playlist(id: "zeta")?.removed == ["jam:9": 1_699_999_999])
        #expect(store.playlist(id: "alpha")?.titles.isEmpty == true, "an entry from before the fields decodes")
        await store.awaitPendingWrites()
        #expect(try home.rows().keys.sorted() == ["alpha", "zeta"])
        let aside = home.document.appendingPathExtension("migrated")
        #expect(!FileManager.default.fileExists(atPath: home.document.path))
        #expect(FileManager.default.fileExists(atPath: aside.path), "set aside, never deleted")
        #expect(DocumentMigration.isExcludedFromBackup(aside))

        // A document beside the rows is never read again: a stale copy
        // with another list changes nothing.
        try Data("""
        [{"id": "ghost", "name": "Ghost", "updatedAt": 1800000000, "itemIds": []}]
        """.utf8).write(to: home.document)
        let again = home.store()
        #expect(again.playlists.map(\.id) == ["alpha", "zeta"], "rows win, in name order")
        #expect(FileManager.default.fileExists(atPath: home.document.path), "and the stale copy is left alone")

        // The rows are the base from here: a change is a diff, a removal leaves the rows.
        let created = again.create(name: "Neu")
        again.delete(playlistId: "zeta")
        await again.awaitPendingWrites()
        #expect(try home.rows().keys.sorted() == ["alpha", created.id].sorted())
    }

    @Test("eine Aenderung schreibt nur die geaenderte Liste; eine Loeschung nimmt die Zeile")
    func aChangeIsADiff() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        let a = store.create(name: "A")
        let b = store.create(name: "B")
        await store.awaitPendingWrites()
        #expect(store.add(itemId: "jam:5", to: b.id, knownTitle: "Fuenf") == .added)
        store.delete(playlistId: a.id)
        await store.awaitPendingWrites()
        let rows = try home.rows()
        #expect(rows.keys.sorted() == [b.id])
        #expect(rows[b.id]?.itemIds == ["jam:5"])
        #expect(rows[b.id]?.titles["jam:5"] == "Fuenf")
    }
}
#endif
