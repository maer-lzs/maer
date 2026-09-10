// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Etappe 2: the pure wire→domain mapping at the Jellyfin boundary.
struct JellyfinMappingTests {
    private func jfItem(id: String = "i1", name: String? = "Name", type: String? = nil,
                        ticks: Double? = nil, year: Int? = nil, albumArtist: String? = nil,
                        artists: [String]? = nil, childCount: Int? = nil,
                        dateCreated: String? = nil) -> JFItem {
        JFItem(id: id, name: name, type: type, collectionType: nil, runTimeTicks: ticks, indexNumber: nil,
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

    @Test("Authorization header: handshake carries no token, authorized calls carry it as Token")
    func authorizationHeaderCarriesTheToken() {
        let handshake = JellyfinClient.authorizationHeader(deviceId: "dev1")
        #expect(handshake == "MediaBrowser Client=\"Maer\", Device=\"iPhone\", DeviceId=\"dev1\", Version=\"2.6\"")
        #expect(!handshake.contains("Token="))
        // Jellyfin 12 turned off the legacy X-Emby-Token header; the token now
        // travels inside the Authorization header as Token="…", a form older
        // servers accept too.
        let authorized = JellyfinClient.authorizationHeader(deviceId: "dev1", token: "abc123")
        #expect(authorized == "MediaBrowser Client=\"Maer\", Device=\"iPhone\", DeviceId=\"dev1\", Version=\"2.6\", Token=\"abc123\"")
    }

    /// A source guard, because there is no injectable session here to prove the
    /// wiring and the live server is off-limits: no request may authorize via
    /// the legacy `X-Emby-Token` header, which Jellyfin 12 rejects.
    @Test("no request authorizes via the legacy X-Emby-Token header")
    func noLegacyTokenHeaderRemains() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if trimmed.contains("forHTTPHeaderField") && trimmed.contains("X-Emby-Token") {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "these files set the legacy X-Emby-Token header: \(offenders)")
        // The detector sees a real setter and ignores a mention in a comment.
        let setter = "request.setValue(t, forHTTPHeaderField: \"X-Emby-Token\")"
        #expect(setter.contains("forHTTPHeaderField") && setter.contains("X-Emby-Token"))
    }
}
#endif
