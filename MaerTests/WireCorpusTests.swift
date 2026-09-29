// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// THE shared wire-corpus (`Fixtures/WireCorpus`). The five canonical broken
/// server answers (captive-portal HTML, half JSON, empty body, foreign JSON,
/// foreign array) run against every client's decode layer. Contract per the
/// badPayload-Lehre: "connection went weird" must THROW (or land in a visible
/// error state), never decay to a silent empty list. Where a client
/// deliberately tolerates a shape, the case documents it.
struct WireCorpusTests {

    private func fixture(_ name: String, ext: String) throws -> Data {
        try CorpusFixture.data(name, ext: ext, subdirectory: "WireCorpus")
    }

    // MARK: - HTTP 200 + well-formed XML that is NOT a feed

    /// The real answer podcastle.org/feed/podcast/ gave on 09.08., frozen:
    /// `<error><code>wp_die</code><title>Database Error</title>`. The parser
    /// used to build a subscribable show out of it (title "Database Error",
    /// subscribe button) because the document was well-formed and had a
    /// title. Well-formedness is not feed-ness.
    @Test("wp_die error page is NOT a feed (root element decides)")
    func wpDieErrorPageIsNotAFeed() throws {
        let data = try CorpusFixture.data("wp-die-error", ext: "xml", subdirectory: "WireCorpus")
        let show = RSSFeedParser(feedURL: "https://podcastle.org/feed/podcast/").parse(data)
        #expect(show == nil, "an error page must not become a show")
    }

    @Test("a feed root is still accepted (no over-blocking)")
    func realFeedStillParses() throws {
        let data = try CorpusFixture.data("minimal-valid", ext: "xml", subdirectory: "RSSEdgeCorpus")
        let show = RSSFeedParser(feedURL: "https://example.invalid/feed").parse(data)
        #expect(show != nil)
        #expect(!(show?.episodes.isEmpty ?? true))
    }

    private var brokenBodies: [(String, String)] {
        [("portal", "html"), ("half", "json"), ("empty", "json"), ("foreign", "json")]
    }

    // MARK: Radio Browser (decode failures throw → mirror failover)

    @Test("RadioBrowser states: every broken body throws (no silent empty region list)")
    func radioStatesThrow() throws {
        for (name, ext) in brokenBodies {
            let data = try fixture(name, ext: ext)
            #expect(throws: (any Error).self, "\(name).\(ext) must throw") {
                _ = try RadioBrowserClient.decodeStates(data)
            }
        }
        // Documented tolerance: a foreign ARRAY decodes to entries without a
        // name and filters to []. An array answer is shape-compatible.
        let foreignArray = try fixture("foreign-array", ext: "json")
        #expect(try RadioBrowserClient.decodeStates(foreignArray).isEmpty)
    }

    @Test("RadioBrowser countries: broken bodies throw")
    func radioCountriesThrow() throws {
        for (name, ext) in brokenBodies {
            let data = try fixture(name, ext: ext)
            #expect(throws: (any Error).self, "\(name).\(ext) must throw") {
                _ = try RadioBrowserClient.decodeCountries(data)
            }
        }
    }

    // MARK: gpodder (hardened earlier. The corpus pins it)

    @Test("gpodder parseSubscriptions: every broken body is badPayload")
    func gpodderSubscriptionsThrow() throws {
        for (name, ext) in brokenBodies + [("foreign-array", "json")] {
            let data = try fixture(name, ext: ext)
            #expect(throws: (any Error).self, "\(name).\(ext) must throw") {
                _ = try GPodderClient.parseSubscriptions(data)
            }
        }
    }

    // MARK: Subsonic envelope (decode inside `get`. Throws by construction)

    @Test("Subsonic envelope: broken bodies fail the decode (client error path, not empty)")
    func subsonicEnvelopeThrows() throws {
        for (name, ext) in brokenBodies {
            let data = try fixture(name, ext: ext)
            #expect(throws: (any Error).self, "\(name).\(ext) must throw") {
                _ = try JSONDecoder().decode(SubsonicEnvelope.self, from: data)
            }
        }
    }

    /// Funkwhale 1.2.10 sends every id as a NUMBER (measured on a live
    /// server: id, artistId, albumId in getArtists, getAlbumList2,
    /// getAlbum, search3). One strict String decode on artistId threw the
    /// whole album away and left the library empty.
    @Test("Funkwhale: numeric ids on album and songs decode to strings, nothing is dropped")
    func funkwhaleNumericIdsDecode() throws {
        let data = try fixture("funkwhale-album-numeric-ids", ext: "json")
        let env = try JSONDecoder().decode(SubsonicEnvelope.self, from: data)
        let album = try #require(env.subsonicResponse.album)
        #expect(album.id == "2")
        #expect(album.artistId == "1", "the numeric artistId must survive as a string")
        #expect(album.song?.count == 2)
        #expect(album.song?.first?.albumId == "2")
        // Rot-Probe: the strict form (String only) throws on this body.
        struct Strict: Decodable {
            struct R: Decodable { struct A: Decodable { let artistId: String }; let album: A }
            enum CodingKeys: String, CodingKey { case r = "subsonic-response" }
            let r: R
        }
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Strict.self, from: data) }
    }

    // MARK: Podcast subscriptions store (corrupt ≠ missing)

    @Test("Corrupt subscriptions store is preserved, never silently emptied")
    func corruptStorePreserved() throws {
        // The fix moves an undecodable store aside as .corrupt before the
        // session starts empty. This pins the DECODE side: a corpus body
        // never decodes into an (empty) show list.
        for (name, ext) in brokenBodies {
            let data = try fixture(name, ext: ext)
            #expect((try? JSONDecoder().decode([PodcastShow].self, from: data)) == nil,
                    "\(name).\(ext) must not decode into a show list")
        }
    }
}
#endif
