// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Etappe 2: the pure wire→domain mapping at the Jellyfin boundary.
struct JellyfinMappingTests {
    private func jfItem(id: String = "i1", name: String? = "Name", type: String? = nil,
                        ticks: Double? = nil, year: Int? = nil, albumArtist: String? = nil,
                        artists: [String]? = nil, childCount: Int? = nil,
                        dateCreated: String? = nil) -> JFItem {
        JFItem(id: id, name: name, type: type, runTimeTicks: ticks, indexNumber: nil,
               productionYear: year, genres: nil, album: nil, albumId: nil,
               albumArtist: albumArtist, artists: artists, overview: nil,
               dateCreated: dateCreated, childCount: childCount, userData: nil, playlistItemId: nil)
    }

    @Test("Ticks are 100ns: 10_000_000 ticks = 1 second")
    func tickConversion() {
        #expect(JellyfinProvider.seconds(fromTicks: 36_000_000_000) == 3600)
        #expect(JellyfinProvider.seconds(fromTicks: nil) == nil)
    }

    @Test("Jellyfin 7-digit fraction date parses to epoch ms")
    func dateParsing() {
        // 2026-07-01T10:00:00Z = 1_782_900_000_000 ms (see MusicMappingTests).
        #expect(JellyfinProvider.epochMs(fromJFDate: "2026-07-01T10:00:00.0000000Z") == 1_782_900_000_000)
        #expect(JellyfinProvider.epochMs(fromJFDate: "2026-07-01T10:00:00Z") == 1_782_900_000_000)
        #expect(JellyfinProvider.epochMs(fromJFDate: "garbage") == nil)
        #expect(JellyfinProvider.epochMs(fromJFDate: nil) == nil)
    }

    @Test("Album item maps to a jf:album LibraryItem")
    func albumMapping() {
        let item = JellyfinProvider.libraryItem(fromAlbum: jfItem(
            id: "a1", name: "Album", ticks: 24_000_000_000, year: 1999,
            albumArtist: "Artist", dateCreated: "2026-07-01T10:00:00.0000000Z"))
        #expect(item.id == "jf:album:a1")
        #expect(item.title == "Album")
        #expect(item.author == "Artist")
        #expect(item.media?.duration == 2400)
        #expect(item.addedAt == 1_782_900_000_000)
    }

    @Test("Playlist maps count/duration/changedAt; artist maps childCount")
    func playlistAndArtistMapping() {
        let pl = JellyfinProvider.domainPlaylist(jfItem(
            id: "p1", name: "Mix", ticks: 600_000_000_0, childCount: 3,
            dateCreated: "2026-07-01T10:00:00Z"))
        #expect(pl.songCount == 3)
        #expect(pl.duration == 600)
        #expect(pl.changedAt == 1_782_900_000_000)
        let artist = JellyfinProvider.domainArtist(jfItem(id: "ar1", name: "A", childCount: 7))
        #expect(artist.albumCount == 7)
    }

    @Test("Shelf vocabulary translates to Jellyfin sorts")
    func shelfTranslation() {
        #expect(JellyfinProvider.shelfSort(for: .newest) == ("DateCreated", "Descending"))
        #expect(JellyfinProvider.shelfSort(for: .frequent) == ("PlayCount", "Descending"))
        #expect(JellyfinProvider.shelfSort(for: .recent) == ("DatePlayed", "Descending"))
        #expect(JellyfinProvider.shelfSort(for: .byArtist) == ("AlbumArtist,SortName", "Ascending"))
        #expect(JellyfinProvider.shelfSort(for: .alphabetical) == ("SortName", "Ascending"))
        #expect(SubsonicProvider.albumListType(for: .newest) == "newest")
        #expect(SubsonicProvider.albumListType(for: .byArtist) == "alphabeticalByArtist")
    }

    @Test("Lyrics: synced ticks become seconds, unsynced lines carry no start")
    func lyricsMapping() {
        let synced = JellyfinProvider.songLyrics(from: JFLyricsResponse(
            metadata: JFLyricsMetadata(isSynced: true),
            lyrics: [JFLyricLine(start: 25_000_000, text: "Line")]))
        #expect(synced?.synced == true)
        #expect(synced?.lines.first?.start == 2.5)
        let plain = JellyfinProvider.songLyrics(from: JFLyricsResponse(
            metadata: JFLyricsMetadata(isSynced: false),
            lyrics: [JFLyricLine(start: 25_000_000, text: "Line")]))
        #expect(plain?.synced == false)
        #expect(plain?.lines.first?.start == nil)
        #expect(JellyfinProvider.songLyrics(from: JFLyricsResponse(metadata: nil, lyrics: [])) == nil)
    }
}
#endif
