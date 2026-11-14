// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A length from outside is finite, not negative and bounded, or unknown.
struct PodcastDurationTests {

    private func parsed(duration: String) throws -> PodcastEpisode {
        let show = try #require(RSSFeedParser(feedURL: "https://length.example/feed.xml").parse(Data("""
        <rss><channel>
          <title>Length</title>
          <item>
            <title>One</title>
            <guid>one</guid>
            <itunes:duration>\(duration)</itunes:duration>
            <enclosure url="https://length.example/1.mp3" type="audio/mpeg"/>
          </item>
        </channel></rss>
        """.utf8)))
        try #require(show.episodes.count == 1)
        return show.episodes[0]
    }

    @Test("the rule: finite, non-negative and at most one year, otherwise unknown")
    func theRule() {
        #expect(PodcastDuration.known(.infinity) == 0)
        #expect(PodcastDuration.known(-.infinity) == 0)
        #expect(PodcastDuration.known(.nan) == 0)
        #expect(PodcastDuration.known(-5) == 0)
        #expect(PodcastDuration.known(1e300) == 0)
        #expect(PodcastDuration.known(PodcastDuration.longest + 1) == 0)
        #expect(PodcastDuration.known(PodcastDuration.longest) == PodcastDuration.longest)
        #expect(PodcastDuration.known(0) == 0)
        #expect(PodcastDuration.known(3723) == 3723)
    }

    @Test("a duration from the feed that is no length becomes unknown, can be drawn and can be written",
          arguments: ["inf", "nan", "NaN", "NaN:NaN:NaN", "1e999", "-5", "1e300", "inf:00", "-1:00:00"])
    func aLengthNoReaderCanTakeIsUnknown(written: String) throws {
        let episode = try parsed(duration: written)
        #expect(episode.duration == 0, "\(written) came through as \(episode.duration)")
        #expect(DurationText.length(seconds: episode.duration) == DurationText.length(seconds: 0))
        let data = try JSONEncoder().encode(episode)
        #expect(!data.isEmpty)
    }

    @Test("an ordinary duration from the feed stays", arguments: [("1:02:03", 3723.0), ("45:00", 2700.0), ("600", 600.0)])
    func anOrdinaryLengthStays(written: String, seconds: Double) throws {
        #expect(try parsed(duration: written).duration == seconds)
    }

    @Test("the answer of the directory goes through the same rule")
    func theDirectoryAnswerPassesTheSameRule() async throws {
        let show = PodcastShow(id: "feed:length", title: "Length", author: nil, artworkURL: nil, description: nil,
                               feedURL: "https://length.example/feed.xml", episodes: [])
        let answer = [
            PodcastIndexEpisode(guid: "huge", title: "Huge", enclosureUrl: "https://length.example/h.mp3",
                                datePublished: 2, duration: 1e300, description: nil, image: nil),
            PodcastIndexEpisode(guid: "minus", title: "Minus", enclosureUrl: "https://length.example/m.mp3",
                                datePublished: 1, duration: -5, description: nil, image: nil),
        ]
        let added = try #require(await PodcastSubscriptions.historyAdditions(of: show, browsed: true) { _ in answer })
        #expect(added.map(\.duration) == [0, 0])
    }

    @Test("a stored stock with such a duration is healed on reading")
    func aStoredStockIsHealedOnReading() async throws {
        let store = try await PodcastRowStore(connection: SQLiteConnection(path: ":memory:"))
        var huge = PodcastEpisode(guid: "huge", title: "Huge", audioURL: "https://length.example/h.mp3",
                                  pubDate: 2, duration: 1e300)
        huge.measuredDuration = 1e300
        let minus = PodcastEpisode(guid: "minus", title: "Minus", audioURL: "https://length.example/m.mp3",
                                   pubDate: 1, duration: -5)
        let fine = PodcastEpisode(guid: "fine", title: "Fine", audioURL: "https://length.example/f.mp3",
                                  pubDate: 0, duration: 600)
        let stock = [PodcastShow(id: "feed:length", title: "Length", author: nil, artworkURL: nil, description: nil,
                                 feedURL: "https://length.example/feed.xml", episodes: [huge, minus, fine])]
        try await store.apply(PodcastRowDiff.compute(previous: [], current: stock))
        let read = try await store.loadAll()
        try #require(read.count == 1)
        let byGuid = Dictionary(uniqueKeysWithValues: read[0].episodes.map { ($0.guid, $0) })
        #expect(byGuid.count == 3, "the stored rows carry the three lengths")
        #expect(byGuid["huge"]?.duration == 0)
        #expect(byGuid["huge"]?.measuredDuration == 0)
        #expect(byGuid["minus"]?.duration == 0)
        #expect(byGuid["fine"]?.duration == 600)
    }
}
#endif
