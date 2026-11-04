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

    @Test("Siris Frage: nichts genannt ist Weiterhoeren, eine Suche findet Titel und Autor")
    func whatSiriAsksFinds() {
        let books = BookQuery.books(from: [item("a", title: "Der Zauberberg", author: "Thomas Mann"),
                                           item("b", title: "Die unendliche Geschichte", author: "Michael Ende"),
                                           item("c", title: "Effi Briest", author: "Theodor Fontane")], tagOf: tagOf)
        let ids = { (ask: AudioAsk, last: String?) in AudioAsk.books(for: ask, in: books, lastPlayedId: last).map(\.itemId) }
        #expect(ids(.unnamed, "c") == ["c"], "nothing named continues the last played book")
        #expect(ids(.unnamed, "rss:feed:episode").isEmpty, "the last played title is no book on offer")
        #expect(ids(.unnamed, nil).isEmpty)
        #expect(ids(.search("zauberberg"), nil) == ["a"], "a search ignores case")
        #expect(ids(.search("Fontané"), nil) == ["c"], "a search ignores accents and finds the author")
        #expect(ids(.search("  "), nil).isEmpty, "an empty search finds nothing")
        #expect(ids(.unanswered, "a").isEmpty, "an address is not answered")
        #expect(AudioAsk.search("geheim").kind == "search", "the log line names the kind, never the words")
    }

    /// The build exports Siri's play under the audio schema, and its search.
    @Test("der Bau exportiert Siris Wiedergabe unter dem Schema der Audio-Domaene")
    func theBuildExportsThePlay() throws {
        let url = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                               subdirectory: "Metadata.appintents"))
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])
        let actions = try #require(json["actions"] as? [String: Any])
        let play = try #require(actions["PlayAudioIntent"], "Siri's play is not exported")
        let text = String(describing: play)
        #expect(text.contains("PlayAudioIntent") && text.contains("audio"), "not under the audio schema: \(text.prefix(300))")
    }

    /// Siri's play starts a title through the one door of continue
    /// listening, never a way of its own.
    @Test("Siris Wiedergabe geht durch die eine Tuer des Weiterhoerens", .needsTheSources)
    func thePlayGoesThroughTheDoor() throws {
        let shortcuts = try FetchAnswerTests.squeezedSource("Sources/AppShortcuts.swift")
        #expect(shortcuts.contains("case .audiobook(let book): try await ResumeListeningIntent.run(itemId: book.itemId)"),
                "the book does not go through the door")
        #expect(!shortcuts.contains("resume(namedItemId:"), "a way of its own beside the door")
        let widget = try FetchAnswerTests.squeezedSource("Sources/Models/WidgetShared.swift")
        #expect(widget.contains("try await Self.run(itemId: itemId) { try await Self.opensApp(self) }"),
                "the widget's command left the shared run")
    }

    @Test("der laufende Titel nennt Siri sein Buch, nur mit Kennung nach aussen")
    @available(iOS 27, *)
    func thePlayingTitleNamesItsBook() {
        #expect(NowPlayingEntities.ref(forItem: "a", tagOf: tagOf) == OutwardItemRef.ref(itemId: "a", serverTag: tagOf("a")))
        #expect(NowPlayingEntities.ref(forItem: "a", tagOf: tagOf) != nil)
        #expect(NowPlayingEntities.ref(forItem: "unowned", tagOf: tagOf) == nil, "a book without an owner")
        #expect(NowPlayingEntities.ref(forItem: "rss:feed:episode", tagOf: tagOf) == nil, "an episode is no book")
        #expect(NowPlayingEntities.ref(forItem: nil, tagOf: tagOf) == nil)
    }

    /// The info is written on every event of the playback: the device's
    /// tags are read once per title, never for a title with a namespace.
    @Test("die Kennung des laufenden Titels wird je Titel einmal gerechnet")
    @available(iOS 27, *)
    @MainActor
    func theIdentifiersAreWorkedOutOncePerTitle() {
        let owned = "li_\(UUID().uuidString)"
        let other = "li_\(UUID().uuidString)"
        let owners = OutwardItemRefTests.owners([owned: OutwardItemRefTests.serverA, other: OutwardItemRefTests.serverA])
        var reads = 0
        let tags: () -> ((String) -> String?)? = {
            reads += 1
            return OutwardServerTag.tagOf(owners: owners, salt: OutwardItemRefTests.saltA)
        }
        #expect(NowPlayingEntities.identifiers(forItem: owned, tagOf: tags).count == 1)
        #expect(NowPlayingEntities.identifiers(forItem: owned, tagOf: tags).count == 1)
        #expect(reads == 1, "the second write of the same title reads nothing")
        #expect(NowPlayingEntities.identifiers(forItem: other, tagOf: tags).count == 1)
        #expect(reads == 2, "another title is worked out anew")
        #expect(NowPlayingEntities.identifiers(forItem: "rss:feed:\(UUID().uuidString)", tagOf: tags).isEmpty)
        #expect(reads == 2, "a title with a namespace reads nothing")
        #expect(NowPlayingEntities.identifiers(forItem: "li_\(UUID().uuidString)", tagOf: { nil }).isEmpty,
                "without salt or register no entity")
    }

    /// A book often plays for days: an empty answer gives way when the
    /// register gets a new stand, and an unreadable salt is asked again
    /// after a minute, without a read on every write in between.
    @Test("ein leeres Ergebnis weicht einem neuen Stand des Registers und nach einer Minute")
    @available(iOS 27, *)
    @MainActor
    func anEmptyAnswerGivesWay() {
        let book = "li_\(UUID().uuidString)"
        let start = Date()
        var reads = 0
        var owners = ItemOwners()
        let tags: () -> ((String) -> String?)? = {
            reads += 1
            return OutwardServerTag.tagOf(owners: owners, salt: OutwardItemRefTests.saltA)
        }
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 7, now: start).isEmpty,
                "no owner yet")
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 7, now: start + 30).isEmpty)
        #expect(reads == 1, "the same stand within the minute reads nothing")
        owners.noteFullLoad(ids: [book], server: OutwardItemRefTests.serverA)
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 8, now: start + 31).count == 1,
                "the register's new stand gives the entity while the same book plays")
        #expect(reads == 2)
        #expect(NowPlayingEntities.identifiers(forItem: book, tagOf: tags, generation: 9, now: start + 999).count == 1)
        #expect(reads == 2, "a found entity holds for its title")

        let locked = "li_\(UUID().uuidString)"
        var saltReadable = false
        let lockedTags: () -> ((String) -> String?)? = {
            reads += 1
            guard saltReadable else { return nil }
            return OutwardServerTag.tagOf(owners: OutwardItemRefTests.owners([locked: OutwardItemRefTests.serverA]),
                                          salt: OutwardItemRefTests.saltA)
        }
        #expect(NowPlayingEntities.identifiers(forItem: locked, tagOf: lockedTags, generation: 9, now: start).isEmpty,
                "a locked keychain gives no salt")
        saltReadable = true
        #expect(NowPlayingEntities.identifiers(forItem: locked, tagOf: lockedTags, generation: 9, now: start + 59).isEmpty)
        #expect(reads == 3, "within the minute nothing is read")
        #expect(NowPlayingEntities.identifiers(forItem: locked, tagOf: lockedTags, generation: 9, now: start + 61).count == 1,
                "after the minute the salt is asked again")
    }

    @Test("ein gemerktes Ergebnis gilt fuer seinen Titel, leer nur bei gleichem Stand und binnen der Frist")
    @available(iOS 27, *)
    func whenAKeptAnswerHolds() {
        let at = Date()
        let holds = { (count: Int, kept: Int, now: Int, after: TimeInterval, asked: String?) in
            NowPlayingEntities.holds(itemId: "a", identifiers: count, generation: kept, at: at,
                                     for: asked, generation: now, now: at + after)
        }
        #expect(holds(1, 1, 2, 9999, "a"), "a found entity holds")
        #expect(!holds(1, 1, 1, 0, "b"), "another title never holds")
        #expect(holds(0, 1, 1, 59, "a"), "empty, same stand, within the minute")
        #expect(!holds(0, 1, 2, 0, "a"), "empty gives way to a new stand")
        #expect(!holds(0, 1, 1, NowPlayingEntities.emptyHolds, "a"), "empty gives way after the minute")
    }

    @Test("ein geschriebenes Register zaehlt seinen Stand")
    func aWrittenRegisterCountsItsStand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owners-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = ItemOwnerShelf(file: dir.appendingPathComponent("item-owners.json"))
        let before = OutwardServerTag.registerGeneration
        shelf.write(OutwardItemRefTests.owners(["a": OutwardItemRefTests.serverA]), afterCorruptRead: false)
        #expect(OutwardServerTag.registerGeneration > before, "a written register is a new stand")
        let after = OutwardServerTag.registerGeneration
        shelf.write(ItemOwners(), afterCorruptRead: true)
        #expect(OutwardServerTag.registerGeneration == after, "a write that does not happen is no new stand")
    }

    @Test("die Angaben zum laufenden Titel tragen sein Buch", .needsTheSources)
    func theNowPlayingInfoCarriesTheBook() throws {
        let nowPlaying = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel+NowPlaying.swift")
        #expect(nowPlaying.contains("let identifiers = NowPlayingEntities.identifiers(forItem: item?.id) if !identifiers.isEmpty { info[MPNowPlayingInfoPropertyAppEntityIdentifiers] = identifiers }"),
                "the now playing info does not name the title's entity")
    }
}
#endif
