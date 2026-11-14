// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A Gutenberg title names its author and genres as a person reads them,
/// not in the record's catalogue form, at every way in.
struct GutenbergNamesTests {
    @Test("the author appears as first name last name, without life dates")
    func theAuthorReadsAsAName() {
        #expect(FreeCatalog.gutenbergAuthor("Swift, Jonathan, 1667-1745") == "Jonathan Swift")
        #expect(FreeCatalog.gutenbergAuthor("Swift, Jonathan") == "Jonathan Swift")
        #expect(FreeCatalog.gutenbergAuthor("Doyle, Arthur Conan, 1859-1930") == "Arthur Conan Doyle")
        #expect(FreeCatalog.gutenbergAuthor("Wells, H. G. (Herbert George), 1866-1946") == "H. G. Wells")
        #expect(FreeCatalog.gutenbergAuthor("Scott, Walter, Sir, 1771-1832") == "Sir Walter Scott")
        #expect(FreeCatalog.gutenbergAuthor("Homer, active 8th century B.C.") == "Homer")
        #expect(FreeCatalog.gutenbergAuthor("Anonymous") == "Anonymous")
        #expect(FreeCatalog.gutenbergAuthor(nil) == nil)
        #expect(FreeCatalog.gutenbergAuthor("") == nil)
    }

    @Test("a genre is the main heading of the subject chain, each once")
    func aGenreIsTheChainsMainHeading() {
        #expect(FreeCatalog.gutenbergGenres(["Voyages, Imaginary -- Fiction", "Satire", "Voyages, Imaginary -- Juvenile fiction"])
                == ["Voyages, Imaginary", "Satire"])
        #expect(FreeCatalog.gutenbergGenres([]) == nil)
        #expect(FreeCatalog.gutenbergGenres(nil) == nil)
    }

    /// The subjects of Gulliver's Travels as the kept Gutenberg stock carries
    /// them (`gut:9272`).
    @Test("the real Gulliver chain gives at most three genres, the character drops")
    func theGulliverChainGivesThreeGenresWithoutTheCharacter() {
        let gulliver = ["Fantasy fiction", "Satire", "Travelers -- Fiction",
                        "Gulliver, Lemuel (Fictitious character) -- Fiction",
                        "Voyages, Imaginary -- Early works to 1800"]
        #expect(FreeCatalog.gutenbergGenres(gulliver) == ["Fantasy fiction", "Satire", "Travelers"])
        // The character drops even where it would stand within the limit.
        #expect(FreeCatalog.gutenbergGenres(["Gulliver, Lemuel (Fictitious character) -- Fiction", "Satire"]) == ["Satire"])
        #expect(FreeCatalog.gutenbergGenreLimit == 3)
    }

    @Test("every way of a Gutenberg title takes the two rules", .needsTheSources)
    func everyWayInTakesTheRules() throws {
        let provider = SyncContractFenceTests.stripped(
            try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/FreeCatalogProvider.swift"),
                       encoding: .utf8))
        #expect(provider.components(separatedBy: "FreeCatalog.gutenbergAuthor(").count - 1 == 3)
        #expect(provider.components(separatedBy: "FreeCatalog.gutenbergGenres(").count - 1 == 2)
        // The kept stock is read through the rules too.
        #expect(provider.contains(".map(FreeCatalog.gutenbergReadable)"))
    }

    /// Every way a stored Gutenberg title comes back into the app, and the
    /// read that takes it through the rules there.
    static let storedWays: [(file: String, read: String)] = [
        ("Sources/Providers/FreeCatalogProvider.swift", ".map(FreeCatalog.gutenbergReadable)"),
        ("Sources/Networking/DownloadManager.swift", "(keeper.startNow() ?? [:]).mapValues(FreeCatalog.gutenbergReadable)"),
        ("Sources/Networking/DownloadManager.swift", "read: read.mapValues(FreeCatalog.gutenbergReadable)"),
        ("Sources/Storage/ListenHistory.swift", "entries = rows.mapValues(Self.readable)"),
        ("Sources/Storage/ListenHistory.swift", "read: read.mapValues(Self.readable)"),
        ("Sources/Providers/MaerPlaylists.swift", ".map(FreeCatalog.gutenbergReadable)"),
        ("Sources/Models/SyncCarried.swift", "carried.map(FreeCatalog.gutenbergReadable)"),
    ]

    @Test("every stored way of a Gutenberg title reads through the rules", .needsTheSources)
    func everyStoredWayReadsThroughTheRules() throws {
        for way in Self.storedWays {
            let text = SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(way.file), encoding: .utf8))
            #expect(text.contains(way.read), "\(way.file) reads a stored Gutenberg title raw")
        }
    }

    @Test("Download, history and carried title read legibly")
    func theOtherStoredFormsReadReadable() throws {
        let stored = """
        {"id":"gut:9272","media":{"metadata":{"title":"Gulliver's Travels","authorName":"Swift, Jonathan, 1667-1745",
        "genres":["Satire","Gulliver, Lemuel (Fictitious character) -- Fiction"]},"duration":40000},
        "userMediaProgress":null}
        """
        let detail = FreeCatalog.gutenbergReadable(try JSONDecoder().decode(LibraryItemDetail.self, from: Data(stored.utf8)))
        #expect(detail.media.metadata?.authorName == "Jonathan Swift" && detail.media.metadata?.genres == ["Satire"])
        #expect(detail.media.duration == 40000)
        let carried = FreeCatalog.gutenbergReadable(CarriedItem(id: "gut:9272", title: "Gulliver's Travels",
                                                                subtitle: "Swift, Jonathan, 1667-1745"))
        #expect(carried.subtitle == "Jonathan Swift" && carried.title == "Gulliver's Travels")
        #expect(SyncCarried.stub(itemId: "gut:9272", carried: CarriedItem(id: "gut:9272", title: "G",
                                                                           subtitle: "Swift, Jonathan, 1667-1745"))
                    .media?.metadata?.authorName == "Jonathan Swift")
        let entry = ListenHistory.readable(ListenHistory.Entry(id: "gut:9272", family: .book, title: "G",
                                                              subtitle: "Swift, Jonathan, 1667-1745", heardAt: 1))
        #expect(entry.subtitle == "Jonathan Swift")
        // Another title keeps its words.
        let other = ListenHistory.Entry(id: "lva:x", family: .book, title: "G", subtitle: "Swift, Jonathan", heardAt: 1)
        #expect(ListenHistory.readable(other) == other)
    }

    @Test("a Gutenberg title stored before the rules reads legibly", .needsTheSources)
    func aTitleKeptBeforeTheRulesReadsReadable() throws {
        // The record as the kept stock held it before the rules existed.
        let stored = """
        {"id":"gut:9272","media":{"metadata":{"title":"Gulliver's Travels","authorName":"Swift, Jonathan, 1667-1745",
        "genres":["Fantasy fiction","Satire","Travelers -- Fiction","Gulliver, Lemuel (Fictitious character) -- Fiction"]},
        "duration":40000},"addedAt":null}
        """
        let item = try JSONDecoder().decode(LibraryItem.self, from: Data(stored.utf8))
        let read = FreeCatalog.gutenbergReadable(item)
        #expect(read.media?.metadata?.authorName == "Jonathan Swift")
        #expect(read.media?.metadata?.genres == ["Fantasy fiction", "Satire", "Travelers"])
        #expect(read.media?.duration == 40000 && read.media?.metadata?.title == "Gulliver's Travels")
        // Read again, it stays as it is; any other title passes unchanged.
        #expect(FreeCatalog.gutenbergReadable(read) == read)
        let other = LibraryItem(id: "lva:x", media: item.media, addedAt: nil)
        #expect(FreeCatalog.gutenbergReadable(other) == other)
    }

    @Test("a Gutenberg audiobook is never an album: the player leads to the book page, the series shows a work", .needsTheSources)
    func aGutenbergBookIsNeverAnAlbum() throws {
        // Even a title once marked as started in album form stays a reading.
        for form in [ProgressMark.StartedForm?.none, .album] {
            guard case .catalogBook(let id) = PlayerSourceTargets.catalogPage("gut:9272", markedForm: form) else {
                Issue.record("a Gutenberg title leads to the album page"); continue
            }
            #expect(id == "gut:9272")
        }
        let song = CatalogSongID.make(album: "lva:MIXG032", index: 0)
        guard case .catalogAlbum(let release) = PlayerSourceTargets.catalogPage(song, markedForm: nil) else {
            Issue.record("a catalogue song does not lead to its release"); return
        }
        #expect(release == "lva:MIXG032")
        guard case .catalogAlbum = PlayerSourceTargets.catalogPage("jam:991", markedForm: nil) else {
            Issue.record("a Jamendo title does not lead to its album"); return
        }
        // The player asks the form; the series page lets only archive items be albums.
        let player = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/PlayerView.swift"), encoding: .utf8))
        #expect(player.contains("return PlayerSourceTargets.catalogPage(id, markedForm: ListeningStore.startedForm(id))"))
        #expect(!player.contains("if PlayerSourceTargets.isCatalog(id) { return .catalogAlbum(itemId: id) }"))
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift"), encoding: .utf8))
        #expect(page.contains("guard itemId.hasPrefix(FreeCatalog.archivePrefix) else { return .series }"))
    }

    @Test("a catalog title in Continue Listening opens its page, not an episode page")
    @MainActor
    func aCatalogTitleOpensItsOwnPage() {
        let facts = CatalogFacts.empty
        #expect(facts.page(of: "gut:9272") == .catalogBook(itemId: "gut:9272"))
        let song = CatalogSongID.make(album: "lva:MIXG032", index: 0)
        #expect(facts.page(of: song) == .series(itemId: "lva:MIXG032"))
        // An episode keeps its episode page.
        #expect(facts.page(of: "rss:episode-1") == nil)
    }
}
#endif
