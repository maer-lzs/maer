// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The pure playlist-card presentation rules.
struct PlaylistPresentationTests {
    @Test("mosaic tile count degrades gracefully 0…4+")
    func mosaicTiles() {
        #expect(PlaylistPresentation.mosaicTileCount(0) == 0)
        #expect(PlaylistPresentation.mosaicTileCount(1) == 1)
        #expect(PlaylistPresentation.mosaicTileCount(2) == 2)
        #expect(PlaylistPresentation.mosaicTileCount(3) == 3)
        #expect(PlaylistPresentation.mosaicTileCount(4) == 3)
        #expect(PlaylistPresentation.mosaicTileCount(9) == 3)   // caps at big + two small
        #expect(PlaylistPresentation.mosaicTileCount(-3) == 0)
    }

    @Test("duration text: H:MM at an hour or more, else M:SS")
    func duration() {
        #expect(PlaylistPresentation.durationText(seconds: 4320) == "1:12")   // 1h12m
        #expect(PlaylistPresentation.durationText(seconds: 600) == "10:00")
        #expect(PlaylistPresentation.durationText(seconds: 225) == "3:45")
        #expect(PlaylistPresentation.durationText(seconds: 0) == "0:00")
    }

    @Test("changed timestamp parses ISO-8601 (with and without fractional seconds)")
    func changed() {
        #expect(PlaylistPresentation.changedDate("2026-07-20T10:00:00Z") != nil)
        #expect(PlaylistPresentation.changedDate("2026-07-20T10:00:00.123Z") != nil)
        #expect(PlaylistPresentation.changedDate(nil) == nil)
        #expect(PlaylistPresentation.changedDate("not a date") == nil)
    }

    @Test("sort: newest changed first, undated last, stable")
    func sort() {
        struct P { let name: String; let changed: String? }
        let input = [
            P(name: "old", changed: "2026-07-18T10:00:00Z"),
            P(name: "none", changed: nil),
            P(name: "new", changed: "2026-07-20T10:00:00Z"),
            P(name: "mid", changed: "2026-07-19T10:00:00Z"),
        ]
        let sorted = PlaylistPresentation.sortedByChanged(input) {
            PlaylistPresentation.changedDate($0.changed)
        }
        #expect(sorted.map(\.name) == ["new", "mid", "old", "none"])
    }

    /// ONE playlist row: server and device lists share it, the device lists
    /// carry the capsule, the "+" card stands once at the end.
    @Test("Eine Playlist-Reihe: Kapsel nur an Geraete-Listen, das Plus einmal", .needsTheSources)
    @MainActor
    func onePlaylistRow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Views/Music/MusicView.swift"), encoding: .utf8)
        #expect(view.components(separatedBy: "NewPlaylistCard {").count - 1 == 1, "the plus card stands once")
        #expect(!view.contains("On your server"), "a second row per world came back")
        let list = MaerPlaylists.Playlist(id: "l1", name: "Test", updatedAt: 1_700_000_000, itemIds: ["lv:1"])
        let device = PlaylistCardSource.device(list)
        #expect(device.placeCapsule != nil)
        #expect(device.changedAtMs == 1_700_000_000_000, "the store keeps seconds, the card speaks ms")
        // A server list may carry a capsule (its server's name), so
        // the card's name hangs on the world, never on the capsule.
        #expect(PlaylistCard.identifier(for: device) == "maer-playlist-l1")
        var serverWithCapsule = device
        serverWithCapsule.isDeviceList = false
        serverWithCapsule.placeCapsule = "Navidrome"
        #expect(PlaylistCard.identifier(for: serverWithCapsule) == "server-playlist-l1")
    }

    /// The card of a device list and its page draw the mosaic from the
    /// same question, asked as each is drawn: a card built while the
    /// music server cannot answer yet shows the covers on its next build.
    @Test("Karte und Seite einer Geraete-Liste nehmen das Mosaik aus derselben Quelle, bei jedem Bau", .needsTheSources)
    @MainActor
    func deviceCardAndPageShareTheMosaic() throws {
        let list = MaerPlaylists.Playlist(id: "l1", name: "Test", updatedAt: 1, itemIds: ["sub:song:1", "sub:song:2"])
        final class Answers: @unchecked Sendable { var ready = false }
        let answers = Answers()
        var router = ItemRouter.empty
        router.coverURL = { id in answers.ready ? URL(string: "https://music.example/\(id)") : nil }
        let card = PlaylistCardSource.device(list, router: router)
        #expect(card.covers?() == [], "no server answer yet")
        answers.ready = true
        #expect(card.covers?() == PlaylistCardSource.deviceCovers(list, router: router))
        #expect(card.covers?().count == 2, "the next draw carries the covers")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let flat = { (path: String) throws -> String in
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let cardCode = try flat("Sources/Views/Music/PlaylistCard.swift")
        #expect(cardCode.contains("PlaylistArtwork(playlistID:source.id,coverURLs:shownCovers"))
        #expect(cardCode.contains("source.covers?()??coverURLs"))
        #expect(cardCode.contains("covers:{deviceCovers(list,router:router)}"))
        #expect(try flat("Sources/Views/Music/MusicLibraryPages.swift")
            .contains("PlaylistArtwork(playlistID:playlist.id,coverURLs:PlaylistCardSource.deviceCovers(playlist,router:router))"))
    }

    /// A device list of music server songs met nowhere else: the source has
    /// not named their covers, so the card asks for them and draws what was
    /// learned; the page asks the same question when it shows.
    @Test("Geraete-Liste fragt die Cover, die ihre Quelle noch nicht nennt, und zeichnet das Gelernte", .needsTheSources)
    @MainActor
    func deviceListLearnsItsCovers() async throws {
        let list = MaerPlaylists.Playlist(id: "l-learn", name: "Test", updatedAt: 1,
                                          itemIds: ["sub:song:tr-1", "sub:song:tr-2", "sub:song:tr-1"])
        final class Server: @unchecked Sendable {
            var named: [String: String] = [:]
            var asked: [[String]] = []
        }
        let server = Server()
        var router = ItemRouter.empty
        router.coverURL = { id in URL(string: "https://music.example/\(server.named[id] ?? id)") }
        router.learnCovers = { ids in
            server.asked.append(ids)
            server.named = ["sub:song:tr-1": "al-1", "sub:song:tr-2": "al-1"]
            return true
        }
        let card = PlaylistCardSource.device(list, router: router)
        #expect(card.covers?().map(\.lastPathComponent) == ["sub:song:tr-1", "sub:song:tr-2"],
                "before the answer each song asks its own id")
        let loaded = await card.mosaic()
        #expect(server.asked == [list.itemIds], "the card asks once, for the list's entries")
        #expect(loaded.covers.map(\.lastPathComponent) == ["al-1"], "the learned cover, once")
        #expect(card.covers?() == loaded.covers, "the card draws what was learned")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: root.appendingPathComponent("Sources/Views/Music/MusicLibraryPages.swift"),
                              encoding: .utf8).components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(page.contains("ifletids=playlist?.itemIds,awaitrouter.learnCovers(ids){coverRound+=1}"))
        #expect(page.contains("letround=coverRound"), "the page's body reads the round")
    }

    @Test("TF2: realPlaylists keeps only real named playlists (name non-empty and != id), incl. empty ones")
    func realPlaylistsFilter() {
        func pl(_ id: String, _ name: String?, songs: Int? = 0) -> MusicPlaylist {
            MusicPlaylist(id: id, itemId: id, name: name, songCount: songs, duration: nil, changedAt: nil)
        }
        let input = [
            pl("pl-1", "My Mix", songs: 18),          // real, named
            pl("pl-2", "Empty but named", songs: 0),  // real, named, EMPTY → kept
            pl("abc123", "abc123"),                   // junk: name == id
            pl("pl-4", ""),                           // junk: empty name
            pl("pl-5", "   "),                        // junk: whitespace-only name
            pl("pl-6", nil),                          // junk: nil name
        ]
        #expect(PlaylistPresentation.realPlaylists(input).map(\.id) == ["pl-1", "pl-2"])
    }

    // MARK: - Mosaic cover selection (Korrektur 01.08. Duplicates hard-forbidden)

    @Test("Regression: per-song cover ids of ONE album collapse to one tile")
    func sameAlbumCollapsesToOneTile() {
        // Navidrome hands every song its own coverArt id (mf-…). Three songs
        // of the same album must yield ONE mosaic tile, never three copies.
        let songs: [(albumKey: String?, coverArt: String?)] = [
            ("al-1", "mf-1"), ("al-1", "mf-2"), ("al-1", "mf-3"),
        ]
        #expect(PlaylistPresentation.mosaicCoverIDs(songs) == ["mf-1"])
    }

    @Test("unique albums fill up to the limit, in playlist order")
    func uniqueAlbumsFill() {
        let songs: [(albumKey: String?, coverArt: String?)] = [
            ("al-1", "c1"), ("al-2", "c2"), ("al-1", "c1b"), ("al-3", "c3"),
            ("al-4", "c4"), ("al-5", "c5"),
        ]
        #expect(PlaylistPresentation.mosaicCoverIDs(songs) == ["c1", "c2", "c3", "c4"])
    }

    @Test("no album key: the cover id itself is the identity; nil covers skip")
    func fallbackKeys() {
        let songs: [(albumKey: String?, coverArt: String?)] = [
            (nil, "c1"), (nil, "c1"), (nil, nil), (nil, "c2"),
        ]
        #expect(PlaylistPresentation.mosaicCoverIDs(songs) == ["c1", "c2"])
    }

    @Test("hard invariant: the selection NEVER contains duplicate album keys")
    func selectionNeverDuplicates() {
        let songs: [(albumKey: String?, coverArt: String?)] =
            (0..<40).map { ("al-\($0 % 3)", "mf-\($0)") }
        let ids = PlaylistPresentation.mosaicCoverIDs(songs)
        #expect(ids.count == Set(ids).count)
        #expect(ids.count == 3)
    }

    /// The glyph of an empty playlist stands in the middle of the visible
    /// square: on the big square it sat on the frame's lower edge.
    @Test("das Symbol einer leeren Playlist steht in der Mitte des sichtbaren Quadrats, nicht auf dem grossen Feld", .needsTheSources)
    func theEmptyGlyphIsCentredInTheFrame() throws {
        let art = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/PlaylistArtwork.swift"), encoding: .utf8))
        let frame = try #require(art.range(of: ".aspectRatio(1, contentMode: .fit)"), "the card lost its square frame")
        let glyph = try #require(art.range(of: "Image(systemName: \"music.note.list\")"), "the empty glyph is gone")
        #expect(frame.upperBound < glyph.lowerBound, "the glyph hangs on a slot inside the frame again")
        #expect(art.components(separatedBy: "Image(systemName: \"music.note.list\")").count == 2, "the glyph is drawn twice")
    }

    /// The empty glyph grows with the square, like the radio placeholder:
    /// a fixed point size stayed small on the larger playlist page.
    @Test("das Symbol einer leeren Playlist waechst mit dem Quadrat, auf der Karte bleibt es 34 pt", .needsTheSources)
    func theEmptyGlyphScalesWithTheSquare() throws {
        let art = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/PlaylistArtwork.swift"), encoding: .utf8))
        #expect(art.contains(".font(.system(size: geo.size.width * Self.glyphShare))"), "the glyph lost its share of the square")
        #expect(!art.contains(".font(.system(size: 34))"), "the glyph is a fixed size again")
        #expect(abs(CardMetrics.featuredCardWidth * PlaylistArtwork.glyphShare - 34) < 1, "the card glyph moved off 34 pt")
    }
}

/// The playlist card's artist line. Most frequent first, folded
/// dedupe keeps the first-seen spelling, ties by appearance, empties drop.
struct PlaylistTopArtistsTests {
    @Test("Frequency ranks; folded spellings merge; first-seen display wins")
    func ranking() {
        let out = PlaylistPresentation.topArtists(
            ["Anna B", "Cari D", "anna b", "Émil", "Emil", "Anna B", "Zed"])
        #expect(out == ["Anna B", "Émil", "Cari D"])
    }

    @Test("Ties keep appearance order; limit applies; empties/nils drop")
    func tiesAndLimit() {
        #expect(PlaylistPresentation.topArtists(["B", "A", nil, " ", "C", "D"], limit: 3)
                == ["B", "A", "C"])
        #expect(PlaylistPresentation.topArtists([]) == [])
        #expect(PlaylistPresentation.topArtists([nil, "  "]).isEmpty)
    }
}
#endif
