// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Siri book query reads the rows first and the document only when
/// the rows hold nothing. The arm that mattered: after the migration the
/// document is set aside and the rows hold the library, and the query
/// must see the same books the library shows.
struct ShortcutBooksTests {
    private func item(_ id: String, title: String?, author: String? = "A") -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: author, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 10, chapters: nil, tracks: nil),
            addedAt: 1)
    }

    private func missingFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).json")
    }

    @Test("nach dem Umzug: die Zeilen tragen, das Dokument ist weg, der Kurzbefehl findet die Buecher")
    func rowsCarryAfterTheMigration() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        _ = try await store.replaceAll(LibraryDiskCache(items: [item("a", title: "Alpha"), item("b", title: "Beta"),
                                                                item("c", title: nil)],
                                                        progress: [:]))
        let books = await BookQuery.books(rows: store, fallback: missingFile())
        #expect(books.map(\.title) == ["Alpha", "Beta"], "a title is what makes a book; the one without stays out")
        #expect(books.first?.author == "A")
    }

    @Test("vor dem Umzug: leere Zeilen, das Dokument traegt noch")
    func theDocumentCarriesBeforeTheMigration() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let legacy = """
        {"items":[{"id":"x","media":{"metadata":{"title":"From the file","authorName":"F"}}}],"progress":{}}
        """
        try Data(legacy.utf8).write(to: file)
        let books = await BookQuery.books(rows: store, fallback: file)
        #expect(books.map(\.title) == ["From the file"])
        let noRows = await BookQuery.books(rows: nil, fallback: file)
        #expect(noRows.map(\.title) == ["From the file"], "without rows the document is read")
    }

    @Test("weder Zeilen noch Dokument: keine Buecher, kein Fehler")
    func nothingIsNothing() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        #expect(await BookQuery.books(rows: store, fallback: missingFile()).isEmpty)
        #expect(await BookQuery.books(rows: nil, fallback: missingFile()).isEmpty)
    }
}
#endif
