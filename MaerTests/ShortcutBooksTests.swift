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

    private let tagOf = OutwardServerTag.tagOf(
        owners: OutwardItemRefTests.owners(["a": OutwardItemRefTests.serverA, "b": OutwardItemRefTests.serverA,
                                            "c": OutwardItemRefTests.serverA]),
        salt: OutwardItemRefTests.saltA)

    @Test("die Zeilen tragen, der Kurzbefehl findet die Buecher")
    func theRowsCarry() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        _ = try await store.replaceAll(LibraryDiskCache(items: [item("a", title: "Alpha"), item("b", title: "Beta"),
                                                                item("c", title: nil)],
                                                        progress: [:]))
        let books = await BookQuery.books(rows: store, tagOf: tagOf)
        #expect(books.map(\.title) == ["Alpha", "Beta"], "a title is what makes a book; the one without stays out")
        #expect(books.first?.author == "A")
        #expect(books.map(\.itemId) == ["a", "b"])
        #expect(books.map(\.id) == ["a", "b"].map { OutwardItemRef.ref(itemId: $0, serverTag: tagOf($0)) },
                "the entity's id is the outward id")
    }

    @Test("leere Zeilen oder keine: keine Buecher, kein Fehler")
    func nothingIsNothing() async throws {
        let store = try await LibraryRowStore(connection: try SQLiteConnection(path: ":memory:"))
        #expect(await BookQuery.books(rows: store, tagOf: tagOf).isEmpty)
        #expect(await BookQuery.books(rows: nil, tagOf: tagOf).isEmpty)
    }

    @Test("ein Buch ohne Besitzer wird nicht angeboten")
    func noOwnerNoBook() {
        let books = BookQuery.books(from: [item("a", title: "Alpha"), item("unowned", title: "Ohne")], tagOf: tagOf)
        #expect(books.map(\.itemId) == ["a"])
    }

    @Test("die Kennung nach aussen, eine fremde und eine alte Kennung finden ihr Buch")
    func theIdentifiersFindTheirBooks() throws {
        let items = [item("a", title: "Alpha"), item("b", title: "Beta")]
        let own = try #require(BookQuery.books(from: items, tagOf: tagOf).first?.id)
        let otherTag = try #require(OutwardServerTag.tag(owner: OutwardItemRefTests.serverA, salt: OutwardItemRefTests.saltB))
        let fromAnotherDevice = try #require(OutwardItemRef.ref(itemId: "b", serverTag: otherTag))
        let found = BookQuery.books(for: [own, fromAnotherDevice, "a", "abs.\(otherTag).gone", "gone"], in: items, tagOf: tagOf)
        #expect(found.map(\.itemId) == ["a", "b", "a"],
                "an outward id, one from another device and a library id of an older shortcut")
        #expect(found.last?.id == own, "an older id is answered with its outward id where there is one")
    }

    /// Without a register or without a salt no item has a tag: an older
    /// shortcut still finds its book in the rows, an outward id does not.
    @Test("eine alte Kennung findet ihr Buch ohne Register und ohne Salz")
    func anOlderIdNeedsNoRegisterAndNoSalt() throws {
        let items = [item("a", title: "Alpha"), item("c", title: nil)]
        let noTag: (String) -> String? = { _ in nil }
        let ref = try #require(OutwardItemRef.ref(itemId: "a", serverTag: tagOf("a")))
        let found = BookQuery.books(for: ["a", ref, "c", "gone"], in: items, tagOf: noTag)
        #expect(found.map(\.itemId) == ["a"], "the older id finds its book; the outward id, a book without a title and an unknown id do not")
        #expect(found.first?.id == "a", "without a tag the book keeps the id the shortcut holds")
        #expect(BookQuery.books(from: items, tagOf: noTag).isEmpty, "nothing new is offered without a tag")
    }

    @Test("das Hoerbuch der Audio-Domaene traegt, was die Zeile weiss, und dieselbe Kennung")
    @available(iOS 27, *)
    func theAudiobookCarriesTheRow() throws {
        let row = LibraryItem(
            id: "a",
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Alpha", authorName: "A", narratorName: "N",
                                              seriesName: "S", genres: ["Krimi", "Hoerspiel"], publishedYear: nil,
                                              description: nil),
                duration: 10, chapters: nil, tracks: nil),
            addedAt: 1)
        let book = try #require(BookQuery.books(from: [row], tagOf: tagOf).first)
        let audiobook = AudiobookEntity(book)
        #expect(audiobook.id == book.id, "one outward id for both entities")
        #expect(audiobook.itemId == "a")
        #expect(audiobook.title == "Alpha")
        #expect(audiobook.author == "A")
        #expect(audiobook.narrator == "N")
        #expect(audiobook.seriesTitle == "S")
        #expect(audiobook.genre == "Krimi, Hoerspiel")
        #expect(audiobook.publisher == nil && audiobook.purchaseDate == nil && audiobook.releaseDate == nil,
                "a field the library does not hold stays empty")
    }

    /// The build exports the entity under the audio schema: without it the
    /// metadata of the whole target are missing and no intent works.
    @Test("der Bau exportiert das Hoerbuch unter dem Schema der Audio-Domaene")
    func theBuildExportsTheAudiobook() throws {
        let url = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                               subdirectory: "Metadata.appintents"),
                               "the app carries no App Intents metadata")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let entities = try #require(json["entities"] as? [String: Any])
        let entity = try #require(entities["AudiobookEntity"], "the audiobook entity is not exported")
        let text = String(describing: entity)
        #expect(text.contains("MediaBookEntity") && text.contains("audio"), "not under the audio schema: \(text.prefix(300))")
    }
}
#endif
