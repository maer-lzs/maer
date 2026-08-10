// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

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
        // A bare id is an Audiobookshelf item — the only family without a
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
        // Streams are not — neither carries the download capability, and the
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
        // assignment keep working — without this a song would fall into the
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
        // A plain release is not a song — the caller then means the whole thing.
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
#endif
