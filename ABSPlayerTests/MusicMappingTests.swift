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

/// Portrait chain (pure): conservative MB search, Wikidata relation, P18.
struct ArtistPortraitLookupTests {
    @Test("Unique strong hit only — ambiguity yields nil")
    func conservativeSearch() {
        let hit = MBArtistHit(id: "mb-1", name: "Kraftwerk", score: 100)
        #expect(ArtistPortraitLookup.uniqueSearchHit(
            MBArtistSearchResponse(artists: [hit]), name: "kraftwerk") == "mb-1")
        let twin = MBArtistHit(id: "mb-2", name: "Kraftwerk", score: 97)
        #expect(ArtistPortraitLookup.uniqueSearchHit(
            MBArtistSearchResponse(artists: [hit, twin]), name: "Kraftwerk") == nil)
        let weak = MBArtistHit(id: "mb-3", name: "Kraftwerk", score: 80)
        #expect(ArtistPortraitLookup.uniqueSearchHit(
            MBArtistSearchResponse(artists: [weak]), name: "Kraftwerk") == nil)
        let wrongName = MBArtistHit(id: "mb-4", name: "Kraftclub", score: 100)
        #expect(ArtistPortraitLookup.uniqueSearchHit(
            MBArtistSearchResponse(artists: [wrongName]), name: "Kraftwerk") == nil)
    }

    @Test("Wikidata relation and P18 parse")
    func wikidataChain() throws {
        let mb = MBArtistResponse(relations: [
            MBRelation(type: "official homepage", url: MBRelationURL(resource: "https://x.example")),
            MBRelation(type: "wikidata", url: MBRelationURL(resource: "https://www.wikidata.org/wiki/Q11036")),
        ])
        #expect(ArtistPortraitLookup.wikidataEntity(mb) == "Q11036")
        let entityJSON = """
        {"entities":{"Q11036":{"claims":{"P18":[{"mainsnak":{"datavalue":{"value":"Kraftwerk.jpg"}}}]}}}}
        """.data(using: .utf8)!
        #expect(ArtistPortraitLookup.p18FileName(fromEntityData: entityJSON, entity: "Q11036") == "Kraftwerk.jpg")
        let thumb = try #require(ArtistPortraitLookup.commonsThumbURL(fileName: "Kraftwerk.jpg"))
        #expect(thumb.absoluteString.contains("Special:FilePath/Kraftwerk.jpg"))
    }
}

/// M6: client-side "Top Songs" ranking (pure).
struct MusicPopularityTests {
    @Test("ranks by count desc, ties keep track order, zeros/nils drop")
    func ranking() {
        #expect(MusicPopularity.topIndices(playCounts: [3, nil, 7, 0, 7, 1]) == [2, 4, 0, 5])
        #expect(MusicPopularity.topIndices(playCounts: [nil, nil, 0]) == [])
        #expect(MusicPopularity.topIndices(playCounts: []) == [])
    }

    @Test("limit caps the section")
    func limit() {
        let counts: [Int?] = Array(1...20).map { $0 }
        #expect(MusicPopularity.topIndices(playCounts: counts, limit: 5)
                == [19, 18, 17, 16, 15])
    }
}

/// bdfe8dc/7b061c4: which artist image a surface renders — ONE pure decision
/// (the opt-out governs the WEB chain, never the library server's own image).
struct ArtistImagePolicyTests {
    private let server = URL(string: "https://navidrome.example/rest/getCoverArt?id=ar-1")!
    private let web = URL(string: "https://upload.wikimedia.org/portrait.jpg")!

    @Test("server image always wins and is never gated by the web opt-out")
    func serverWins() {
        for enabled in [true, false] {
            #expect(ArtistImagePolicy.source(serverImageURL: server, webImageURL: web,
                                             webEnabled: enabled) == .server)
            #expect(ArtistImagePolicy.rendered(serverImageURL: server, webImageURL: web,
                                               webEnabled: enabled) == server)
        }
    }

    @Test("web image renders only with the opt-in; off means NOT shown, not just not loaded")
    func webGated() {
        #expect(ArtistImagePolicy.rendered(serverImageURL: nil, webImageURL: web,
                                           webEnabled: true) == web)
        // The e3dabb3 rule: a cached web portrait must not render while off.
        #expect(ArtistImagePolicy.rendered(serverImageURL: nil, webImageURL: web,
                                           webEnabled: false) == nil)
        #expect(ArtistImagePolicy.source(serverImageURL: nil, webImageURL: web,
                                         webEnabled: false) == .none)
    }

    @Test("nothing anywhere → none (the color circle case)")
    func nothing() {
        #expect(ArtistImagePolicy.source(serverImageURL: nil, webImageURL: nil,
                                         webEnabled: true) == .none)
        #expect(ArtistImagePolicy.rendered(serverImageURL: nil, webImageURL: nil,
                                           webEnabled: true) == nil)
    }
}
#endif
