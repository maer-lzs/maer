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
