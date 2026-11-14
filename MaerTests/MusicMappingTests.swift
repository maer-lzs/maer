// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

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

/// Play-count bars beside each track (pure).
struct MusicPopularityTests {
    @Test("three bars from two thirds, two from one third, one below, none at zero, the limits included")
    func barsByThirds() {
        #expect(MusicPopularity.bars(playCounts: [9, 6, 5, 3, 2, 1, 0, nil]) == [3, 3, 2, 2, 1, 1, 0, 0],
                "6 of 9 is exactly two thirds, 3 of 9 exactly one third")
        #expect(MusicPopularity.bars(playCounts: [4]) == [3], "the most played has three")
    }

    @Test("without numbers from the server no bars, and every title keeps its place")
    func noCountsNoBars() {
        #expect(MusicPopularity.bars(playCounts: [nil, nil, 0]) == [0, 0, 0])
        #expect(MusicPopularity.bars(playCounts: []) == [])
    }

    @Test("the album page shows the bars in the one line, the section above it is gone", .needsTheSources)
    func thePageWiresTheBars() throws {
        let flat = try FetchAnswerTests.squeezedSource("Sources/Views/Music/MusicAlbumView.swift")
        #expect(flat.contains("MusicPopularity.bars(playCounts: music.trackPlayCounts(forItemId: item.id))"))
        #expect(flat.contains("bars: popularity.indices.contains(index) ? popularity[index] : 0)"))
        #expect(!flat.contains("Your most played"), "the section above the list is back")
        #expect(PopularityBars.label(3) != PopularityBars.label(1), "the level is said in words")
    }

    @Test("with large type the title stands on its own line and wraps, bars and duration below", .needsTheSources)
    func theRowGivesTheTitleItsLine() throws {
        let flat = try FetchAnswerTests.squeezedSource("Sources/Views/Music/PopularityBars.swift")
        let large = try #require(flat.range(of: "if typeSize.isAccessibilitySize {"))
        let small = try #require(flat.range(of: "} else {", range: large.upperBound..<flat.endIndex))
        let branch = flat[large.upperBound..<small.lowerBound]
        #expect(branch.contains("VStack(alignment: .trailing"), "bars and duration stand below, on the right")
        #expect(branch.contains("Text(title).frame(maxWidth: .infinity"), "the title takes the whole line")
        #expect(!branch.contains("lineLimit"), "the title wraps instead of being cut")
    }
}

/// Which artist image a surface renders. ONE pure decision
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
        // A cached web portrait must not render while off.
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
