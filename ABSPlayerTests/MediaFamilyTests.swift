// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The id namespace decides which page an item can reach. A family without a
/// mapping used to fall into "book" silently, which sent a netlabel album to
/// the audiobook tab and opened an empty page.
struct MediaFamilyTests {
    @Test("every known namespace has a defined family — none falls through")
    func everyNamespaceIsAssigned() {
        let expected: [String: MediaFamily] = [
            "rss:feed:ep": .podcast,
            "abspod:1": .podcast,
            "sub:song:1": .music,
            "jf:1": .music,
            "radio:1": .radio,
            "lv:176": .catalog,
            "lva:OTRR_Gunsmoke": .catalog,
            "jam:1886432": .catalog,
            "gut:12345": .catalog,
            "local:file": .book,
        ]
        for (id, family) in expected {
            #expect(MediaFamily.of(id) == family, "\(id) must map to \(family)")
        }
        // A bare id is an Audiobookshelf item. The only family without a
        // namespace of its own.
        #expect(MediaFamily.of("8f2a-uuid") == .book)
    }

    @Test("an unknown namespace stays unknown instead of counting as a book")
    func unknownIsVisible() {
        #expect(MediaFamily.of("newthing:42") == .unknown)
        #expect(!PlayerSourceTargets.isBook("newthing:42"),
                "an unknown family must not inherit the book affordance")
    }

    @Test("the catalogue families are books to nobody")
    func catalogIsNotABook() {
        for id in ["lv:176", "lva:x", "jam:1", "gut:2"] {
            #expect(!PlayerSourceTargets.isBook(id))
            #expect(PlayerSourceTargets.isCatalog(id))
        }
    }

    @Test("every prefix the catalogue owns is listed in the family map")
    func catalogPrefixesStayInSync() {
        let mapped = Set(MediaFamily.prefixes(for: .catalog))
        let owned: Set<String> = [FreeCatalog.librivoxPrefix, FreeCatalog.archivePrefix,
                                  FreeCatalog.jamendoPrefix, FreeCatalog.gutenbergPrefix]
        #expect(mapped == owned, "a new catalogue namespace must be assigned here too")
    }

    @Test("offline available means locally present, not undownloadable")
    @MainActor
    func offlineAvailabilityIsStatedPositively() {
        // Local files ARE here.
        #expect(LocalProvider.shared.capabilities.contains(.alwaysLocal))
        // Streams are not. Neither carries the download capability, and the
        // old rule turned that into "already here".
        #expect(!FreeCatalogProvider.shared.capabilities.contains(.alwaysLocal))
        #expect(!RadioProvider.shared.capabilities.contains(.alwaysLocal))
        #expect(!FreeCatalogProvider.shared.capabilities.contains(.downloadable))
        #expect(!DownloadManager.shared.isDownloaded(itemId: "lva:some-netlabel-release"),
                "a catalogue stream is not offline available")
    }

    @Test("a song address belongs to the same family as its release")
    func songAddressStaysInTheFamily() {
        // The suffix rides on the existing namespace, so routing and family
        // assignment keep working. Without this a song would fall into the
        // unknown case and lose every affordance.
        #expect(MediaFamily.of("lva:DWK123#3") == .catalog)
        #expect(MediaFamily.of("lva:DWK123") == .catalog)
        #expect(PlayerSourceTargets.isCatalog("lva:DWK123#3"))
        #expect(!PlayerSourceTargets.isBook("lva:DWK123#3"))
    }

    @Test("song addresses parse back to release and index")
    func songAddressesRoundTrip() {
        let id = CatalogSongID.make(album: "lva:DWK123", index: 3)
        #expect(id == "lva:DWK123#3")
        #expect(CatalogSongID.parse(id)?.album == "lva:DWK123")
        #expect(CatalogSongID.parse(id)?.index == 3)
        #expect(CatalogSongID.album(of: id) == "lva:DWK123")
        // A plain release is not a song. The caller then means the whole thing.
        #expect(CatalogSongID.parse("lva:DWK123") == nil)
        #expect(!CatalogSongID.isSong("lva:DWK123"))
        #expect(CatalogSongID.album(of: "lva:DWK123") == "lva:DWK123")
        // An identifier that itself contains a hash keeps its last segment.
        #expect(CatalogSongID.parse("lva:odd#name#7")?.album == "lva:odd#name")
        // Garbage after the separator is not an index.
        #expect(CatalogSongID.parse("lva:x#abc") == nil)
        #expect(CatalogSongID.parse("lva:x#-1") == nil)
    }

    @Test("a song can be queued and put on a playlist — that is the whole point")
    func songsAreQueueable() {
        #expect(PlayQueue.canEnqueue("lva:DWK123#3"))
    }
}

/// The ONE membership test of the books-tab library rows. The third
/// instance of the "family never asked" class, fixed at the class.
@Suite struct BooksTabMembershipTests {

    @Test("books and readings belong, every other family does not")
    func familyMatrix() {
        #expect(MediaFamily.booksTabMember("abs-book-uuid", markedForm: nil))
        #expect(MediaFamily.booksTabMember("local:side-load", markedForm: nil))
        #expect(MediaFamily.booksTabMember("lv:12345", markedForm: nil))
        #expect(MediaFamily.booksTabMember("gut:999", markedForm: nil))
        #expect(!MediaFamily.booksTabMember("rss:feed:ep", markedForm: nil))
        #expect(!MediaFamily.booksTabMember("sub:song", markedForm: nil))
        #expect(!MediaFamily.booksTabMember("radio:rb:x", markedForm: nil))
        #expect(!MediaFamily.booksTabMember("newthing:42", markedForm: nil))
    }

    @Test("jam: is music by type — never a book, form or no form")
    func jamendoNeverBooks() {
        #expect(!MediaFamily.booksTabMember("jam:album-1", markedForm: nil))
        #expect(!MediaFamily.booksTabMember("jam:album-1", markedForm: .album))
        #expect(!MediaFamily.booksTabMember("jam:album-1", markedForm: .work))
    }

    @Test("lva: decides per item — track address is music, work follows its form")
    func archiveDecidesPerItem() {
        // Song-addressed id: a TRACK, music by construction, pre-form stock
        // included.
        #expect(!MediaFamily.booksTabMember("lva:netlabel#3", markedForm: nil))
        // Whole work started as an album: music.
        #expect(!MediaFamily.booksTabMember("lva:album", markedForm: .album))
        // Whole work as a work. Or without a form: the book side is home.
        #expect(MediaFamily.booksTabMember("lva:reading", markedForm: .work))
        #expect(MediaFamily.booksTabMember("lva:reading", markedForm: nil))
    }

    @Test("the continue stock filters through the membership — jam: reaches music instead of vanishing")
    func continueStockRespectsMembership() {
        let defaults: [String: Any] = [
            "localPosition.jam:album-1": [120.0, 1000.0],          // pre-form stock
            "localPosition.lva:netlabel#3": [95.0, 2000.0],        // track address
            "localPosition.lv:reading": [400.0, 3000.0, 3600.0],   // a reading
        ]
        let books = ContinueSources.started(in: defaults, serverKnows: [])
        #expect(books.map(\.id) == ["lv:reading"])
        // The refused music ids appear on the MUSIC side and never vanish,
        // via the id form when the started form is missing.
        let music = ContinueSources.positionless(in: defaults, serverKnows: [])
        #expect(Set(music.map(\.id)) == ["jam:album-1", "lva:netlabel#3"])
    }
}
#endif
