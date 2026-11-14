// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Subscribing clears what was browsed, by the FEED and through the one
/// normalisation. Before: the in-memory half was cleared by a local show
/// that the server branch never has, and the persisted half compared the
/// raw address, so a show browsed under `http://` and subscribed under
/// `https://` kept both halves.
struct BrowsedEpisodesTests {
    private func show(feedURL: String) -> PodcastShow {
        PodcastShow(id: "browsed-\(UUID().uuidString)", title: "Browsed Show", author: "Host",
                    artworkURL: nil, description: nil, feedURL: feedURL,
                    episodes: [PodcastEpisode(guid: "rss:browsed:\(UUID().uuidString)", title: "Ep",
                                              audioURL: "https://x.example/ep.mp3", pubDate: 1_700_000_000_000,
                                              duration: 1800, description: nil, imageURL: nil, chaptersURL: nil)])
    }

    @Test("Browsed remembering, subscribing under http://: both halves empty")
    func subscribingUnderAnotherSchemeClearsBothHalves() {
        let suite = "browsed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowsedEpisodes()
        let browsed = show(feedURL: "https://x.example/feed?utm_source=mail")
        let guid = browsed.episodes[0].guid
        store.remember(show: browsed)
        store.keepListened(guid: guid, defaults: defaults)
        #expect(store.episode(guid: guid) != nil, "the precondition: browsed and kept")
        #expect(store.listened(guid: guid, defaults: defaults) != nil)

        store.forget(feedURL: "http://x.example/feed")
        store.forgetListened(feedURL: "http://x.example/feed", defaults: defaults)
        #expect(store.episode(guid: guid) == nil, "the in-memory half is cleared by the feed")
        #expect(store.listened(guid: guid, defaults: defaults) == nil, "the persisted half is cleared through the normalisation")
    }

    /// The kept list decodes once per stored list: reads without a write
    /// decode nothing more, a write is seen.
    @Test("the remembered list is decoded once per state, not per read; a write is noticed")
    func theKeptListDecodesOncePerWrite() {
        let suite = "browsed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowsedEpisodes()
        let first = show(feedURL: "https://a.example/feed"), second = show(feedURL: "https://b.example/feed")
        store.remember(show: first)
        store.remember(show: second)
        store.keepListened(guid: first.episodes[0].guid, defaults: defaults)
        let before = BrowsedEpisodes.decodeCount(in: defaults)
        for _ in 0..<5 { #expect(store.listened(guid: first.episodes[0].guid, defaults: defaults) != nil) }
        #expect(store.allListened(defaults: defaults).count == 1)
        #expect(BrowsedEpisodes.decodeCount(in: defaults) <= before + 1, "six reads, at most one decode")
        store.keepListened(guid: second.episodes[0].guid, defaults: defaults)
        #expect(store.listened(guid: second.episodes[0].guid, defaults: defaults) != nil, "the write is seen")
        #expect(store.allListened(defaults: defaults).count == 2)
    }

    @Test("another feed stays untouched")
    func anotherFeedStays() {
        let suite = "browsed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrowsedEpisodes()
        let other = show(feedURL: "https://y.example/feed")
        let guid = other.episodes[0].guid
        store.remember(show: other)
        store.keepListened(guid: guid, defaults: defaults)
        store.forget(feedURL: "https://x.example/feed")
        store.forgetListened(feedURL: "https://x.example/feed", defaults: defaults)
        #expect(store.episode(guid: guid) != nil)
        #expect(store.listened(guid: guid, defaults: defaults) != nil)
    }

    /// A kept list that stands and does not decode is set aside before the
    /// keep writes: the keep stands, the unreadable list lies under
    /// `CorruptStore.asideKey`, and the forget after it finds a readable list.
    @Test("a remembered list that does not decode is set aside; remembering and forgetting write the new state")
    func anUnreadableListIsSetAside() {
        let suite = "browsed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let garbage = Data("{\"not\": \"a kept list\"".utf8)
        defaults.set(garbage, forKey: "browsedEpisodesListened")
        let store = BrowsedEpisodes()
        let browsed = show(feedURL: "https://z.example/feed")
        let guid = browsed.episodes[0].guid
        store.remember(show: browsed)
        #expect(store.episode(guid: guid) != nil, "the precondition: the episode is browsed")
        store.keepListened(guid: guid, defaults: defaults)
        let kept = store.listened(guid: guid, defaults: defaults)
        #expect(kept != nil, "the keep did not stand")
        let aside = defaults.data(forKey: CorruptStore.asideKey("browsedEpisodesListened"))
        #expect(aside == garbage, "the unreadable list was not set aside")
        store.forgetListened(feedURL: "https://z.example/feed", defaults: defaults)
        let gone = store.listened(guid: guid, defaults: defaults)
        #expect(gone == nil, "the forget did not stand")
        let stillAside = defaults.data(forKey: CorruptStore.asideKey("browsedEpisodesListened"))
        #expect(stillAside == garbage, "the forget replaced the aside copy")
    }
}
#endif
