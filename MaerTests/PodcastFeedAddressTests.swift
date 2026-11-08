// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A directory hands out an `http://` address for a feed or a cover that
/// answers identically over https, so a foreign address is raised; a server
/// the person entered keeps its scheme. The cases that raise name no own
/// server (`ownHosts: []`), so the register of the test's host plays no part.
struct PodcastFeedAddressTests {
    /// The image door raises a feed's cleartext image address the same
    /// way, and keeps host, path and query.
    @Test("eine http-Bildadresse geht als https hinaus, sonst unveraendert")
    func imageAddressIsRaised() {
        let raised = PodcastFeedAddress.upgraded(URL(string: "http://ichef.bbci.co.uk/images/ic/3000x3000/p0.jpg?v=1")!, ownHosts: [])
        #expect(raised.absoluteString == "https://ichef.bbci.co.uk/images/ic/3000x3000/p0.jpg?v=1")
        let kept = PodcastFeedAddress.upgraded(URL(string: "https://files.relay.fm/a.png")!)
        #expect(kept.absoluteString == "https://files.relay.fm/a.png")
    }

    @Test("das Geraet selbst wird nicht gehoben: eine Adresse auf dem Loopback bleibt http, jeder andere Host nicht")
    func loopbackStaysCleartext() {
        for host in ["127.0.0.1:8811", "localhost:8080", "[::1]:9"] {
            let url = URL(string: "http://\(host)/cover.png")!
            #expect(PodcastFeedAddress.upgraded(url, ownHosts: []) == url, "\(host) was raised")
        }
        #expect(PodcastFeedAddress.upgraded(URL(string: "http://127.0.0.2/cover.png")!, ownHosts: []).scheme == "https",
                "a neighbour of the loopback is not the device")
        #expect(PodcastFeedAddress.upgraded(URL(string: "http://192.168.178.5/cover.png")!, ownHosts: []).scheme == "https")
    }

    @Test("ein eigener Server behaelt http, fuer Cover und Feeds; ein fremder Host daneben wird gehoben")
    func anOwnServerKeepsItsScheme() throws {
        let own: Set<String> = ["100.64.0.7", "nas.local"]
        for address in ["http://100.64.0.7:13378/api/items/1/cover", "http://nas.local:4533/rest/getCoverArt?id=1"] {
            let url = try #require(URL(string: address))
            #expect(PodcastFeedAddress.upgraded(url, ownHosts: own) == url, "\(address) was raised")
        }
        #expect(PodcastFeedAddress.requestURL("http://nas.local:8945/feeds/channel.xml", ownHosts: own)?.absoluteString
                == "http://nas.local:8945/feeds/channel.xml", "a feed on an own server was raised")
        #expect(PodcastFeedAddress.upgraded(try #require(URL(string: "http://100.64.0.8/cover.jpg")), ownHosts: own).scheme == "https",
                "a neighbour of an own server is not it")
        #expect(PodcastFeedAddress.requestURL("http://feeds.example.org/show", ownHosts: own)?.scheme == "https")
    }

    @Test("die Hosts der eigenen Server, auch aus Eintraegen ohne Schema")
    func theHostsOfTheOwnServers() throws {
        #expect(KnownServers.host(of: "http://100.64.0.7:13378") == "100.64.0.7")
        #expect(KnownServers.host(of: "100.64.0.7:13378") == "100.64.0.7")
        #expect(KnownServers.host(of: "nas.local:4533") == "nas.local")
        #expect(KnownServers.host(of: "https://Audio.Example.com/abs/") == "audio.example.com")
        #expect(KnownServers.host(of: "https://name:secret@books.example") == "books.example")
        #expect(KnownServers.host(of: "") == nil)
        let defaults = try #require(UserDefaults(suiteName: "own-hosts-\(UUID().uuidString)"))
        KnownServers.remember("100.64.0.7:13378", service: .audiobookshelf, now: 1, defaults: defaults)
        KnownServers.remember("http://nas.local:4533", service: .subsonic, now: 2, defaults: defaults)
        #expect(KnownServers.hosts(defaults: defaults) == ["100.64.0.7", "nas.local"])
    }

    @Test("ein eingerichteter Server, dessen Vorschlag entfernt ist, bleibt eigen und behaelt http")
    func aSetUpServerStaysOwnWithoutItsSuggestion() throws {
        let defaults = try #require(UserDefaults(suiteName: "own-hosts-\(UUID().uuidString)"))
        let entry = KnownServer(url: "http://100.64.0.7:13378", service: .audiobookshelf, lastSuccessAt: 1)
        KnownServers.remember(entry.url, service: entry.service, now: 1, defaults: defaults)
        KnownServers.forget(entry, defaults: defaults)
        #expect(KnownServers.hosts(defaults: defaults).isEmpty, "the suggestion is still in the register")
        let own = KnownServers.ownHosts(defaults: defaults, configured: ["http://100.64.0.7:13378", "nas.local:4533"])
        #expect(own == ["100.64.0.7", "nas.local"])
        let cover = try #require(URL(string: "http://100.64.0.7:13378/api/items/1/cover"))
        #expect(PodcastFeedAddress.upgraded(cover, ownHosts: own) == cover, "the set-up server's cover was raised")
    }

    @Test("Messung: die eigenen Hosts je Cover-Anfrage, 200 Aufrufe hintereinander")
    func theOwnHostsCostPerRequest() {
        let started = ContinuousClock.now
        var hosts = 0
        for _ in 0..<200 { hosts += KnownServers.ownHosts().count }
        let elapsed = ContinuousClock.now - started
        let micros = Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
        print(String(format: "COVERHOSTS calls=200 us_per_call=%.1f hosts=%d", micros / 200, hosts / 200))
        #expect(micros / 200 < 1000, "over a millisecond per cover request: a held image of the hosts belongs in")
    }

    @Test("eine http-Adresse geht als https-Anfrage raus")
    func cleartextIsRaised() {
        #expect(PodcastFeedAddress.requestURL("http://feeds.example.org/show", ownHosts: [])?.absoluteString
                == "https://feeds.example.org/show")
        #expect(PodcastFeedAddress.upgraded(URL(string: "http://feeds.example.org/show")!, ownHosts: [])
                .absoluteString == "https://feeds.example.org/show")
        // Case is not a licence to smuggle cleartext through.
        #expect(PodcastFeedAddress.requestURL("HTTP://Feeds.Example.org/Show", ownHosts: [])?.scheme == "https")
    }

    @Test("Pfad, Abfrage und Gross-/Kleinschreibung bleiben unangetastet")
    func onlyTheSchemeChanges() {
        let raised = PodcastFeedAddress.requestURL("http://feeds.example.org/Show?token=AbC&x=1", ownHosts: [])
        // The address is an identity: lowercasing it would turn a token into a
        // different one. Only the scheme is this rule's business.
        #expect(raised?.absoluteString == "https://feeds.example.org/Show?token=AbC&x=1")
    }

    @Test("schema-lose Eingabe wird https, https bleibt https")
    func defaultsAndPassThrough() {
        #expect(PodcastFeedAddress.requestURL("feeds.example.org/show")?.absoluteString
                == "https://feeds.example.org/show")
        #expect(PodcastFeedAddress.requestURL("https://feeds.example.org/show")?.absoluteString
                == "https://feeds.example.org/show")
        #expect(PodcastFeedAddress.requestURL("  https://feeds.example.org/show  ")?.absoluteString
                == "https://feeds.example.org/show")
        #expect(PodcastFeedAddress.requestURL("") == nil)
        #expect(PodcastFeedAddress.requestURL("   ") == nil)
    }

    @Test("ein fremdes Schema ist nicht Sache dieser Regel")
    func foreignSchemesPassThrough() {
        // Not web transport at all. Raising it would invent an address.
        #expect(PodcastFeedAddress.requestURL("file:///tmp/feed.xml")?.scheme == "file")
        #expect(PodcastFeedAddress.upgraded(URL(string: "itpc://example.org/f")!).scheme == "itpc")
    }

    @Test("die Erhebung kann keinen Abo-Zwilling erzeugen")
    func identityIsSchemeFree() {
        // The subscription identity strips the scheme, so raising the REQUEST
        // cannot split one subscription into two. Without this the fix would
        // have been a data bug in disguise.
        #expect(PodcastIdentity.normalizeFeedURL("http://feeds.example.org/show")
                == PodcastIdentity.normalizeFeedURL("https://feeds.example.org/show"))
    }
}
#endif
