// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One question, "does this address stay home", for the directory and the
/// shared export: a secret by any access name, a user and password before
/// the host, the person's own server (a mirrored Pinchflat feed, an entered
/// host), an unreadable sign-in; and an episode's own address with access
/// leaves the file too.
struct ExportStaysHomeTests {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "export-home-\(UUID().uuidString)")!
    }

    /// Open feeds of the big hosts and paths that only look like access.
    static let openPaths = [
        "https://feeds.acast.com/public/shows/5e7b777ba085cbe7192b0607",
        "https://feeds.simplecast.com/54nAGcIl",
        "https://feeds.megaphone.fm/GLT1412515089",
        "https://feeds.libsyn.com/12345/rss",
        "https://example.com/keynote/feed.xml",
        "https://example.com/podcast/key",
        "https://example.com/private",
        "https://example.com/feed.xml?q=/private/x",
        "https://example.com/feed.xml#/token/x",
    ]

    /// Paths that carry access: a whole segment that says it, another behind.
    static let secretPaths = [
        "https://api.substack.com/feed/podcast/123/private/0f1e2d3c-aaaa-bbbb-cccc-1234567890ab.rss",
        "https://example.com/token/abc123/feed.xml",
        "example.com/Secret/xyz",
        "https://example.com/feeds/AUTH/x?format=mp3",
        "https://example.com//key//abc",
    ]

    @Test("a path carries access only by a whole segment that says it, with another behind; long ids alone do not")
    func aPathCarriesAccessByAWholeSegment() {
        for raw in Self.openPaths {
            #expect(!PodcastFeedAddress.carriesAccess(raw), "\(raw) was held back")
        }
        for raw in Self.secretPaths {
            #expect(PodcastFeedAddress.carriesAccess(raw), "\(raw) left the device")
            #expect(!PodcastFeedAddress.isTokenFeedURL(raw), "a secret in the path made the feed premium")
        }
        #expect(PodcastSubscriptions.staysHome(Self.secretPaths[0], defaults: suite(), ownHosts: []),
                "the directory and the export are asked past the path")
    }

    @Test("secret in the address: other names, user and password without a scheme; an ordinary address does not")
    func anAddressCarriesAccessByAnyName() {
        for raw in ["https://feeds.example/show.xml?api_key=abc", "https://feeds.example/show.xml?access_token=abc",
                    "https://feeds.example/show.xml?x=1&Password=abc", "https://feeds.example/show.xml?sig=abc",
                    "anna:geheim@feeds.example/show.xml", "https://anna:geheim@feeds.example/show.xml"] {
            #expect(PodcastFeedAddress.carriesAccess(raw), "\(raw) left the device")
        }
        for raw in ["https://feeds.example/show.xml", "https://feeds.example/show.xml?format=mp3&page=2",
                    "https://feeds.example/show.xml?api_key="] {
            #expect(!PodcastFeedAddress.carriesAccess(raw), "\(raw) was held back")
        }
        // A word counts whole, never inside another.
        for name in ["author", "keyword", "design", "passage", "monkey", "sigma"] {
            #expect(!PodcastFeedAddress.carriesAccess("https://feeds.example/show.xml?\(name)=x"), "\(name) was read as access")
        }
        for name in ["api_key", "apiKey", "accessToken", "X-Auth-Token", "session_id", "sid", "auth", "apikey", "user.pass"] {
            #expect(PodcastFeedAddress.carriesAccess("https://feeds.example/show.xml?\(name)=x"), "\(name) was not read as access")
        }
        // Written as one word.
        for name in ["authtoken", "accesskey", "apitoken", "sessionid", "secretkey", "privatekey", "userpass", "passcode",
                     "accesstoken", "clientsecret", "authkey", "sessiontoken", "passphrase", "refreshtoken", "oauth"] {
            #expect(PodcastFeedAddress.carriesAccess("https://feeds.example/show.xml?\(name)=x"), "\(name) was not read as access")
        }
        for name in ["pwd", "hmac", "user_pwd", "userpwd", "hmacsha256", "X-Hmac"] {
            #expect(PodcastFeedAddress.carriesAccess("https://feeds.example/show.xml?\(name)=x"), "\(name) was not read as access")
        }
        #expect(!PodcastFeedAddress.isTokenFeedURL("https://feeds.example/show.xml?api_key=abc"),
                "a wider access name made the feed premium")
    }

    @Test("stays home: a mirrored feed and a feed on the own server, an open feed does not")
    func theOwnServerStaysHome() {
        let defaults = suite()
        let mirrored = "https://pinchflat.home.example/feeds/abc.xml"
        defaults.set([PodcastIdentity.feedKey(mirrored)], forKey: AppStorageKeys.pinchflatMirroredFeedKeys)
        #expect(PodcastSubscriptions.staysHome(mirrored, defaults: defaults, ownHosts: []), "a mirrored feed went out")
        #expect(PodcastSubscriptions.staysHome("http://abs.home.example/feed/1", defaults: defaults,
                                               ownHosts: ["abs.home.example"]), "a feed on the own server went out")
        #expect(!PodcastSubscriptions.staysHome("https://feeds.open.example/show.xml", defaults: defaults,
                                                ownHosts: ["abs.home.example"]), "an open feed was held back")
    }

    @Test("Export: the address of an episode with access does not travel along, the state with its guid does")
    func anEpisodeAddressWithAccessStaysOut() {
        let show = (title: "Open", feedURL: "https://feeds.open.example/show.xml")
        let state = ForeignListeningState(feedURL: show.feedURL, episodeGUID: "g1",
                                          enclosureURL: "https://cdn.example/e1.mp3?token=SECRET1",
                                          episodeLink: "https://anna:SECRET2@site.example/e1",
                                          episodeTitle: "One", position: 100, finished: false)
        let kept = OPMLExport.states([state], for: [show])
        #expect(kept.map(\.episodeGUID) == ["g1"])
        #expect(kept.first?.enclosureURL == nil && kept.first?.episodeLink == nil)
        let doc = OPMLExport.document(shows: [show], states: kept, generatedAt: Date(timeIntervalSince1970: 0))
        #expect(!doc.contains("SECRET1") && !doc.contains("SECRET2"), "an episode's access went into the file")
    }
}
#endif
