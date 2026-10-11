// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The groups of the own library (authors, series, genres) are one page,
/// opened by the books tab's tiles and by the search deck's tiles; the
/// groups come from one place, and the page of a group holds the books its
/// group counted.
struct BookGroupsTests {
    private func entry(_ id: String, author: String? = nil, series: String? = nil,
                       genres: [String]? = nil) -> LibraryEntry {
        LibraryEntry(item: LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: "Book \(id)", authorName: author, narratorName: nil,
                    seriesName: series, genres: genres, publishedYear: nil, description: nil),
                duration: 100, chapters: nil, tracks: nil),
            addedAt: nil), progress: nil)
    }

    private var stock: [LibraryEntry] {
        [entry("f1", author: "Asimov", series: "Foundation #1", genres: ["SF"]),
         entry("f2", author: "Asimov", series: "foundation #2", genres: ["SF", "Classic"]),
         entry("z1", author: "Zelazny", series: "Amber #1", genres: ["Fantasy"]),
         entry("w1", author: "Asimov, Silverberg", genres: ["SF"]),
         entry("n1")]
    }

    @Test("der Reiter und die Suche oeffnen fuer Serien und Autoren dieselbe Seite, ein Tipp in einer Gruppe dieselbe Buchliste wie ein Treffer")
    func tabAndSearchOpenTheSamePage() {
        #expect(LibraryListRoute.bookTabEntries == [.groups(.series), .groups(.authors), .localFiles, .history])
        let tiles = SearchDeckTiles.tiles(scope: .audiobooks, counts: SearchDeckCounts())
        let searchKinds: [BookGroupKind] = tiles.compactMap {
            if case .group(let kind) = $0.destination { return kind } else { return nil }
        }
        let tabKinds: [BookGroupKind] = LibraryListRoute.bookTabEntries.compactMap {
            if case .groups(let kind) = $0 { return kind } else { return nil }
        }
        #expect(searchKinds == [.authors, .series, .genres])
        #expect(tabKinds == [.series, .authors], "the tab opens no groups page of its own: \(tabKinds)")
        for kind in BookGroupKind.allCases {
            let tile = tiles.first { $0.destination == .group(kind) }
            #expect(tile?.title == LibraryListRoute.groups(kind).title, "\(kind): the two entries are named apart")
            #expect(tile?.systemImage == LibraryListRoute.groups(kind).systemImage, "\(kind): the two glyphs differ")
        }
        #expect(LibraryListRoute.books(of: .authors, named: "A") == .author("A"))
        #expect(LibraryListRoute.books(of: .series, named: "S") == .series("S"))
        #expect(LibraryListRoute.books(of: .genres, named: "G") == .genre("G"))
    }

    @Test("die Gruppen je Art kommen aus einer Stelle: Serien gefaltet und sortiert, ohne Serie in keiner; das Deck der Suche liest dieselben")
    func theGroupsComeFromOnePlace() {
        let series = LibraryViewModel.groups(.series, of: stock)
        #expect(series.map(\.name) == ["Amber", "Foundation"], "\(series.map(\.name))")
        #expect(series.map(\.entries.count) == [1, 2], "the folded series split or a book without one joined")
        let deck = SearchDeck.build(entries: stock, shows: [], albums: [])
        for kind in BookGroupKind.allCases {
            let page = LibraryViewModel.groups(kind, of: stock).map { "\($0.name):\($0.entries.count)" }
            let searched: [(name: String, entries: [LibraryEntry])]
            switch kind {
            case .authors: searched = deck.authorGroups
            case .series: searched = deck.seriesGroups
            case .genres: searched = deck.genreGroups
            }
            #expect(searched.map { "\($0.name):\($0.entries.count)" } == page, "\(kind): the deck groups apart from the page")
        }
    }

    @Test("die Seite einer Gruppe haelt jedes Buch, das ihre Gruppe zaehlt; Serie und Genre genau diese")
    func thePageOfAGroupHoldsItsBooks() {
        for kind in BookGroupKind.allCases {
            for group in LibraryViewModel.groups(kind, of: stock) {
                let counted = Set(group.entries.map(\.id))
                let shown = Set(LibraryViewModel.books(of: kind, named: group.name, in: stock).map(\.id))
                #expect(counted.isSubset(of: shown), "\(kind) \(group.name): the page lacks \(counted.subtracting(shown))")
                if kind != .authors {
                    #expect(shown == counted, "\(kind) \(group.name): the page shows \(shown), the group counted \(counted)")
                }
            }
        }
        let foundation = LibraryViewModel.books(of: .series, named: "Foundation", in: stock).map(\.id)
        #expect(Set(foundation) == ["f1", "f2"], "the series page misses a book of another spelling: \(foundation)")
        let unknown = LibraryViewModel.authorGroupName(of: entry("x"))
        let withoutAuthor = LibraryViewModel.books(of: .authors, named: unknown, in: stock).map(\.id)
        #expect(withoutAuthor == ["n1"], "the group of the books without an author opens an empty page: \(withoutAuthor)")
    }

    @Test("die Suche hat keine Bohr-Ebene fuer Buchgruppen mehr und schiebt die Seite; der Reiter zeigt die Kacheln", .needsTheSources)
    func noSecondGroupList() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let deck = try code("Sources/ViewModels/SearchDeck.swift")
        #expect(!deck.contains("case groups(") && !deck.contains("case entries("), "the search keeps a drill level of book groups")
        #expect(!deck.contains("baseSeriesName("), "the deck groups the series by itself again")
        let screen = try code("Sources/Views/SearchScreen.swift")
        #expect(screen.contains("case .group(let kind):") && screen.contains("pushLibraryListRoute(.groups(kind))"),
                "a group tile of the search opens no page")
        let library = try code("Sources/Views/LibraryView.swift")
        #expect(library.contains("BookGroupsScreen(kind: kind, entries: viewModel.entries)"), "the groups route has no page")
        #expect(library.contains("LibraryListRoute.bookTabEntries.map"), "the books tab shows no tile deck")
        #expect(library.contains("NavigationLink(value: LibraryListRoute.localFiles)"),
                "the serverless row reaches local files by another way than the tile")
    }
}
#endif
