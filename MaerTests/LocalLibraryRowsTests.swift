// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The index of imported local files as rows in `maer.sqlite`, one per
/// item: the rows are the truth, read newest first, and a deleted item
/// leaves its row. Every case runs over a database file and a directory of
/// its own.
@MainActor
struct LocalLibraryRowsTests {
    private struct Home {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        func store() -> LocalLibrary {
            LocalLibrary(database: database,
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

    @Test("the rows are read newest first; a deleted entry leaves its row")
    func theRowsReadNewestFirst() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let older = entry(1, addedAt: 1_000)
        let newer = entry(2, addedAt: 2_000)
        let rows = try await KeyedRowStore<LocalLibrary.Entry>(connection: try home.database.connection(), table: .localLibrary)
        _ = try await rows.replaceAll([older.id: older, newer.id: newer])

        let store = home.store()
        #expect(store.entries.map(\.id) == [newer.id, older.id], "newest first, whatever the rows' order")
        store.delete(id: older.id)
        await store.awaitPendingWrites()
        #expect(Set(try home.rows().keys) == [newer.id])
        let again = home.store()
        #expect(again.entries.map(\.id) == [newer.id])
        #expect(again.entries.first?.title == "Book 2")
    }

    // MARK: A file that cannot be copied is counted, not dropped

    @Test("a file that cannot be copied is counted instead of silently skipped")
    func aFailedCopyIsCounted() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        let good = home.directory.appendingPathComponent("01 good.mp3")
        try (Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 400)).write(to: good)
        // A source that is gone by the time the copy runs, the way a file
        // provider can take a picked file away.
        let gone = home.directory.appendingPathComponent("02 gone.mp3")
        let failed = await store.importFiles([good, gone])
        #expect(failed == 1, "gezaehlt: \(failed)")
        #expect(store.entries.count == 1 && store.entries.first?.trackFiles == ["01 good.mp3"],
                "what arrived becomes the entry")
    }

    @Test("if no file arrives, no entry and no empty folder arise")
    func nothingArrivedLeavesNothing() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.directory) }
        let store = home.store()
        let missing = ["a.mp3", "b.m4b"].map { home.directory.appendingPathComponent($0) }
        let failed = await store.importFiles(missing)
        #expect(failed == 2)
        #expect(store.entries.isEmpty)
        let audio = home.directory.appendingPathComponent("LocalAudio", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: audio.path)) ?? []
        #expect(folders.isEmpty, "no empty folder left behind: \(folders)")
    }

    @Test("the import page shows how many files were not taken over", .needsTheSources)
    func theImportPageSaysHowManyFailed() throws {
        let page = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LocalFilesView.swift"),
                              encoding: .utf8)
        #expect(page.contains("notTakenOver = await library.importFiles(urls)"), "the page keeps the count")
        #expect(page.contains("Files not taken over: \\(notTakenOver)"), "and says it")
    }
}
#endif
