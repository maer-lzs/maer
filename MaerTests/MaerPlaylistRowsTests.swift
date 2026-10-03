// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Mär playlists live as rows, one per list, and the rows are the
/// truth. Every case runs over a database file and a directory of its own.
@MainActor
struct MaerPlaylistRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        func store() -> MaerPlaylists { MaerPlaylists(database: database) }
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

    @Test("eine frische Installation schreibt Zeilen")
    func freshInstallWritesRows() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        #expect(store.playlists.isEmpty)
        let list = store.create(name: "Mix", itemIds: ["jam:1", "lva:x"])
        await store.awaitPendingWrites()
        #expect(try home.rows().keys.sorted() == [list.id])
        // A second start reads the rows.
        let again = home.store()
        #expect(again.playlists.map(\.id) == [list.id])
        #expect(again.playlist(id: list.id)?.itemIds == ["jam:1", "lva:x"])
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
