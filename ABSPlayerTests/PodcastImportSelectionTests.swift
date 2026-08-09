// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// S21: import only ACTIVE (subscribed/followed) Apple Podcasts shows, not the
/// whole history; count paid/exclusive subscriptions (subscribed but no public
/// feed) for a hint instead of dropping them silently.
struct PodcastImportSelectionTests {
    private func show(_ feed: String?, subscribed: Bool) -> PodcastImport.AppleShow {
        PodcastImport.AppleShow(feedURL: feed, isSubscribed: subscribed)
    }

    @Test("only subscribed shows with a feed import; paid subs counted; history ignored")
    func selection() {
        let shows = [
            show("https://a.com/feed", subscribed: true),   // active → import
            show("https://b.com/feed", subscribed: false),  // unsubscribed → ignore
            show(nil, subscribed: true),                    // paid (no feed) → count
            show("", subscribed: true),                     // paid (empty feed) → count
            show(nil, subscribed: false),                   // old unsubscribed, no feed → ignore
        ]
        let r = PodcastImport.selectImportable(shows)
        #expect(r.feeds == ["https://a.com/feed"])
        #expect(r.paidUnimportable == 2)
    }

    @Test("all-subscribed fallback (old schema) imports every feed, no paid noise")
    func fallback() {
        let shows = [show("https://a.com/f", subscribed: true), show("https://b.com/f", subscribed: true)]
        let r = PodcastImport.selectImportable(shows)
        #expect(r.feeds.count == 2)
        #expect(r.paidUnimportable == 0)
    }
}
#endif
