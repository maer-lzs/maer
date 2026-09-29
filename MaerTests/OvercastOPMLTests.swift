// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The reader on the frozen fixtures under `Fixtures/ForeignImport`,
/// built from the format description; the real export is the
/// acceptance, not the precondition. The same files go to the source
/// watch, so the expectations here are the ones it checks.
struct OvercastOPMLTests {
    @Test("erweitertes OPML: Feeds in Dateiordnung, Staende je Folge mit Sendung")
    func extendedYieldsFeedsAndStates() throws {
        let extended = try CorpusFixture.data("overcast-extended", ext: "opml", subdirectory: "ForeignImport")
        let doc = try #require(OvercastOPML.parse(extended))
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
        // `B1` traegt keinen Zeitpunkt: darf spaeter nur fuellen.
        #expect(doc.states[2].stampedAt == nil)
        #expect(doc.states[2].feedURL == "https://b.example/rss")
    }

    @Test("die eigene Ausfuhr-Datei liest sich mit GUID und Millisekunden")
    func ownExportFixture() throws {
        let data = try CorpusFixture.data("maer-export", ext: "opml", subdirectory: "ForeignImport")
        let doc = try #require(OvercastOPML.parse(data))
        #expect(doc.feedURLs == ["https://free.example/rss", "https://plain.example/rss"])
        #expect(doc.states.map(\.episodeGUID) == ["one", "two", "three"])
        #expect(doc.states[0].stampedAt == 1_706_781_600_500)
        #expect(doc.states[0].episodeTitle == "Episode <one> & more")
        #expect(doc.states[1].finished)
        #expect(doc.states[2].stampedAt == nil)
        #expect(doc.states.allSatisfy { $0.feedURL == "https://free.example/rss" })
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
