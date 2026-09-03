// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The measured case: a directory hands out an `http://` address for a feed
/// that answers identically over https. ATS allows cleartext for MEDIA only,
/// so the request never left the device and a LIVING feed reported itself as
/// unloadable.
struct PodcastFeedAddressTests {
    /// The image door raises a feed's cleartext image address the same
    /// way, and keeps host, path and query.
    @Test("eine http-Bildadresse geht als https hinaus, sonst unveraendert")
    func imageAddressIsRaised() {
        let raised = PodcastFeedAddress.upgraded(URL(string: "http://ichef.bbci.co.uk/images/ic/3000x3000/p0.jpg?v=1")!)
        #expect(raised.absoluteString == "https://ichef.bbci.co.uk/images/ic/3000x3000/p0.jpg?v=1")
        let kept = PodcastFeedAddress.upgraded(URL(string: "https://files.relay.fm/a.png")!)
        #expect(kept.absoluteString == "https://files.relay.fm/a.png")
    }


    @Test("eine http-Adresse geht als https-Anfrage raus")
    func cleartextIsRaised() {
        #expect(PodcastFeedAddress.requestURL("http://feeds.example.org/show")?.absoluteString
                == "https://feeds.example.org/show")
        #expect(PodcastFeedAddress.upgraded(URL(string: "http://feeds.example.org/show")!)
                .absoluteString == "https://feeds.example.org/show")
        // Case is not a licence to smuggle cleartext through.
        #expect(PodcastFeedAddress.requestURL("HTTP://Feeds.Example.org/Show")?.scheme == "https")
    }

    @Test("Pfad, Abfrage und Gross-/Kleinschreibung bleiben unangetastet")
    func onlyTheSchemeChanges() {
        let raised = PodcastFeedAddress.requestURL("http://feeds.example.org/Show?token=AbC&x=1")
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
        #expect(PodcastSubscriptions.normalizeFeedURL("http://feeds.example.org/show")
                == PodcastSubscriptions.normalizeFeedURL("https://feeds.example.org/show"))
    }
}
#endif
