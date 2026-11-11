// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Jellyfin audiobooks. Every case here is pinned to a MEASURED value
/// measured against Jellyfin 10.11.11 with Bookshelf 13.0.0.0. The wire
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

    /// A server WITHOUT a books library must not grow one. A books library is
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

    /// The road that carries. 900 000 000 ticks = 90 s. Exactly the value
    /// written and read back on the measured instance.
    @Test func theListeningPositionComesBackFromUserData() throws {
        let book = try JSONDecoder().decode(JFItem.self, from: Data(bookWire.utf8))
        #expect(JellyfinProvider.position(fromUserData: book.userData) == 90)
    }

    /// No position is NOT position zero. A book at 0 would jump to the start.
    @Test func anAbsentPositionStaysAbsent() throws {
        let wire = """
        {"Id":"b2","Name":"Ohne Stand","Type":"AudioBook",
         "UserData":{"PlaybackPositionTicks":0,"PlayCount":0}}
        """
        let book = try JSONDecoder().decode(JFItem.self, from: Data(wire.utf8))
        #expect(JellyfinProvider.position(fromUserData: book.userData) == nil)
        #expect(JellyfinProvider.position(fromUserData: nil) == nil)
    }

    /// An older server answers no UserData fields at all. The wire type must
    /// decode anyway (mirrors of varying versions, and the sweep's lesson).
    @Test func aUserDataWithoutTheNewFieldsStillDecodes() throws {
        let wire = """
        {"Id":"b3","Name":"Alt","Type":"AudioBook","UserData":{"PlayCount":2}}
        """
        let book = try JSONDecoder().decode(JFItem.self, from: Data(wire.utf8))
        #expect(book.userData?.playCount == 2)
        #expect(book.userData?.playbackPositionTicks == nil)
    }

    /// A MEASURED value rather than an intention: the
    /// server cannot tell "never touched" from "explicitly set to 0". Both
    /// answers are byte-identical. So 0 must not count as progress, or every
    /// never-heard book lands in "Continue listening", and silently.
    ///
    /// Same class as the flushed witness: a source answering a question it
    /// cannot answer.
    @Test func positionZeroIsNoProgressBecauseTheServerCannotTellTheCasesApart() throws {
        let untouched = """
        {"Id":"b9","Name":"Nie gehoert","Type":"AudioBook","RunTimeTicks":1800000000,
         "UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false}}
        """
        let afterReset = untouched   // byte-identical — that IS the finding
        for wire in [untouched, afterReset] {
            let book = try JSONDecoder().decode(JFItem.self, from: Data(wire.utf8))
            #expect(JellyfinProvider.position(fromUserData: book.userData) == nil)
        }
    }

    /// The write must carry REAL JSON types. A quoted "true" is a
    /// string, and a server that ignores a mistyped field does it silently.
    /// The first thing to rule out before concluding that Jellyfin cannot mark
    /// a book finished at all.
    @Test func theUserDataWriteSendsANumberAndABool() throws {
        let data = try JellyfinClient.userDataBody(seconds: 90, isFinished: true)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"PlaybackPositionTicks\":900000000"))
        #expect(text.contains("\"Played\":true"))
        // …and NOT as strings, which is what the old dictionary body produced.
        #expect(!text.contains("\"900000000\""))
        #expect(!text.contains("\"true\""))
    }

    /// The server's position carries the moment it was written: the write
    /// sends `LastPlayedDate`, and the read gives it to the start, so an
    /// older backup of this device no longer wins over another device's
    /// newer position.
    @Test("Jellyfin: der Schrieb traegt das Datum, der Stand des Servers liest es, und eine aeltere Sicherung gewinnt nicht")
    func theServerStandCarriesItsMoment() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.25)
        let text = String(decoding: try JellyfinClient.userDataBody(seconds: 90, isFinished: false, now: now), as: UTF8.self)
        #expect(text.contains("\"LastPlayedDate\":\"2027-01-15T08:00:00.250Z\""), "the write carries no moment: \(text)")
        let wire = #"{"Id":"b1","UserData":{"PlaybackPositionTicks":30000000000,"LastPlayedDate":"2027-01-15T08:00:00.2500000Z"}}"#
        let book = try JSONDecoder().decode(JFItem.self, from: Data(wire.utf8))
        let stand = try #require(JellyfinProvider.standMs([book.userData]), "the read lost the moment")
        #expect(abs(stand - 1_800_000_000_250) < 1)
        #expect(JellyfinProvider.standMs([nil, book.userData, nil]) == stand)
        #expect(JellyfinProvider.standMs([nil]) == nil)
        // Device A kept minute 10 an hour before device B wrote minute 50.
        #expect(!SyncRules.shouldRestoreLocalPosition(savedTime: 600, savedAtMs: stand - 3_600_000,
                                                      serverTime: 3_000, serverUpdateMs: stand),
                "the older backup of this device wins over the server's newer position")
    }

    /// The audiobooks of a library come page by page until the listing
    /// ends: 1200 files of three books in pages of 500 fold into three
    /// books, and a page that fails in the middle leaves no listing that
    /// stands as the whole stock.
    @Test("Jellyfin: die Hoerbuecher kommen geblaettert, 1200 Dateien in drei Buechern; eine Seite, die scheitert, gibt keinen ganzen Bestand")
    func theAudiobooksArePaged() async throws {
        let files: [JFItem] = try (0..<1200).map { index in
            let book = index / 400
            let wire = #"{"Id":"f\#(index)","ParentId":"folder-\#(book)","Album":"Book \#(book)","IndexNumber":\#(index % 400 + 1)}"#
            return try JSONDecoder().decode(JFItem.self, from: Data(wire.utf8))
        }
        var asked: [Int] = []
        let all = try await JellyfinClient.allPages(limit: 500) { start, limit in
            asked.append(start)
            return (Array(files[min(start, files.count)..<min(start + limit, files.count)]), files.count)
        }
        #expect(asked == [0, 500, 1000])
        #expect(all.count == 1200, "a page was lost: \(all.count)")
        #expect(JellyfinBookFold.fold(all).count == 3, "the fold did not find the three books")
        // Without a total the listing ends at the short page.
        let untold = try await JellyfinClient.allPages(limit: 500) { start, limit in
            (Array(files[min(start, files.count)..<min(start + limit, files.count)]), nil)
        }
        #expect(untold.count == 1200)
        struct Cut: Error {}
        await #expect(throws: Cut.self, "a listing cut in the middle stood as the whole stock") {
            _ = try await JellyfinClient.allPages(limit: 500) { start, limit in
                if start >= 500 { throw Cut() }
                return (Array(files[start..<start + limit]), files.count)
            }
        }
    }

    @Test func aNegativePositionNeverTravels() throws {
        let data = try JellyfinClient.userDataBody(seconds: -5, isFinished: false)
        #expect(String(decoding: data, as: UTF8.self).contains("\"PlaybackPositionTicks\":0"))
    }

    @Test func theBooksLibraryIdCarriesTheViewId() {
        let libraryId = JellyfinProvider.libraryId(booksViewId: "v-books")
        #expect(JellyfinProvider.booksViewId(fromLibraryId: libraryId) == "v-books")
        // A music library id must not be mistaken for a books one.
        #expect(JellyfinProvider.booksViewId(fromLibraryId: "jf") == nil)
    }

    /// The id namespace must stay unambiguous. A book is not an album.
    @Test func bookIdsAreTheirOwnKind() {
        #expect(JellyfinProvider.id("jf:book:b1", kind: "book") == "b1")
        #expect(JellyfinProvider.id("jf:album:a1", kind: "book") == nil)
        #expect(JellyfinProvider.owns(itemId: "jf:book:b1"))
    }
}
#endif
