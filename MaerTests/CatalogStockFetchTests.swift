// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The retrieval of the stock: the bulk routes, and what could go wrong
/// with them without anyone noticing.
struct CatalogStockFetchTests {

    /// The first retrieval runs through the SCOOP endpoint, not through the
    /// page API of the surfaces. Measured: 10,000 entries in 3.6 s, so
    /// 19 fetches for the largest collection instead of hundreds.
    @Test("the first retrieval asks the bulk route with exactly the fields of the stock")
    func theFirstFetchUsesTheMassRoute() throws {
        let url = try #require(CatalogStockFetch.scrapeURL(
            query: "collection:librivoxaudio AND mediatype:(audio)", cursor: nil))
        let text = url.absoluteString
        #expect(text.contains("/services/search/v1/scrape"),
                "der Erstbezug laeuft wieder ueber die Seiten-API")
        #expect(text.contains("count=10000"), "der Deckel des Endpunkts wird nicht ausgenutzt")
        for feld in ["identifier", "title", "creator", "subject", "downloads", "licenseurl"] {
            #expect(CatalogStockFetch.scrapeFields.contains(feld),
                    "\(feld) fehlt im Bezug, obwohl der Bestand es fuehrt")
        }
        // The pointer travels along, otherwise one would always get the same slice.
        let zweite = try #require(CatalogStockFetch.scrapeURL(query: "x", cursor: "abc"))
        #expect(zweite.absoluteString.contains("cursor=abc"))
    }

    /// The Gutenberg dump is a CSV with quotation marks, commas in
    /// titles and semicolon lists. This literal carries the columns of the
    /// real form, but LF instead of CRLF; the real bytes are checked by
    /// `GutenbergDumpTests` on an excerpt of the file.
    @Test("the dump is read as it really looks")
    func theDumpIsParsedAsItReallyLooks() {
        let csv = """
        Text#,Type,Issued,Title,Language,Authors,Subjects,LoCC,Bookshelves
        1,Text,1971-12-01,The Declaration of Independence,en,"Jefferson, Thomas","United States -- History",E201,"Politics; United States Law"
        20653,Sound,2006-01-01,"Alice's Adventures in Wonderland, and more",en,"Carroll, Lewis","Fantasy fiction; Children's stories",PR,"Children's Literature; Fantasy"
        99999,Sound,2020-01-01,Ohne Autor,de,,,,
        """
        let eintraege = CatalogStockFetch.gutenbergEntries(fromCSV: csv)
        #expect(eintraege.count == 2, "der Medientyp entscheidet, nicht die Zeilenzahl")

        let alice = eintraege.first { $0.id == "gut:20653" }
        #expect(alice?.title == "Alice's Adventures in Wonderland, and more",
                "das Komma im Titel hat die Spalten verschoben")
        #expect(alice?.creator == "Carroll, Lewis")
        // Keywords AND bookshelves, both semicolon-separated, both
        // individually. The local shelf assignment depends on it.
        #expect(alice?.subjects.contains("Fantasy fiction") == true)
        #expect(alice?.subjects.contains("Children's Literature") == true)
        #expect(alice?.subjects.contains("Children's stories") == true)
        // The dump carries NO download counts. Measured, and the reason
        // why the Popular order stays with the service.
        #expect(alice?.downloads == nil, "der Abzug traegt ploetzlich Popularitaet")

        // Red test: the text row drops out although it comes first.
        #expect(!eintraege.contains { $0.id == "gut:1" },
                "ein Text-Werk ist im Hoerbuch-Bestand gelandet")
        // And a row without an author does not drop out, it just has none.
        #expect(eintraege.first { $0.id == "gut:99999" }?.creator?.isEmpty ?? true)
    }

    /// An empty lookup does NOT move the mark forward. Otherwise
    /// a quiet day without new arrivals would have closed the time window
    /// in which the latecomers stand.
    @Test("an empty answer leaves the mark in place")
    func anEmptyAnswerKeepsTheWatermark() {
        #expect(CatalogStockFetch.watermark(from: [], previous: "2026-08-01") == "2026-08-01")
        // Red test: a non-empty answer certainly sets it anew.
        let eintrag = CatalogStockEntry(id: "a", title: "T", creator: nil, subjects: [],
                                        downloads: nil, licenseurl: nil, year: nil)
        let neu = CatalogStockFetch.watermark(from: [eintrag], previous: "2026-08-01")
        #expect(neu != "2026-08-01")
        #expect(neu?.count == 10, "die Marke ist kein Datum in der Form JJJJ-MM-TT")
    }
}
/// The staged download of the Gutenberg dump: completeness
/// is decided by the ANNOUNCED total size, not by the length of the
/// last slice. The three holes of the length rule (infinite loop
/// with a Range-ignoring host, torso through short 206, 416 on an exact
/// multiple) are thereby closed.
struct GutenbergSliceRuleTests {
    private let size = CatalogStockFetch.gutenbergSliceBytes

    @Test("with an announced total the total decides, not the slice length")
    func statedTotalDecides() {
        let full = CatalogStockFetch.DumpSlice(bytes: size, statedTotal: 21_196_613)
        // Full slice, but nowhere near everything: continue.
        #expect(!CatalogStockFetch.dumpIsComplete(held: size, slice: full, sliceSize: size))
        // Short slice in the middle (allowed short 206): NO end,
        // otherwise a torso would be booked as the full stock.
        let short = CatalogStockFetch.DumpSlice(bytes: 1_000, statedTotal: 21_196_613)
        #expect(!CatalogStockFetch.dumpIsComplete(held: 5_000_000, slice: short, sliceSize: size))
        // Everything held: done, even if the slice was full.
        #expect(CatalogStockFetch.dumpIsComplete(held: 21_196_613, slice: full, sliceSize: size))
    }

    @Test("without a total the short answer remains the only honest end")
    func withoutTotalTheShortAnswerEnds() {
        let vollAntwort = CatalogStockFetch.DumpSlice(bytes: size, statedTotal: nil)
        #expect(!CatalogStockFetch.dumpIsComplete(held: size, slice: vollAntwort, sliceSize: size))
        let kurz = CatalogStockFetch.DumpSlice(bytes: 12, statedTotal: nil)
        #expect(CatalogStockFetch.dumpIsComplete(held: 12, slice: kurz, sliceSize: size))
    }

    /// The crack that the two rules above do NOT catch: the
    /// request always carries a Range, so a plain 200 says
    /// „ignoriert, hier ist alles". Such an answer carries no
    /// Content-Range (no total) and is longer than a slice (so
    /// not a short answer either). Appended, it would multiply the
    /// file round after round.
    @Test("a 200 on a range request replaces the body and ends")
    func ignoredRangeReplacesInsteadOfAppending() {
        #expect(CatalogStockFetch.dumpAnswerReplacesBody(status: 200))
        // Red test: the regular partial content keeps appending.
        #expect(!CatalogStockFetch.dumpAnswerReplacesBody(status: 206))
        // And without an HTTP response the old behavior remains.
        #expect(!CatalogStockFetch.dumpAnswerReplacesBody(status: nil))
    }

    /// Shows why the 200 needs a rule of its own at all: measured against the
    /// two existing rules it looks like „weitermachen".
    @Test("the 200 falls through both completeness rules")
    func theIgnoredRangeAnswerLooksIncompleteToBothRules() {
        let ganzeDatei = CatalogStockFetch.DumpSlice(bytes: 21_196_613, statedTotal: nil)
        #expect(!CatalogStockFetch.dumpIsComplete(held: 21_196_613,
                                                 slice: ganzeDatei, sliceSize: size))
    }

    @Test("the total size is read from the Content-Range")
    func totalComesFromTheHeader() {
        #expect(CatalogStockFetch.statedTotal(fromContentRange: "bytes 0-4194303/21196613") == 21_196_613)
        #expect(CatalogStockFetch.statedTotal(fromContentRange: "bytes 0-1023/*") == nil)
        #expect(CatalogStockFetch.statedTotal(fromContentRange: nil) == nil)
    }
}
