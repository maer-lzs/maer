// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The picture the server reports for a feed goes along when a show is
/// created on Audiobookshelf.
struct ABSPodcastFeedTests {
    /// The answer of `POST /api/podcasts/feed` in the server's shape
    /// (`podcastUtils.js`, Audiobookshelf 2.37): the picture is `image`.
    static let serverAnswer = Data("""
    {"podcast":{"metadata":{"title":"Ein Feed","author":"Jemand","description":"Worum es geht",
    "releaseDate":"2026-01-01","genres":["Kunst"],"language":"de","explicit":"false",
    "podcastType":"episodic","image":"https://feed.example.lan/cover.jpg",
    "feedUrl":"https://feed.example.lan/rss","itunesPageUrl":"","itunesId":"","itunesArtistId":"",
    "type":"episodic"},"episodes":[]}}
    """.utf8)

    @Test("the picture from the server's answer goes along when a show is created")
    func theServersPictureGoesAlong() throws {
        let metadata = try JSONDecoder().decode(PodcastFeedResponse.self, from: Self.serverAnswer).podcast.metadata
        #expect(metadata.image == "https://feed.example.lan/cover.jpg", "the picture under the server's name was not read")
        #expect(metadata.title == "Ein Feed" && metadata.feedUrl == "https://feed.example.lan/rss")
    }

    @Test("the measured answer of the server carries the picture under image")
    func theMeasuredAnswerCarriesThePicture() throws {
        // A measured answer of the test server, byte for byte; it is no
        // shared case file, so it lives beside them, not among them.
        let data = try CorpusFixture.data("podcast_feed", ext: "json", subdirectory: "ServerAnswers/abs")
        let metadata = try JSONDecoder().decode(PodcastFeedResponse.self, from: data).podcast.metadata
        #expect(metadata.image == "http://host.docker.internal:13379/cover.jpg")
        #expect(metadata.title == "Stille-Funk")
    }

    @Test("creating a show and the catch-up carry this picture", .needsTheSources)
    func creationAndFollowUpCarryIt() throws {
        let client = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/APIClient.swift"), encoding: .utf8))
        #expect(client.contains(#""imageUrl": metadata.image ?? """#), "the creation sends another field")
        let provider = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/ABSPodcastProvider.swift"), encoding: .utf8))
        #expect(provider.contains("cover: coverURL ?? metadata.image)"), "the follow-up lost the server's picture")
    }
}
#endif
