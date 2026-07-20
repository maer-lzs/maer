// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// Tests fürs RSS/Atom-Parsing der Podcast-Feeds — der Codepfad, der an
/// echten (oft schludrigen) Feeds am ehesten bricht.
struct RSSFeedParserTests {

    private func parse(_ xml: String) -> PodcastShow? {
        RSSFeedParser(feedURL: "https://example.com/feed.xml")
            .parse(Data(xml.utf8))
    }

    @Test func parsesShowAndEpisodes() throws {
        let show = try #require(parse("""
        <rss><channel>
          <title>My Show</title>
          <itunes:author>Jane Doe</itunes:author>
          <itunes:image href="https://example.com/show.jpg"/>
          <item>
            <title>Episode One</title>
            <guid>ep-1</guid>
            <pubDate>Wed, 01 Jul 2026 08:00:00 +0000</pubDate>
            <itunes:duration>1:02:03</itunes:duration>
            <enclosure url="https://example.com/1.mp3" type="audio/mpeg"/>
          </item>
        </channel></rss>
        """))
        #expect(show.title == "My Show")
        #expect(show.author == "Jane Doe")
        #expect(show.artworkURL == "https://example.com/show.jpg")
        #expect(show.episodes.count == 1)
        let ep = show.episodes[0]
        #expect(ep.title == "Episode One")
        #expect(ep.audioURL == "https://example.com/1.mp3")
        #expect(ep.duration == 3723)                      // 1*3600 + 2*60 + 3
        #expect(ep.guid.hasPrefix("rss:"))
        #expect(ep.pubDate > 0)
    }

    @Test("Dauer als reine Sekunden und als MM:SS")
    func parsesDurationFormats() throws {
        let secs = try #require(parse(feed(duration: "600")))
        #expect(secs.episodes[0].duration == 600)
        let mmss = try #require(parse(feed(duration: "12:30")))
        #expect(mmss.episodes[0].duration == 750)
    }

    @Test("Item ohne Audio-Enclosure wird verworfen")
    func dropsItemsWithoutAudio() throws {
        let show = try #require(parse("""
        <rss><channel><title>S</title>
          <item><title>No audio</title><guid>x</guid></item>
          <item><title>Has audio</title><guid>y</guid>
            <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """))
        #expect(show.episodes.count == 1)
        #expect(show.episodes[0].title == "Has audio")
    }

    @Test func handlesCDATAAndMissingFields() throws {
        let show = try #require(parse("""
        <rss><channel><title><![CDATA[Show & Co]]></title>
          <item><title><![CDATA[Folge <b>1</b>]]></title><guid>g1</guid>
            <enclosure url="https://example.com/a.mp3"/></item>
        </channel></rss>
        """))
        #expect(show.title == "Show & Co")
        #expect(show.episodes[0].title.contains("Folge"))
        #expect(show.episodes[0].duration == 0)           // unbekannt → 0
    }

    private func feed(duration: String) -> String {
        """
        <rss><channel><title>S</title>
          <item><title>E</title><guid>g</guid>
            <itunes:duration>\(duration)</itunes:duration>
            <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
    }
}
#endif
