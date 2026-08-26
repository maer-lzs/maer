// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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

    @Test("R1: Item ohne Audio-Enclosure bleibt als Nur-Text-Folge erhalten")
    func keepsItemsWithoutAudio() throws {
        let show = try #require(parse("""
        <rss><channel><title>S</title>
          <item><title>No audio</title><guid>x</guid></item>
          <item><title>Has audio</title><guid>y</guid>
            <enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """))
        // BOTH stay — the text item is kept,
        // marked non-playable; the audio item stays playable.
        #expect(show.episodes.count == 2)
        let text = try #require(show.episodes.first { $0.title == "No audio" })
        #expect(!text.isPlayable)
        #expect(text.audioURL.isEmpty)
        let audio = try #require(show.episodes.first { $0.title == "Has audio" })
        #expect(audio.isPlayable)
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

    // MARK: - Pure helpers

    @Test("R2: enclosure acceptance — audio/video/octet-stream heuristic")
    func enclosureAcceptance() {
        #expect(RSSFeedParser.acceptsEnclosure(type: "audio/mpeg", url: "https://x.example/a.mp3"))
        #expect(RSSFeedParser.acceptsEnclosure(type: "video/mp4", url: "https://x.example/v.mp4"))
        #expect(RSSFeedParser.acceptsEnclosure(type: nil, url: "https://x.example/a"))
        #expect(RSSFeedParser.acceptsEnclosure(
            type: "application/octet-stream", url: "https://x.example/e.mp3"))
        #expect(RSSFeedParser.acceptsEnclosure(
            type: "application/octet-stream", url: "https://x.example/e.mp3?token=1"))
        #expect(!RSSFeedParser.acceptsEnclosure(
            type: "application/octet-stream", url: "https://x.example/page.html"))
        #expect(!RSSFeedParser.acceptsEnclosure(type: "text/html", url: "https://x.example/e.mp3"))
        #expect(!RSSFeedParser.acceptsEnclosure(type: "image/jpeg", url: "https://x.example/c.jpg"))
    }

    @Test("R3: URL resolution against the feed base")
    func urlResolution() {
        let base = "https://example.com/podcast/feed.xml"
        #expect(RSSFeedParser.resolved("media/ep1.mp3", against: base)
                == "https://example.com/podcast/media/ep1.mp3")
        #expect(RSSFeedParser.resolved("/root/ep.mp3", against: base)
                == "https://example.com/root/ep.mp3")
        #expect(RSSFeedParser.resolved("https://cdn.example/a.mp3", against: base)
                == "https://cdn.example/a.mp3")
        // Loose input gets percent-encoded and resolved (iOS 26 lenient URL
        // parsing); an unparseable BASE passes the raw value through.
        #expect(RSSFeedParser.resolved("nicht url ähnlich %", against: base)
                == "https://example.com/podcast/nicht%20url%20%C3%A4hnlich%20%25")
        #expect(RSSFeedParser.resolved("media/ep1.mp3", against: "") == "media/ep1.mp3")
    }
}
#endif
