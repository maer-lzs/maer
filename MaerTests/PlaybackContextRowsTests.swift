// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The playback context as one row in `maer.sqlite`: the row is the truth,
/// and a cleared context is an empty row. Every case runs over a database
/// file and a directory of its own.
@MainActor
struct PlaybackContextRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        func store() -> PlaybackContext {
            PlaybackContext(persists: true, database: database)
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

    @Test("a fresh install writes the row; an emptied context stays an empty row")
    func freshInstallWritesTheRow() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        #expect(store.isEmpty)
        store.replace(ids: ["a", "b"], source: "Album A")
        await store.awaitPendingWrites()
        #expect(try home.row() == PlaybackContext.Stored(version: 1, sourceTitle: "Album A", ids: ["a", "b"]))
        // A second start reads the row, source and all.
        let again = home.store()
        #expect(again.ids == ["a", "b"])
        #expect(again.sourceTitle == "Album A")
        again.clear()
        await again.awaitPendingWrites()
        #expect(try home.row() == PlaybackContext.Stored(version: 1, sourceTitle: nil, ids: []),
                "cleared is an empty row, not a missing one")
        #expect(home.store().isEmpty, "the empty row reads back as empty")
    }
}
#endif
