// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// Der Bezug des Bestands: die Massen-Wege, und was an ihnen schiefgehen
/// koennte, ohne dass es jemand merkt.
struct CatalogStockFetchTests {

    /// Der Erstbezug laeuft ueber den SCHOEPF-Endpunkt, nicht ueber die
    /// Seiten-API der Flaechen. Gemessen: 10.000 Eintraege in 3,6 s, also
    /// 19 Abrufe fuer die groesste Sammlung statt Hunderten.
    @Test("der Erstbezug fragt den Massen-Weg mit genau den Feldern des Bestands")
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
        // Der Zeiger reist mit, sonst bekaeme man immer dieselbe Scheibe.
        let zweite = try #require(CatalogStockFetch.scrapeURL(query: "x", cursor: "abc"))
        #expect(zweite.absoluteString.contains("cursor=abc"))
    }

    /// Der Gutenberg-Abzug ist eine CSV mit Anfuehrungszeichen, Kommata in
    /// Titeln und Semikolon-Listen. Gegen ein Literal der ECHTEN Form
    /// geprueft, nicht gegen eine selbstgebaute.
    @Test("der Abzug wird gelesen wie er wirklich aussieht")
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
        // Schlagworte UND Buecherregale, beide semikolon-getrennt, beide
        // einzeln — daran haengt die lokale Fach-Zuordnung.
        #expect(alice?.subjects.contains("Fantasy fiction") == true)
        #expect(alice?.subjects.contains("Children's Literature") == true)
        #expect(alice?.subjects.contains("Children's stories") == true)
        // Der Abzug traegt KEINE Download-Zahlen. Gemessen, und der Grund,
        // warum die Beliebt-Ordnung beim Dienst bleibt.
        #expect(alice?.downloads == nil, "der Abzug traegt ploetzlich Popularitaet")

        // Rot-Probe: die Text-Zeile faellt heraus, obwohl sie zuerst steht.
        #expect(!eintraege.contains { $0.id == "gut:1" },
                "ein Text-Werk ist im Hoerbuch-Bestand gelandet")
        // Und eine Zeile ohne Autor faellt nicht weg, sie hat nur keinen.
        #expect(eintraege.first { $0.id == "gut:99999" }?.creator?.isEmpty ?? true)
    }

    /// Ein leerer Nachschlag verschiebt die Marke NICHT nach vorne. Sonst
    /// haette ein stiller Tag ohne Neuzugaenge das Zeitfenster geschlossen,
    /// in dem die Nachzuegler stehen.
    @Test("eine leere Antwort laesst die Marke stehen")
    func anEmptyAnswerKeepsTheWatermark() {
        #expect(CatalogStockFetch.watermark(from: [], previous: "2026-08-01") == "2026-08-01")
        // Rot-Probe: eine nicht leere Antwort setzt sie sehr wohl neu.
        let eintrag = CatalogStockEntry(id: "a", title: "T", creator: nil, subjects: [],
                                        downloads: nil, licenseurl: nil, year: nil)
        let neu = CatalogStockFetch.watermark(from: [eintrag], previous: "2026-08-01")
        #expect(neu != "2026-08-01")
        #expect(neu?.count == 10, "die Marke ist kein Datum in der Form JJJJ-MM-TT")
    }
}
/// Der Etappen-Download des Gutenberg-Abzugs: die Vollstaendigkeit
/// entscheidet an der ANGESAGTEN Gesamtgroesse, nicht an der Laenge der
/// letzten Scheibe. Die drei Loecher der Laengen-Regel (Endlosschleife
/// bei Range-ignorierendem Host, Torso durch kurze 206, 416 bei exaktem
/// Vielfachen) sind damit zu.
struct GutenbergSliceRuleTests {
    private let size = CatalogStockFetch.gutenbergSliceBytes

    @Test("mit angesagtem Total entscheidet das Total, nicht die Scheibenlaenge")
    func statedTotalDecides() {
        let full = CatalogStockFetch.DumpSlice(bytes: size, statedTotal: 21_196_613)
        // Volle Scheibe, aber laengst nicht alles: weitermachen.
        #expect(!CatalogStockFetch.dumpIsComplete(held: size, slice: full, sliceSize: size))
        // Kurze Scheibe mitten drin (erlaubte kurze 206): KEIN Ende,
        // sonst buchte sich ein Torso als Vollbestand.
        let short = CatalogStockFetch.DumpSlice(bytes: 1_000, statedTotal: 21_196_613)
        #expect(!CatalogStockFetch.dumpIsComplete(held: 5_000_000, slice: short, sliceSize: size))
        // Alles gehalten: fertig, auch wenn die Scheibe voll war.
        #expect(CatalogStockFetch.dumpIsComplete(held: 21_196_613, slice: full, sliceSize: size))
    }

    @Test("ohne Total bleibt die kurze Antwort das einzige ehrliche Ende")
    func withoutTotalTheShortAnswerEnds() {
        let vollAntwort = CatalogStockFetch.DumpSlice(bytes: size, statedTotal: nil)
        #expect(!CatalogStockFetch.dumpIsComplete(held: size, slice: vollAntwort, sliceSize: size))
        let kurz = CatalogStockFetch.DumpSlice(bytes: 12, statedTotal: nil)
        #expect(CatalogStockFetch.dumpIsComplete(held: 12, slice: kurz, sliceSize: size))
    }

    @Test("die Gesamtgroesse wird aus dem Content-Range gelesen")
    func totalComesFromTheHeader() {
        #expect(CatalogStockFetch.statedTotal(fromContentRange: "bytes 0-4194303/21196613") == 21_196_613)
        #expect(CatalogStockFetch.statedTotal(fromContentRange: "bytes 0-1023/*") == nil)
        #expect(CatalogStockFetch.statedTotal(fromContentRange: nil) == nil)
    }
}
