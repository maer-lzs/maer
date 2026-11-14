// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The shelves' answers become entries below the views, with the one
/// curation. Each witness checks what the pages did before, word for word:
/// which documents stay, in which order, and that music is not curated.
@MainActor
struct CatalogShelfEntriesTests {
    static func doc(_ id: String = "entries-\(UUID().uuidString)", title: String = "T",
                    creator: String? = nil) -> ArchivePopularDoc {
        ArchivePopularDoc(identifier: id, title: ArchiveStringList([title]),
                          creator: creator.map { ArchiveStringList([$0]) }, downloads: 1, runtime: nil,
                          licenseurl: nil, year: nil, subject: nil, collection: ArchiveStringList(["etree"]))
    }

    @Test("the one curation: block list always, LibriVox separation only outside LibriVox, order stays")
    func theOneCuration() {
        let first = Self.doc(), second = Self.doc()
        let denied = Self.doc("BearislandAM")
        let duplicate = Self.doc(title: "Read by LibriVox volunteers")
        let docs = [first, denied, duplicate, second]
        #expect(CatalogShelfEntries.curated(docs, source: .archiveBooks).map(\.identifier)
                == [first.identifier, second.identifier], "ausserhalb von LibriVox faellt das Duplikat")
        #expect(CatalogShelfEntries.curated(docs, source: .librivox).map(\.identifier)
                == [first.identifier, duplicate.identifier, second.identifier], "LibriVox trennt sich nicht von sich selbst")
    }

    @Test("a shelf becomes entries; collections behind the single works only where required")
    func aShelfBecomesEntries() throws {
        let collection = Self.doc(creator: "Various")
        let single = Self.doc(creator: "A")
        let denied = Self.doc("IceStationZebraAM")
        let answer = CatalogShelfSource.Answer.archive(docs: [collection, denied, single], total: 42)
        let books = try #require(CatalogShelfEntries.shelf(answer, source: .archiveBooks, collectionsLast: true))
        #expect(books.items.map(\.id) == [single, collection].map { FreeCatalog.archivePrefix + ($0.identifier ?? "") })
        #expect(books.total == 42)
        let plain = try #require(CatalogShelfEntries.shelf(answer, source: .archiveBooks))
        #expect(plain.items.map(\.id) == [collection, single].map { FreeCatalog.archivePrefix + ($0.identifier ?? "") },
                "ohne Verlangen bleibt die Reihenfolge der Antwort")
        #expect(CatalogShelfEntries.shelf(.unsupported, source: .archiveBooks) == nil)
        #expect(CatalogShelfEntries.shelf(nil, source: .archiveBooks) == nil)
        #expect(CatalogShelfEntries.shelf(.gutenberg(books: [], total: 0), source: .gutenberg)?.items.isEmpty == true)
    }

    @Test("Music is not curated, as before")
    func musicIsNotCurated() {
        let denied = Self.doc("HMSUlyssesAM")
        let items = CatalogShelfEntries.music([denied])
        #expect(items.map(\.id) == [FreeCatalog.archivePrefix + "HMSUlyssesAM"],
                "die Buch-Kuratierung galt fuer die Musik nie")
    }
}
#endif
