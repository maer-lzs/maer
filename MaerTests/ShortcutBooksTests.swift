// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Siri book query reads the rows, the same books the library shows.
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

    @Test("die Zeilen tragen, der Kurzbefehl findet die Buecher")
    func theRowsCarry() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        _ = try await store.replaceAll(LibraryDiskCache(items: [item("a", title: "Alpha"), item("b", title: "Beta"),
                                                                item("c", title: nil)],
                                                        progress: [:]))
        let books = await BookQuery.books(rows: store)
        #expect(books.map(\.title) == ["Alpha", "Beta"], "a title is what makes a book; the one without stays out")
        #expect(books.first?.author == "A")
    }

    @Test("leere Zeilen oder keine: keine Buecher, kein Fehler")
    func nothingIsNothing() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        #expect(await BookQuery.books(rows: store).isEmpty)
        #expect(await BookQuery.books(rows: nil).isEmpty)
    }
}
#endif
