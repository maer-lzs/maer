// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Y51: free→premium episode matching — conservative by design (a missed match
/// is cheap, a wrong match moves progress onto the wrong episode).
struct PodcastPremiumMatchTests {
    private func episode(_ guid: String, title: String, audio: String, pubDate: Double = 0) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: title, audioURL: audio, pubDate: pubDate, duration: 0,
                       description: nil, imageURL: nil)
    }

    @Test("same-show test is normalized but strict; empty titles never match")
    func sameShow() {
        #expect(PodcastPremiumMatch.sameShow(titleA: "Die ZEIT: Verbrechen", titleB: "die zeit verbrechen"))
        #expect(PodcastPremiumMatch.sameShow(titleA: "Café Übermorgen", titleB: "Cafe Übermorgen!"))
        #expect(!PodcastPremiumMatch.sameShow(titleA: "Verbrechen", titleB: "Verbrechen von nebenan"))
        #expect(!PodcastPremiumMatch.sameShow(titleA: "", titleB: ""))
    }

    @Test("primary match: normalized enclosure URL wins regardless of guid/title")
    func enclosurePrimary() {
        let free = [episode("rss:f:1", title: "Folge 1", audio: "https://cdn.host/ep1.mp3?free=1")]
        let premium = [episode("rss:p:9", title: "Ganz anders", audio: "http://CDN.host/ep1.mp3")]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: premium) == ["rss:f:1": "rss:p:9"])
    }

    @Test("ambiguous premium enclosures poison the key — no match")
    func ambiguousEnclosure() {
        let free = [episode("f1", title: "A", audio: "https://h/e.mp3")]
        let premium = [episode("p1", title: "A", audio: "https://h/e.mp3"),
                       episode("p2", title: "B", audio: "https://h/e.mp3")]
        // Enclosure is ambiguous AND the title fallback stays conservative
        // (only p1 shares the title, so the unique-title rule may still apply) —
        // assert the enclosure path did NOT force p2.
        let m = PodcastPremiumMatch.episodeMatches(free: free, premium: premium)
        #expect(m["f1"] != "p2")
    }

    @Test("fallback: unique title on both sides within the 48h window")
    func titleDateFallback() {
        let base: Double = 1_700_000_000_000
        let free = [episode("f1", title: "Der große Fall", audio: "https://free.host/a.mp3", pubDate: base)]
        let premium = [episode("p1", title: "Der große Fall!", audio: "https://prem.host/x/a.mp3?tok=s",
                               pubDate: base + 12 * 3600 * 1000)]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: premium) == ["f1": "p1"])
    }

    @Test("fallback refuses: outside the window or duplicate titles")
    func fallbackConservative() {
        let base: Double = 1_700_000_000_000
        let free = [episode("f1", title: "Folge", audio: "https://free.host/a.mp3", pubDate: base)]
        let farPremium = [episode("p1", title: "Folge", audio: "https://prem.host/b.mp3",
                                  pubDate: base + 72 * 3600 * 1000)]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: farPremium).isEmpty)

        let dupPremium = [episode("p1", title: "Folge", audio: "https://prem.host/b.mp3", pubDate: base),
                          episode("p2", title: "Folge", audio: "https://prem.host/c.mp3", pubDate: base)]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: dupPremium).isEmpty)
    }
}

/// Y52: token-URL premium class — classification and masking (secrets never
/// shown or logged unmasked).
struct PodcastTokenFeedTests {
    @Test("token classification: known secret param with value; conservative otherwise")
    func classification() {
        #expect(PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?token=abc123"))
        #expect(PodcastSubscriptions.isTokenFeedURL("h.example/feed?auth=x&limit=5"))
        #expect(PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?SECRET=s"))
        #expect(!PodcastSubscriptions.isTokenFeedURL("https://h.example/feed"))
        #expect(!PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?page=2"))
        #expect(!PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?token="))   // empty value
    }

    @Test("masking replaces ONLY secret values, works on raw, normalized and composite strings")
    func masking() {
        #expect(PodcastSubscriptions.maskedFeedURL("https://h.example/feed?token=abc&page=2")
                == "https://h.example/feed?token=••••&page=2")
        #expect(PodcastSubscriptions.maskedFeedURL("h.example/feed?auth=x")
                == "h.example/feed?auth=••••")
        #expect(PodcastSubscriptions.maskedFeedURL("https://h.example/feed") == "https://h.example/feed")
        // Composite report string ("Title — url?token=…") still gets masked.
        #expect(PodcastSubscriptions.maskedFeedURL("Show — https://h.example/f?key=s")
                == "Show — https://h.example/f?key=••••")
    }

    @Test("premium test: token class counts even without stored credentials")
    func premiumIncludesTokenClass() {
        #expect(PodcastSubscriptions.isPremiumFeed("https://h.example/feed?token=abc"))
        #expect(PodcastSubscriptions.isPremiumFeed("https://www.patreon.com/rss/show"))
        #expect(!PodcastSubscriptions.isPremiumFeed("https://h.example/feed"))
    }
}
#endif
