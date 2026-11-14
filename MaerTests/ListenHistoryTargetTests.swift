// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A row of the listening history opens its target: a book row the book, a
/// song row the song's album. A row that cannot open says why.
struct ListenHistoryTargetTests {
    private func entry(_ id: String, _ family: ListenHistory.Family) -> ListenHistory.Entry {
        ListenHistory.Entry(id: id, family: family, title: "T", subtitle: "S", heardAt: 1_800_000_000_000, unheardAt: nil)
    }

    private func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("Row target: book on the shelf, catalog album, server song, and a reason instead of silence")
    func everyRowHasATargetOrAReason() {
        let T = ListenHistory.self
        // A book: on the shelf it opens, gone from it says so.
        #expect(T.target(of: entry("li_book1", .book), onShelf: true, sourceConfigured: true) == .book(itemId: "li_book1"))
        #expect(T.target(of: entry("li_book1", .book), onShelf: false, sourceConfigured: true) == .unavailable(.notInLibrary))
        // A catalog book opens its detail page from its id: it never stands
        // in the shelf's entries, so the shelf is not asked.
        for id in ["lv:123", "lva:radioplay", "gut:84"] {
            for onShelf in [true, false] {
                #expect(T.target(of: entry(id, .book), onShelf: onShelf, sourceConfigured: false) == .catalogBook(itemId: id))
            }
        }
        // A catalog song opens its release; a title of one song is its own.
        let track = CatalogSongID.make(album: "lva:release", index: 3)
        #expect(T.target(of: entry(track, .music), onShelf: false, sourceConfigured: false) == .catalogAlbum(itemId: "lva:release"))
        #expect(T.target(of: entry("jam:991", .music), onShelf: false, sourceConfigured: false) == .catalogAlbum(itemId: "jam:991"))
        // A server song asks its server for the album, once it is set up here.
        #expect(T.target(of: entry("sub:song:s1", .music), onShelf: false, sourceConfigured: true) == .serverSong(itemId: "sub:song:s1"))
        #expect(T.target(of: entry("jf:song:j1", .music), onShelf: false, sourceConfigured: true) == .serverSong(itemId: "jf:song:j1"))
        #expect(T.target(of: entry("sub:song:s1", .music), onShelf: false, sourceConfigured: false)
                == .unavailable(.sourceNotConfigured(source: "sub:")))
        // Nobody knows the id: a reason, not silence.
        #expect(T.target(of: entry("zzz:1", .music), onShelf: false, sourceConfigured: true) == .unavailable(.unknownSource))
    }

    /// The opener as the page calls it, with the shelf the app has: a heard
    /// catalog audiobook opens its detail page (the shelf's entries never
    /// hold a catalog work), a server book no longer on the shelf says why.
    @MainActor
    @Test("at the caller: a played catalog audiobook opens its page, a server book off the shelf says the reason")
    func theOpenerOpensACatalogBook() async {
        let router = PlayerSourceRouter.shared
        let before = router.handler
        defer { router.handler = before }
        var routed: [String] = []
        router.handler = { routed.append(String(describing: $0)) }
        for id in ["lv:history-witness-1", "lva:history-witness-2"] {
            #expect(AppSession.shared.libraryViewModel.entry(id: id) == nil, "the shelf holds no catalog work")
            #expect(await ListenHistoryOpen.open(entry(id, .book)) == .opened, "a catalog book row does not open: \(id)")
        }
        #expect(routed == ["catalogBook(itemId: \"lv:history-witness-1\")", "catalogBook(itemId: \"lva:history-witness-2\")"])
        routed = []
        #expect(await ListenHistoryOpen.open(entry("li_history_witness_gone", .book)) == .unavailable(.notInLibrary))
        #expect(routed.isEmpty, "a book that is gone opened something")
    }

    /// The handler the router calls pushes the one catalog book page for
    /// `.catalogBook`, in the books tab; swallowing the target would leave the
    /// opener green and the tap without a page.
    @Test("the grip pushes the one detail page for a catalog book, in the audiobooks tab", .needsTheSources)
    func theHandlerPushesTheCatalogBookPage() throws {
        let library = try code("Sources/Views/LibraryView.swift")
        // The router's handler only: the search handler pushes the same
        // route for its own hits and would answer for it.
        let start = try #require(library.range(of: "PlayerSourceRouter.shared.handler = {"), "the handler is gone")
        let end = try #require(library.range(of: "case .catalogAlbum(let itemId):", range: start.upperBound..<library.endIndex))
        let handler = String(library[start.upperBound..<end.lowerBound])
        #expect(StockDriftTests.squeezed(handler).contains(
            StockDriftTests.squeezed("case .catalogBook(let itemId):\n pushToActive(FreeAudiobooksRoute.catalogBook(itemId: itemId))")),
            "the handler does not push the catalog book page")
        #expect(PlayerSourceTarget.catalogBook(itemId: "lv:1").tab == .audiobooks)
    }

    /// The page: every row is a button into the one opener, and every
    /// outcome of it is handled; nothing that cannot open stays silent.
    @Test("the page: every row opens through the one door, every outcome is reported", .needsTheSources)
    func thePageOpensEveryRow() throws {
        let page = try code("Sources/Views/ListenHistoryScreen.swift")
        #expect(page.contains("Button {") && page.contains("await open(entry)"), "a row is not a button")
        #expect(page.contains("await ListenHistoryOpen.open(entry)"), "the page opens past the one opener")
        #expect(page.contains("case .unavailable(let reason): openFailure = MaerPlaylistPage.reasonText(reason)"),
                "a row that leads nowhere is not said with the sentence of the travelled lists")
        #expect(page.contains("case .failed(let sentence): openFailure = sentence"), "a failed question is not said")
        #expect(page.contains(".sentenceAlert($openFailure)"), "the page has no place to say it")
        // The opener routes every target through the one route of the source pages.
        let opener = try code("Sources/ViewModels/ListenHistoryOpen.swift")
        for route in [".book(itemId: itemId)", ".catalogBook(itemId: itemId)", ".catalogAlbum(itemId: itemId)", ".musicAlbum(album)"] {
            #expect(opener.contains("router.open(\(route))"), "a target does not open: \(route)")
        }
        #expect(opener.contains("return .unavailable(.notInLibrary)"), "a song without an album on the server is silent")
        #expect(opener.contains("return .failed(ErrorSentence.of(error))"), "a failed question is silent")
    }

    /// Both servers answer the album of a song from the song itself; the
    /// union asks the server the id names.
    @Test("both servers name the album of a song from the song, the union asks the server of the id", .needsTheSources)
    func bothServersNameTheAlbum() throws {
        let subsonic = try code("Sources/Providers/SubsonicProvider.swift")
        #expect(subsonic.contains("guard let song = try await client.song(id: songId), let albumId = song.albumId else { return nil }"))
        #expect(subsonic.contains("id: Self.itemId(albumId: albumId)"))
        let jellyfin = try code("Sources/Providers/JellyfinProvider.swift")
        #expect(jellyfin.contains("guard let song = try await client.item(id: songId), let albumId = song.albumId else { return nil }"))
        #expect(jellyfin.contains("id: Self.itemId(albumId: albumId)"))
        let union = try code("Sources/Providers/MusicUnion.swift")
        #expect(union.contains("try await source(for: songItemId).album(ofSong: songItemId)"))
        // Not a song: nothing to ask.
        #expect(SubsonicProvider.id("sub:album:a1", kind: "song") == nil)
        #expect(JellyfinProvider.id("jf:album:a1", kind: "song") == nil)
    }
}
#endif
