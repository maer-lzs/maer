// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A date that the feed parser does not read is not a cosmetic fault.
/// The podcast tab takes in a show only if its newest episode HAS a
/// date (`PodcastSections.compute`: `newest > 0`). A feed with
/// unrecognized dates thus becomes a subscription that stands in the settings list
/// (with its episode count) and stays invisible in the tab, without a word.
///
/// This was measured on a reported show that stood
/// „nur in den Einstellungen". The case fits, because it wrote nothing of „0 Folgen".
///
/// The cases run the REAL parser over real feed texts, not a
/// replica of the format list.
struct FeedDateParsingTests {
    private func feed(itemDate: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>Testsendung</title>
            <item>
              <title>Erste Folge</title>
              <guid>folge-1</guid>
              <enclosure url="https://example.org/1.mp3" type="audio/mpeg"/>
              \(itemDate)
            </item>
          </channel>
        </rss>
        """.utf8)
    }

    private func pubDate(_ itemDate: String) -> Double? {
        RSSFeedParser(feedURL: "https://example.org/feed.xml")
            .parse(feed(itemDate: itemDate))?.episodes.first?.pubDate
    }

    @Test("The ordinary RFC 822 date is read")
    func plainRFC822IsRead() {
        let date = pubDate("<pubDate>Wed, 09 Sep 2026 10:30:00 +0200</pubDate>") ?? 0
        #expect(date > 0)
        // A feed that names the wrong weekday (the 9th is a Wednesday) is
        // read to the same moment: the day and time carry the date, and the
        // weekday is not checked.
        #expect(pubDate("<pubDate>Tue, 09 Sep 2026 10:30:00 +0200</pubDate>") == date,
                "a wrong weekday on purpose")
    }

    /// The seconds are OPTIONAL in RFC 822, and feeds send both
    /// forms. Before, the shorter fell to 0 and took the show out of the tab.
    @Test("RFC 822 WITHOUT seconds is read")
    func rfc822WithoutSecondsIsRead() {
        #expect(pubDate("<pubDate>Wed, 09 Sep 2026 10:30 +0200</pubDate>") ?? 0 > 0)
        #expect(pubDate("<pubDate>09 Sep 2026 10:30 GMT</pubDate>") ?? 0 > 0)
    }

    /// Feeds that never write `pubDate` date with Dublin Core or with
    /// Atom's `updated`. Before, all their episodes had the date 0.
    @Test("dc:date and Atom updated are read when pubDate is missing")
    func dublinCoreAndAtomAreRead() {
        #expect(pubDate("<dc:date>2026-09-09T10:30:00Z</dc:date>") ?? 0 > 0)
        #expect(pubDate("<updated>2026-09-09T10:30:00Z</updated>") ?? 0 > 0)
    }

    /// The choice does NOT depend on the order in the XML: `pubDate` is the
    /// publication date, `updated` that of the last edit, and
    /// a feed that carries both should keep the first. That is why
    /// the two lie in separate fields and are chosen only at build time.
    @Test("If a feed carries both, pubDate wins, whatever the order")
    func publicationDateWinsRegardlessOfOrder() {
        let published = pubDate("<pubDate>Wed, 09 Sep 2026 10:30:00 +0000</pubDate>") ?? 0
        let bothWays = [
            "<pubDate>Wed, 09 Sep 2026 10:30:00 +0000</pubDate><updated>2027-01-01T00:00:00Z</updated>",
            "<updated>2027-01-01T00:00:00Z</updated><pubDate>Wed, 09 Sep 2026 10:30:00 +0000</pubDate>",
        ]
        for order in bothWays {
            #expect(pubDate(order) == published, "die Reihenfolge im XML entscheidet mit")
        }
    }

    /// Counter-check, so the cases above are not green because the parser
    /// meanwhile accepts everything: unreadable stays 0, and the episode itself
    /// stays there all the same.
    @Test("An unreadable date stays zero, the episode stays")
    func anUnreadableDateStaysZero() {
        let show = RSSFeedParser(feedURL: "https://example.org/feed.xml")
            .parse(feed(itemDate: "<pubDate>irgendwann letzten Sommer</pubDate>"))
        #expect(show?.episodes.count == 1, "die Folge darf an einem Datum nicht scheitern")
        #expect(show?.episodes.first?.pubDate == 0)
    }
}
#endif
