// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Ein Datum, das der Feed-Parser nicht liest, ist kein Schoenheitsfehler.
/// Der Podcast-Tab nimmt eine Sendung nur auf, wenn ihre neueste Folge ein
/// Datum HAT (`PodcastSections.compute`: `newest > 0`). Ein Feed mit
/// unerkannten Daten wird deshalb ein Abo, das in der Einstellungsliste steht
/// — mit seiner Folgenzahl — und im Tab unsichtbar bleibt, ohne ein Wort.
///
/// Gemessen wurde das an E76: Vladimir meldete eine Sendung, die „nur in den
/// Einstellungen" stand. Der Fall passt, weil er nichts von „0 Folgen"
/// geschrieben hat.
///
/// Die Faelle fahren den ECHTEN Parser ueber echte Feed-Texte, nicht eine
/// Nachbildung der Formatliste.
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

    @Test("Das gewoehnliche RFC-822-Datum wird gelesen")
    func plainRFC822IsRead() {
        let date = pubDate("<pubDate>Wed, 09 Sep 2026 10:30:00 +0200</pubDate>") ?? 0
        #expect(date > 0)
        // A feed that names the wrong weekday (the 9th is a Wednesday) is
        // read to the same moment: the day and time carry the date, and the
        // weekday is not checked.
        #expect(pubDate("<pubDate>Tue, 09 Sep 2026 10:30:00 +0200</pubDate>") == date,
                "a wrong weekday on purpose")
    }

    /// Die Sekunden sind in RFC 822 OPTIONAL, und Feeds verschicken beide
    /// Formen. Vorher fiel die kuerzere auf 0 und nahm der Sendung den Tab.
    @Test("RFC 822 OHNE Sekunden wird gelesen")
    func rfc822WithoutSecondsIsRead() {
        #expect(pubDate("<pubDate>Wed, 09 Sep 2026 10:30 +0200</pubDate>") ?? 0 > 0)
        #expect(pubDate("<pubDate>09 Sep 2026 10:30 GMT</pubDate>") ?? 0 > 0)
    }

    /// Feeds, die nie `pubDate` schreiben, datieren mit Dublin Core oder mit
    /// Atoms `updated`. Vorher hatten alle ihre Folgen das Datum 0.
    @Test("dc:date und Atom-updated werden gelesen, wenn pubDate fehlt")
    func dublinCoreAndAtomAreRead() {
        #expect(pubDate("<dc:date>2026-09-09T10:30:00Z</dc:date>") ?? 0 > 0)
        #expect(pubDate("<updated>2026-09-09T10:30:00Z</updated>") ?? 0 > 0)
    }

    /// Die Wahl haengt NICHT an der Reihenfolge im XML: `pubDate` ist das
    /// Veroeffentlichungsdatum, `updated` das der letzten Bearbeitung, und
    /// ein Feed, der beide fuehrt, soll das erste behalten. Deshalb liegen
    /// die zwei in getrennten Feldern und werden erst beim Bauen gewaehlt.
    @Test("Traegt ein Feed beides, gewinnt pubDate, egal in welcher Reihenfolge")
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

    /// Gegenprobe, damit die Faelle oben nicht gruen sind, weil der Parser
    /// inzwischen alles annimmt: unlesbares bleibt 0, und die Folge selbst
    /// bleibt trotzdem da.
    @Test("Ein unlesbares Datum bleibt null, die Folge bleibt")
    func anUnreadableDateStaysZero() {
        let show = RSSFeedParser(feedURL: "https://example.org/feed.xml")
            .parse(feed(itemDate: "<pubDate>irgendwann letzten Sommer</pubDate>"))
        #expect(show?.episodes.count == 1, "die Folge darf an einem Datum nicht scheitern")
        #expect(show?.episodes.first?.pubDate == 0)
    }
}
#endif
