// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The sign-in of a private feed is bound to the feed's own host: an
/// episode file on another host, or on the same host over http when the feed
/// is https, is asked without it.
@MainActor
struct FeedSignInHostTests {
    private static func address(_ text: String) throws -> URL {
        try #require(URL(string: text))
    }

    @Test("die Anmeldung eines Feeds geht nur an den Host des Feeds und nie von https hinunter auf http")
    func theSignInTravelsOnlyToTheFeedsOwnHost() throws {
        let feed = try Self.address("https://Feeds.Example.org/private/show.xml")
        #expect(PodcastFeedAuth.mayCarry(feed: feed, target: try Self.address("https://feeds.example.org/audio/1.mp3")))
        #expect(PodcastFeedAuth.mayCarry(feed: feed, target: try Self.address("https://FEEDS.example.ORG/audio/1.mp3")),
                "the host is compared without case")
        #expect(!PodcastFeedAuth.mayCarry(feed: feed, target: try Self.address("https://cdn.example.org/audio/1.mp3")),
                "another host of the same domain is another host")
        #expect(!PodcastFeedAuth.mayCarry(feed: feed, target: try Self.address("https://counter.example.com/r/feeds.example.org/1.mp3")),
                "a counting service in front gets no sign-in")
        #expect(!PodcastFeedAuth.mayCarry(feed: feed, target: try Self.address("http://feeds.example.org/audio/1.mp3")),
                "never from https down to http")
        let plain = try Self.address("http://feeds.example.org/private/show.xml")
        #expect(PodcastFeedAuth.mayCarry(feed: plain, target: try Self.address("https://feeds.example.org/audio/1.mp3")))
        #expect(PodcastFeedAuth.mayCarry(feed: plain, target: try Self.address("http://feeds.example.org/audio/1.mp3")),
                "a feed that is http itself is asked as it is")
        #expect(!PodcastFeedAuth.mayCarry(feed: nil, target: try Self.address("https://feeds.example.org/audio/1.mp3")),
                "a feed whose address is not known binds its sign-in to no host")
    }

    @Test("die Kopfzeilen einer Folge je Adresse: eigener Host mit Anmeldung, fremder ohne, unlesbar nur am eigenen Host unbekannt")
    func theHeadersPerAddress() throws {
        let key = "feed-\(UUID().uuidString)"
        let episode = "rss:\(key):guid-1"
        let feed = try Self.address("https://feeds.example.org/private/show.xml")
        let own = try Self.address("https://feeds.example.org/audio/1.mp3")
        let foreign = try Self.address("https://cdn.example.net/audio/1.mp3")
        let downgraded = try Self.address("http://feeds.example.org/audio/1.mp3")
        PodcastFeedAuth.$reading.withValue(FeedAccessUnknownTests.keychain(key, .value("anna\ngeheim"))) {
            #expect(PodcastFeedAuth.streamHeaders(forItemId: episode, feed: feed, to: own)?["Authorization"]
                    == "Basic YW5uYTpnZWhlaW0=")
            #expect(PodcastFeedAuth.streamHeaders(forItemId: episode, feed: feed, to: foreign) == [:],
                    "the sign-in went to a foreign host")
            #expect(PodcastFeedAuth.streamHeaders(forItemId: episode, feed: feed, to: downgraded) == [:],
                    "the sign-in went from https down to http")
            #expect(PodcastFeedAuth.streamHeaders(forItemId: episode, feed: nil, to: own) == [:])
        }
        PodcastFeedAuth.$reading.withValue(FeedAccessUnknownTests.keychain(key, .unreadable)) {
            #expect(PodcastFeedAuth.streamHeaders(forItemId: episode, feed: feed, to: own) == nil,
                    "an own address waits for a sign-in that cannot be read now")
            #expect(PodcastFeedAuth.streamHeaders(forItemId: episode, feed: feed, to: foreign) == [:],
                    "a foreign address needs no sign-in, so it waits for none")
        }
    }

    @Test("ueber das Protokoll: ohne Adresse nie die Anmeldung, mit Adresse nur am Host des Feeds")
    func throughTheProtocol() throws {
        let key = "feed-\(UUID().uuidString)"
        let episode = "rss:\(key):guid-1"
        let rss: any AudioProvider = RSSProvider.shared
        PodcastFeedAuth.$reading.withValue(FeedAccessUnknownTests.keychain(key, .value("anna\ngeheim"))) {
            #expect(rss.streamAuthHeaders(forItemId: episode) == [:], "the form without an address hands out the sign-in")
            // The feed of this key is not subscribed: its address is not
            // known, so no address is its own.
            #expect(rss.streamAuthHeaders(forItemId: episode, to: URL(fileURLWithPath: "/dev/null")) == [:])
        }
    }

    /// Every reader of the headers asks the form with the address; the form
    /// without one is asked only for whether the sign-in can be read.
    static let readers: [String: (withAddress: Int, readableOnly: Int, reason: String)] = [
        "PlayerViewModel.swift": (3, 0, reason: "the queue asks per track, the planner per address it plans (the track's and the end of its redirects), and the question whether a track needs a plan, each for the address in question"),
        "DownloadManager.swift": (1, 1, reason: "per file for its address; before the first file only whether the sign-in can be read"),
        "MusicUnion.swift": (1, 1, reason: "forwards both forms to the title's own source"),
        "ABSPodcastProvider.swift": (1, 0, reason: "forwards the form with the address to the server's client"),
        "AudioProvider.swift": (0, 1, reason: "the default of the form with the address answers with the item's own"),
    ]

    @Test("das Token von Audiobookshelf geht nur an den eigenen Server, auch wenn der Server eine fremde Adresse nennt")
    func theServersTokenStaysWithItsServer() throws {
        let server = try Self.address("https://abs.example.org/audiobookshelf")
        let client = APIClient(baseURL: server, token: "T")
        let abs: any AudioProvider = client
        let own = try #require(client.streamURL(forContentPath: "/api/items/1/file/2"))
        #expect(abs.streamAuthHeaders(forItemId: "book-1", to: own)?["Authorization"] == "Bearer T")
        // The server names an absolute address on another host.
        let foreign = try #require(client.streamURL(forContentPath: "https://cdn.example.net/audio/2.mp3"))
        #expect(foreign.host == "cdn.example.net")
        #expect(abs.streamAuthHeaders(forItemId: "book-1", to: foreign) == [:], "the token went to a foreign host")
        let downgraded = try #require(client.streamURL(forContentPath: "http://abs.example.org/audio/2.mp3"))
        #expect(abs.streamAuthHeaders(forItemId: "book-1", to: downgraded) == [:], "the token went from https down to http")
    }

    @Test("Pinchflat gibt seine Anmeldung nur Feeds auf dem eigenen Host", .needsTheSources)
    func pinchflatsSignInStaysWithItsHost() throws {
        let client = try FetchAnswerTests.squeezedSource("Sources/Networking/PinchflatClient.swift")
        #expect(client.contains("if let login, let address = PodcastFeedAddress.requestURL(feedURL), SignInReach.mayCarry(own: PinchflatClient.serverURL, target: address) {"),
                "a feed on another host inherits the server's sign-in")
        let server = try Self.address("https://pinchflat.example.org")
        #expect(SignInReach.mayCarry(own: server, target: try Self.address("https://pinchflat.example.org/sources/1/feed.xml")))
        #expect(!SignInReach.mayCarry(own: server, target: try Self.address("https://other.example.org/feed.xml")))
    }

    @Test("jeder Leser der Kopfzeilen fragt die Form mit der Adresse", .needsTheSources)
    func everyReaderAsksWithTheAddress() {
        var found: [String: (withAddress: Int, readableOnly: Int)] = [:]
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            for line in SyncContractFenceTests.stripped(text).split(separator: "\n")
            where line.contains("streamAuthHeaders(forItemId:") && !line.contains("func streamAuthHeaders(") {
                var entry = found[file] ?? (0, 0)
                if line.contains(", to: ") { entry.withAddress += 1 } else { entry.readableOnly += 1 }
                found[file] = entry
            }
        }
        #expect(found.keys.sorted() == Self.readers.keys.sorted(), "the readers of the headers: \(found.keys.sorted())")
        for (file, expected) in Self.readers {
            #expect(found[file]?.withAddress == expected.withAddress && found[file]?.readableOnly == expected.readableOnly,
                    "\(file): \(String(describing: found[file]))")
        }
    }

    @Test("die Form ohne Adresse traegt bei einem Feed nie die Anmeldung", .needsTheSources)
    func theFormWithoutAnAddressNeverCarriesTheSignIn() throws {
        let rss = try FetchAnswerTests.squeezedSource("Sources/Providers/RSSProvider.swift")
        #expect(rss.contains("PodcastFeedAuth.streamHeaders(forItemId: itemId) == nil ? nil : [:]"))
        #expect(rss.contains("PodcastFeedAuth.streamHeaders(forItemId: itemId, feed: feedAddress(ofItemId: itemId), to: url)"))
        let auth = try FetchAnswerTests.squeezedSource("Sources/Networking/PodcastFeedAuth.swift")
        #expect(auth.contains("guard mayCarry(feed: feed, target: target) else { return [:] }"))
    }
}
#endif
