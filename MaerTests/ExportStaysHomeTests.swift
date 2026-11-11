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

    @Test("Geheimnis in der Adresse: andere Namen, Benutzer und Passwort ohne Schema; eine gewoehnliche Adresse nicht")
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
        #expect(!PodcastFeedAddress.isTokenFeedURL("https://feeds.example/show.xml?api_key=abc"),
                "a wider access name made the feed premium")
    }

    @Test("bleibt zu Hause: ein gespiegelter Feed und ein Feed auf dem eigenen Server, ein offener Feed nicht")
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

    @Test("Export: die Adresse einer Folge mit Zugang reist nicht mit, der Stand mit seiner guid schon")
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
