// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The reader on a fixture built from the format description; the real
/// export is the acceptance, not the precondition.
struct OvercastOPMLTests {
    private let extended = """
    <?xml version="1.0" encoding="utf-8"?>
    <opml version="1.0">
      <head><title>Overcast Podcast Subscriptions</title></head>
      <body>
        <outline text="feeds">
          <outline type="rss" text="Show A" xmlUrl="https://a.example/rss">
            <outline type="podcast-episode" overcastId="1" pubDate="2024-01-01T00:00:00-00:00"
                     title="A1" url="https://a.example/ep/1" overcastUrl="https://overcast.fm/+x"
                     enclosureUrl="https://a.example/1.mp3" userUpdatedDate="2024-02-01T10:00:00-00:00"
                     progress="612" played="0"/>
            <outline type="podcast-episode" overcastId="2" title="A2" url="https://a.example/ep/2"
                     enclosureUrl="https://a.example/2.mp3" userUpdatedDate="2024-02-02T10:00:00-00:00"
                     played="1"/>
          </outline>
          <outline type="rss" text="Show B" xmlUrl="https://b.example/rss">
            <outline type="podcast-episode" overcastId="3" title="B1"
                     enclosureUrl="https://b.example/1.mp3" progress="30" played="0"/>
          </outline>
        </outline>
      </body>
    </opml>
    """

    @Test("erweitertes OPML: Feeds in Dateiordnung, Staende je Folge mit Sendung")
    func extendedYieldsFeedsAndStates() throws {
        let doc = try #require(OvercastOPML.parse(Data(extended.utf8)))
        #expect(doc.feedURLs == ["https://a.example/rss", "https://b.example/rss"])
        #expect(doc.states.count == 3)
        let a1 = doc.states[0]
        #expect(a1.feedURL == "https://a.example/rss")
        #expect(a1.enclosureURL == "https://a.example/1.mp3")
        #expect(a1.episodeLink == "https://a.example/ep/1")
        #expect(a1.episodeTitle == "A1")
        #expect(a1.position == 612)
        #expect(!a1.finished)
        #expect(a1.episodeGUID == nil)
        #expect(a1.stampedAt == 1_706_781_600_000)
        let a2 = doc.states[1]
        #expect(a2.finished && a2.position == 0)
        // B1 traegt keinen Zeitpunkt: darf spaeter nur fuellen.
        #expect(doc.states[2].stampedAt == nil)
        #expect(doc.states[2].feedURL == "https://b.example/rss")
    }

    @Test("ein schlichtes OPML bleibt der reine Abo-Import")
    func plainOPMLHasNoStates() throws {
        let plain = """
        <opml version="1.0"><body>
          <outline text="Folder">
            <outline type="rss" text="X" xmlUrl="https://x.example/rss"/>
            <outline type="rss" text="Y" xmlURL="https://y.example/rss"/>
          </outline>
        </body></opml>
        """
        let doc = try #require(OvercastOPML.parse(Data(plain.utf8)))
        #expect(doc.feedURLs == ["https://x.example/rss", "https://y.example/rss"])
        #expect(doc.states.isEmpty)
    }

    /// Rot-Probe: eine kaputte Datei liefert nil, nie den Teil davor.
    @Test("kaputtes XML ist nil, kein halber Import")
    func brokenIsNil() {
        let broken = "<opml><body><outline type=\"rss\" xmlUrl=\"https://a.example/rss\">"
        #expect(OvercastOPML.parse(Data(broken.utf8)) == nil)
    }

    @Test("Zeitpunkte: ISO mit Zone, mit Bruchteilen, sonst nil")
    func moments() {
        #expect(OvercastOPML.momentMs("2024-02-01T10:00:00-00:00") == 1_706_781_600_000)
        #expect(OvercastOPML.momentMs("2024-02-01T10:00:00.500Z") == 1_706_781_600_500)
        #expect(OvercastOPML.momentMs("") == nil)
        #expect(OvercastOPML.momentMs("gestern") == nil)
        #expect(OvercastOPML.momentMs(nil) == nil)
    }
}
#endif
