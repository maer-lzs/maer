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

    @Test("Zeilen-Ziel: Buch im Regal, Katalog-Album, Server-Lied, und ein Grund statt Stille")
    func everyRowHasATargetOrAReason() {
        let T = ListenHistory.self
        // A book: on the shelf it opens, gone from it says so.
        #expect(T.target(of: entry("li_book1", .book), onShelf: true, sourceConfigured: true) == .book(itemId: "li_book1"))
        #expect(T.target(of: entry("li_book1", .book), onShelf: false, sourceConfigured: true) == .unavailable(.notInLibrary))
        #expect(T.target(of: entry("lv:123", .book), onShelf: true, sourceConfigured: true) == .book(itemId: "lv:123"),
                "a catalog book on the shelf is a book")
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

    /// The page: every row is a button into the one opener, and every
    /// outcome of it is handled; nothing that cannot open stays silent.
    @Test("die Seite: jede Zeile oeffnet ueber die eine Tuer, jeder Ausgang wird gesagt", .needsTheSources)
    func thePageOpensEveryRow() throws {
        let page = try code("Sources/Views/ListenHistoryScreen.swift")
        #expect(page.contains("Button {") && page.contains("await open(entry)"), "a row is not a button")
        #expect(page.contains("await ListenHistoryOpen.open(entry)"), "the page opens past the one opener")
        #expect(page.contains("case .unavailable(let reason): openFailure = MaerPlaylistPage.reasonText(reason)"),
                "a row that leads nowhere is not said with the sentence of the travelled lists")
        #expect(page.contains("case .failed(let sentence): openFailure = sentence"), "a failed question is not said")
        #expect(page.contains(".alert(Text(openFailure"), "the page has no place to say it")
        // The opener routes every target through the one route of the source pages.
        let opener = try code("Sources/ViewModels/ListenHistoryOpen.swift")
        for route in [".book(itemId: itemId)", ".catalogAlbum(itemId: itemId)", ".musicAlbum(album)"] {
            #expect(opener.contains("router.open(\(route))"), "a target does not open: \(route)")
        }
        #expect(opener.contains("return .unavailable(.notInLibrary)"), "a song without an album on the server is silent")
        #expect(opener.contains("return .failed(ErrorSentence.of(error))"), "a failed question is silent")
    }

    /// Both servers answer the album of a song from the song itself; the
    /// union asks the server the id names.
    @Test("beide Server nennen das Album eines Lieds aus dem Lied, die Vereinigung fragt den Server der Kennung", .needsTheSources)
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
