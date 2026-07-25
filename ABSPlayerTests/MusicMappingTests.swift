// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Stage 1½: the wire→domain mapping at the Subsonic boundary.
struct MusicMappingTests {
    @Test("Playlist mapping parses the ISO changed stamp to epoch ms")
    func playlistMapping() {
        let wire = SubsonicPlaylist(id: "pl-1", name: "Roadtrip", songCount: 12,
                                    duration: 3600, coverArt: nil, owner: nil,
                                    changed: "2026-07-01T10:00:00Z", entry: nil)
        let domain = SubsonicProvider.domainPlaylist(wire)
        #expect(domain.name == "Roadtrip")
        #expect(domain.duration == 3600)
        #expect(domain.changedAt == 1_782_900_000_000)  // 2026-07-01T10:00:00Z in epoch ms
        let unstamped = SubsonicProvider.domainPlaylist(
            SubsonicPlaylist(id: "pl-2", name: nil, songCount: nil, duration: nil,
                             coverArt: nil, owner: nil, changed: "not-a-date", entry: nil))
        #expect(unstamped.changedAt == nil)
    }

    @Test("Artist info picks the largest image and flattens similar names")
    func artistInfoMapping() {
        let wire = SubsonicArtistInfo(
            biography: "bio", musicBrainzId: nil,
            smallImageUrl: "https://img/s", mediumImageUrl: "https://img/m",
            largeImageUrl: "https://img/l",
            similarArtist: [
                SubsonicArtist(id: "a1", name: "Alpha", coverArt: nil, albumCount: nil, album: nil),
                SubsonicArtist(id: "a2", name: nil, coverArt: nil, albumCount: nil, album: nil),
            ])
        let domain = SubsonicProvider.domainArtistInfo(wire)
        #expect(domain.imageURL?.absoluteString == "https://img/l")
        #expect(domain.similarArtistNames == ["Alpha"])
        let small = SubsonicProvider.domainArtistInfo(SubsonicArtistInfo(
            biography: nil, musicBrainzId: nil, smallImageUrl: "https://img/s",
            mediumImageUrl: nil, largeImageUrl: nil, similarArtist: nil))
        #expect(small.imageURL?.absoluteString == "https://img/s")
        #expect(small.similarArtistNames.isEmpty)
    }
}
#endif
