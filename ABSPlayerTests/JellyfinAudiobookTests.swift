// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// facf3e3: Jellyfin audiobooks. Every case here is pinned to a MEASURED value
/// from the operator's run against Jellyfin 10.11.11 with Bookshelf 13.0.0.0 — the wire
/// payloads are the ones that instance answered, not invented shapes.
@Suite struct JellyfinAudiobookTests {

    /// The `/Users/{id}/Views` answer of the measured instance.
    private let viewsWire = """
    {"Items":[
      {"Id":"v-books","Name":"Hoerbuecher","CollectionType":"books"},
      {"Id":"v-music","Name":"Musik","CollectionType":"music"}
    ],"TotalRecordCount":2}
    """

    @Test func theBooksLibraryIsFoundByItsCollectionType() throws {
        let views = try JSONDecoder().decode(JFItemsResult.self, from: Data(viewsWire.utf8))
        let books = JellyfinProvider.booksView(in: views.items ?? [])
        #expect(books?.id == "v-books")
        #expect(books?.name == "Hoerbuecher")
    }

    /// A server WITHOUT a books library must not grow one — a books library is
    /// a plugin-side setup, not a given.
    @Test func aServerWithoutABooksLibraryOffersNone() throws {
        let wire = """
        {"Items":[{"Id":"v-music","Name":"Musik","CollectionType":"music"}]}
        """
        let views = try JSONDecoder().decode(JFItemsResult.self, from: Data(wire.utf8))
        #expect(JellyfinProvider.booksView(in: views.items ?? []) == nil)
    }

    /// The measured item: type `AudioBook`, RunTimeTicks present, no chapters.
    private let bookWire = """
    {"Id":"b1","Name":"Auf der Galerie","Type":"AudioBook",
     "RunTimeTicks":1800000000,"AlbumArtist":"Franz Kafka",
     "UserData":{"PlaybackPositionTicks":900000000,"Played":false,"PlayCount":1}}
    """

    @Test func aBookMapsWithoutChapters() throws {
        let book = try JSONDecoder().decode(JFItem.self, from: Data(bookWire.utf8))
        let item = JellyfinProvider.libraryItem(fromBook: book)
        #expect(item.id == "jf:book:b1")
        #expect(item.media?.metadata?.title == "Auf der Galerie")
        #expect(item.media?.metadata?.authorName == "Franz Kafka")
        // 1_800_000_000 ticks = 180 s (the measured 3,0 min).
        #expect(item.media?.duration == 180)
        // NOT a gap: measured, `Chapters` is 0 and Jellyfin generates none for
        // AudioBook. A chapter assembly here would build for a case the server
        // does not produce.
        #expect(item.media?.chapters == nil)
    }

    /// The road that carries. 900 000 000 ticks = 90 s — exactly the value
    /// written and read back on the measured instance.
    @Test func theListeningPositionComesBackFromUserData() throws {
        let book = try JSONDecoder().decode(JFItem.self, from: Data(bookWire.utf8))
        #expect(JellyfinProvider.position(fromUserData: book.userData) == 90)
    }

    /// No position is NOT position zero — a book at 0 would jump to the start.
    @Test func anAbsentPositionStaysAbsent() throws {
        let wire = """
        {"Id":"b2","Name":"Ohne Stand","Type":"AudioBook",
         "UserData":{"PlaybackPositionTicks":0,"PlayCount":0}}
        """
        let book = try JSONDecoder().decode(JFItem.self, from: Data(wire.utf8))
        #expect(JellyfinProvider.position(fromUserData: book.userData) == nil)
        #expect(JellyfinProvider.position(fromUserData: nil) == nil)
    }

    /// An older server answers no UserData fields at all — the wire type must
    /// decode anyway (mirrors of varying versions, and the sweep's lesson).
    @Test func aUserDataWithoutTheNewFieldsStillDecodes() throws {
        let wire = """
        {"Id":"b3","Name":"Alt","Type":"AudioBook","UserData":{"PlayCount":2}}
        """
        let book = try JSONDecoder().decode(JFItem.self, from: Data(wire.utf8))
        #expect(book.userData?.playCount == 2)
        #expect(book.userData?.playbackPositionTicks == nil)
    }

    @Test func theBooksLibraryIdCarriesTheViewId() {
        let libraryId = JellyfinProvider.libraryId(booksViewId: "v-books")
        #expect(JellyfinProvider.booksViewId(fromLibraryId: libraryId) == "v-books")
        // A music library id must not be mistaken for a books one.
        #expect(JellyfinProvider.booksViewId(fromLibraryId: "jf") == nil)
    }

    /// The id namespace must stay unambiguous — a book is not an album.
    @Test func bookIdsAreTheirOwnKind() {
        #expect(JellyfinProvider.id("jf:book:b1", kind: "book") == "b1")
        #expect(JellyfinProvider.id("jf:album:a1", kind: "book") == nil)
        #expect(JellyfinProvider.owns(itemId: "jf:book:b1"))
    }
}
#endif
