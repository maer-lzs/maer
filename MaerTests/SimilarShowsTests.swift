// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// "Similar Shows" under a show: first what the feed itself names
/// (podroll), else the chart of its genre as "More from <genre>", in the
/// show's language; a feed with access data never asks a directory.
@MainActor
struct SimilarShowsTests {
    static let feed = """
    <rss xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
    <channel><title>Show</title><language>de-DE</language><itunes:category text="Comedy"/>
    <podcast:podroll>
      <podcast:remoteItem feedGuid="a-guid" feedUrl="https://one.example/feed.xml" title="One"/>
      <podcast:remoteItem feedGuid="b-guid"/>
    </podcast:podroll>
    <item><title>E</title><guid>e1</guid><enclosure url="https://x.example/e.mp3" type="audio/mpeg"/></item>
    </channel></rss>
    """

    @Test("the reader keeps the podroll on the show; a feed without one has none")
    func reader() throws {
        let show = try #require(RSSFeedParser(feedURL: "https://show.example/feed.xml").parse(Data(Self.feed.utf8)))
        #expect(show.podroll == [PodcastRemoteItem(feedGuid: "a-guid", feedUrl: "https://one.example/feed.xml", title: "One"),
                                 PodcastRemoteItem(feedGuid: "b-guid", feedUrl: nil, title: nil)])
        let plain = try #require(RSSFeedParser(feedURL: "https://show.example/feed.xml")
            .parse(Data(Self.feed.replacingOccurrences(of: "podroll", with: "nothing").utf8)))
        #expect(plain.podroll == nil)
        let old = try JSONDecoder().decode(PodcastShow.self, from: Data(#"{"id":"x","title":"T","feedURL":"https://x","episodes":[]}"#.utf8))
        #expect(old.podroll == nil)
    }

    @Test("the plan: the podroll with addresses first, then the chart of the genre in the show's language")
    func planOpenApple() {
        let podroll = [PodcastRemoteItem(feedGuid: nil, feedUrl: "https://one.example/feed.xml", title: "One"),
                       PodcastRemoteItem(feedGuid: "b", feedUrl: nil, title: nil)]
        #expect(SimilarShows.plan(categories: ["Comedy"], language: "de-DE", podroll: podroll, directory: .itunes, guarded: false)
                == [.podroll([podroll[0]]), .charts(genreId: 1303, language: "de")])
        #expect(SimilarShows.plan(categories: ["Comedy"], language: "en", podroll: nil, directory: .podcastIndex, guarded: false)
                == [.trending(category: "Comedy", language: "en")])
        #expect(SimilarShows.plan(categories: ["Comedy"], language: nil, podroll: podroll, directory: .none, guarded: false)
                == [.podroll([podroll[0]])])
    }

    @Test("a feed with access data asks no directory, only its own podroll")
    func planGuarded() {
        let podroll = [PodcastRemoteItem(feedGuid: nil, feedUrl: "https://one.example/feed.xml", title: "One")]
        #expect(SimilarShows.plan(categories: ["Comedy"], language: "de", podroll: podroll, directory: .itunes, guarded: true)
                == [.podroll(podroll)])
        #expect(SimilarShows.plan(categories: ["Comedy"], language: "de", podroll: nil, directory: .itunes, guarded: true).isEmpty)
    }

    @Test("the pick: podroll first, without the show itself, the subscribed and doubles, at most six")
    func pick() {
        func p(_ url: String, podroll: Bool = false) -> SimilarShows.Pick {
            SimilarShows.Pick(feedURL: url, title: url, artworkURL: nil, fromPodroll: podroll)
        }
        let picked = SimilarShows.pick(podroll: [p("https://r.example/1", podroll: true)],
                                       directory: [p("https://own.example/feed"), p("https://sub.example/feed"),
                                                   p("https://r.example/1"), p("https://d.example/1"), p("https://d.example/2"),
                                                   p("https://d.example/3"), p("https://d.example/4"), p("https://d.example/5"),
                                                   p("https://d.example/6")],
                                       ownFeed: "https://own.example/feed", subscribed: ["https://sub.example/feed"])
        #expect(picked.map(\.feedURL) == ["https://r.example/1", "https://d.example/1", "https://d.example/2",
                                          "https://d.example/3", "https://d.example/4", "https://d.example/5"])
        #expect(picked.first?.fromPodroll == true)
    }

    @Test("the heading: Similar Shows with a podroll, More from the genre from the chart, nothing when empty")
    func heading() {
        #expect(SimilarShows.heading(podrollShown: true, genre: "Comedy") == String(localized: "Similar Shows"))
        #expect(SimilarShows.heading(podrollShown: false, genre: "Comedy") == String(localized: "More from \("Comedy")"))
        #expect(SimilarShows.heading(podrollShown: false, genre: nil) == String(localized: "Similar Shows"))
    }

    @Test("Fence: the section asks only when it appears, subscribes nothing, and the show page holds it under the episodes", .needsTheSources)
    func section() throws {
        let view = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/SimilarShowsSection.swift"), encoding: .utf8))
        #expect(view.contains(".task(id: show.feedURL)"))
        #expect(!view.contains("subscribe("), "the section subscribes")
        #expect(view.contains("RecommendationTile("))
        let page = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/PodcastShowView.swift"), encoding: .utf8))
        #expect(page.contains("SimilarShowsSection(show:"))
    }
}
#endif
