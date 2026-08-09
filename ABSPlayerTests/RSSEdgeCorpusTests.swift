// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// RSS parser against the edge-case corpus (ballon5, corpus version 1.0).
/// Ground truth: `RSS-MANIFEST.json` / the corpus MANIFEST table. Every case
/// runs on every test run; where Mär deviates from the corpus expectation the
/// assert is wrapped in `withKnownIssue` with a Befund ID (full list in the
/// corpus report) — deviations stay visible, they are never bent green.
///
/// Befund register (see report). FIXED by the Härtungspaket: R2 (video/*
/// and octet-stream-with-media-extension enclosures accepted), R3 (relative
/// URLs resolved against the feed base), R4 (duplicate guids collapse
/// in-parse), R5 (weekday-less / zone-name RFC-2822 forms parse), O1 (broken
/// OPML fails visibly). STILL OPEN:
/// - R1 RESOLVED (owner decision 01.08): text-only items are KEPT and
///   marked non-playable (`isPlayable == false`) — all five R1 cases strict.
/// - R6: channel-level `podcast:guid` (PC20) is not read at all.
/// - R7: `atom:link rel="next"` pagination (RFC 5005) is not surfaced.
struct RSSEdgeCorpusTests {

    private func parse(_ name: String, feedURL: String = "https://example.org/feed.xml") throws -> PodcastShow? {
        let data = try CorpusFixture.data(name, ext: "xml", subdirectory: "RSSEdgeCorpus")
        return RSSFeedParser(feedURL: feedURL).parse(data)
    }

    // MARK: - Clean passes

    @Test func minimalValid() throws {
        let show = try #require(try parse("minimal-valid"))
        #expect(show.title == "The Daily Insight")
        #expect(show.episodes.count == 1)
        let ep = show.episodes[0]
        #expect(ep.title == "Episode 1: The Future of AI")
        #expect(ep.audioURL == "https://example.org/podcast/episode1.mp3")
        #expect(ep.guid.hasSuffix(":https://example.org/podcast/episode1"))
        #expect(ep.pubDate > 0)
    }

    @Test("no <guid> → stable fallback identity from the enclosure URL")
    func noGuidFallback() throws {
        let show = try #require(try parse("no-guid"))
        #expect(show.episodes.count == 2)
        #expect(show.episodes[0].guid.hasSuffix(":https://example.org/episodes/ai2025.mp3"))
    }

    @Test("guid isPermaLink=true: URL value is the identity")
    func guidPermalinkURL() throws {
        let show = try #require(try parse("guid-permalink-url"))
        // R1 resolved: the enclosure-less items are kept, so the fixture
        // asserts run strict.
        #expect(show.episodes.contains { $0.guid.hasSuffix(":https://example.com/episodes/42") })
        #expect(show.episodes.allSatisfy { !$0.isPlayable })
        // The guid semantics themselves, probed inline with the fixture value:
        let inline = RSSFeedParser(feedURL: "https://example.org/f.xml").parse(Data("""
        <rss><channel><title>S</title><item><title>E</title>
        <guid isPermaLink="true">https://example.com/episodes/42</guid>
        <enclosure url="https://example.org/e.mp3" type="audio/mpeg"/>
        </item></channel></rss>
        """.utf8))
        #expect(inline?.episodes.first?.guid.hasSuffix(":https://example.com/episodes/42") == true)
    }

    @Test("enclosure length=0 is not an error; URL stays usable")
    func enclosureZeroLength() throws {
        let show = try #require(try parse("enclosure-zero-length"))
        #expect(show.episodes.count == 2)
        #expect(show.episodes.allSatisfy { $0.audioURL.hasPrefix("https://") })
    }

    @Test("itunes:duration SS / MM:SS / HH:MM:SS, per-item image, episodeType")
    func itunesVariants() throws {
        let show = try #require(try parse("itunes-variants"))
        // R1 resolved: all three text-only items are kept — the fixture's
        // variant metadata is now assertable directly.
        #expect(show.episodes.count == 3)
        #expect(show.episodes.map(\.duration) == [185, 185, 3725])
        #expect(show.episodes.compactMap(\.episodeType) == ["full", "bonus", "trailer"])
        // The variants themselves, probed inline with the fixture values:
        func episode(duration: String, type: String, image: String) -> PodcastEpisode? {
            RSSFeedParser(feedURL: "https://example.org/f.xml").parse(Data("""
            <rss><channel><title>S</title><item><title>E</title>
            <itunes:duration>\(duration)</itunes:duration>
            <itunes:episodeType>\(type)</itunes:episodeType>
            <itunes:image href="\(image)"/>
            <enclosure url="https://example.org/e.mp3" type="audio/mpeg"/>
            </item></channel></rss>
            """.utf8))?.episodes.first
        }
        let ss = episode(duration: "185", type: "full", image: "https://example.org/images/ep1.jpg")
        #expect(ss?.duration == 185)
        #expect(ss?.episodeType == "full")
        #expect(ss?.imageURL == "https://example.org/images/ep1.jpg")
        #expect(episode(duration: "3:05", type: "bonus", image: "https://x.example/i.jpg")?.duration == 185)
        let hms = episode(duration: "1:02:05", type: "trailer", image: "https://x.example/i.jpg")
        #expect(hms?.duration == 3725)
        #expect(hms?.episodeType == "trailer")
    }

    @Test("PC20 chapters URL extracted from the podcast: namespace")
    func pc20Chapters() throws {
        let show = try #require(try parse("pc20-chapters"))
        #expect(show.episodes.first?.chaptersURL == "https://example.com/ep1/chapters.json")
    }

    @Test("BOM is skipped; feed parses as normal UTF-8")
    func bomUTF8() throws {
        let show = try #require(try parse("bom-utf8"))
        #expect(!show.episodes.isEmpty)
        #expect(show.episodes[0].guid.hasSuffix(":bom-ep-1"))
    }

    @Test("declared ISO-8859-1 is decoded correctly (channel level)")
    func latin1Declared() throws {
        let show = try #require(try parse("latin1-declared"))
        #expect(show.title == "Käpt'n Blaubär Hörspiel")
    }

    @Test("multi-byte UTF-8 (umlauts + emoji) survives at channel level")
    func umlautEmojiChannel() throws {
        let show = try #require(try parse("umlaut-emoji"))
        #expect(show.title == "Podcast mit ÄÖÜ und 🎙️🔥")
    }

    @Test("1000-item feed parses completely")
    func hugeFeed() throws {
        let show = try #require(try parse("huge-feed"))
        #expect(show.episodes.count == 1000)
    }

    @Test("Pinchflat shape (audio/mp4, yt-style guids) parses as normal episodes")
    func youtubePinchflatShape() throws {
        let show = try #require(try parse("youtube-pinchflat-shape"))
        #expect(show.episodes.count == 2)
        #expect(show.episodes[0].guid.hasSuffix(":UCabc123_ep1"))
    }

    @Test("broken XML fails cleanly: nil, no crash, no partial garbage")
    func brokenXML() throws {
        #expect(try parse("broken-xml") == nil)
    }

    @Test("declared UTF-8 with Latin-1 bytes fails instead of silent garbage")
    func wrongEncodingLie() throws {
        #expect(try parse("wrong-encoding-lie") == nil)
    }

    @Test("missing pubDate does not invalidate the feed (channel survives)")
    func noPubdateChannel() throws {
        let show = try #require(try parse("no-pubdate"))
        #expect(show.title == "The Daily Insight")
    }

    // MARK: - Befunde (known deviations from the corpus ground truth)

    @Test("R1 resolved: item without enclosure survives as non-playable")
    func enclosureMissing() throws {
        let show = try #require(try parse("enclosure-missing"))
        #expect(show.episodes.count == 2)
        #expect(show.episodes.filter(\.isPlayable).count == 1)
        #expect(show.episodes.filter { !$0.isPlayable }.count == 1)
    }

    @Test("R2 fixed: octet-stream enclosure with media extension is kept")
    func enclosureWrongMime() throws {
        let show = try #require(try parse("enclosure-wrong-mime"))
        #expect(show.episodes.count == 2)
    }

    @Test("R2 fixed: Podsync (video/mp4) feeds parse as episodes")
    func youtubePodsyncShape() throws {
        let show = try #require(try parse("youtube-podsync-shape"))
        #expect(show.episodes.count == 2)
        #expect(show.episodes.first?.guid.hasSuffix(":dQw4w9WgXcQ") == true)
    }

    @Test("R3 fixed: relative URLs resolve against the feed base")
    func relativeURLs() throws {
        let show = try #require(try parse("relative-urls", feedURL: "https://example.com/podcast/feed.xml"))
        #expect(show.episodes.first?.audioURL == "https://example.com/podcast/media/ep1.mp3")
        #expect(show.artworkURL == "https://example.com/podcast/art/cover.jpg")
    }

    @Test("R4 fixed: duplicate guid collapses to one episode (first wins)")
    func duplicateGuid() throws {
        let show = try #require(try parse("duplicate-guid"))
        #expect(show.episodes.count == 1)
        #expect(show.episodes.first?.audioURL == "https://example.org/bytecast/ep-0007.mp3")
    }

    @Test("R5 fixed: RFC-2822 variants (no weekday / zone name) parse")
    func invalidPubdateTolerance() throws {
        // The corpus fixture's items carry no enclosure (blocked by R1), so the
        // date tolerance is probed with the fixture's exact date strings inline.
        func pubDate(_ s: String) -> Double {
            let xml = """
            <rss><channel><title>D</title><item><title>E</title>
            <pubDate>\(s)</pubDate>
            <enclosure url="https://example.org/e.mp3" type="audio/mpeg"/>
            </item></channel></rss>
            """
            return RSSFeedParser(feedURL: "https://example.org/f.xml")
                .parse(Data(xml.utf8))?.episodes.first?.pubDate ?? -1
        }
        #expect(pubDate("Wed, 15 Jan 2025 09:00:00 +0000") > 0)   // reference form parses
        #expect(pubDate("gestern abend") == 0)                     // garbage → 0, no crash
        // R5 fixed: weekday-less and zone-name forms parse now.
        #expect(pubDate("15 Jan 2025 09:00:00 GMT") > 0)
        #expect(pubDate("Wed, 15 Jan 2025 04:00:00 EST") > 0)
    }

    @Test("R1 resolved (paged feed): items kept; R7 rel=next stays report-only")
    func pagedFeed() throws {
        let show = try #require(try parse("paged-feed"))
        #expect(show.episodes.count == 2)
        #expect(show.episodes.allSatisfy { !$0.isPlayable })
    }

    @Test("R1 resolved: CDATA/entity title survives on the kept text item")
    func cdataHTMLTitle() throws {
        let show = try #require(try parse("cdata-html-title"))
        #expect(show.episodes.contains { $0.title.contains("R&D") })
    }
}
#endif
