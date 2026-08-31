// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// Der dauerhaft gehaltene Katalog-Bestand: die Regeln daruber sind pur,
/// also ohne Netz und ohne Platte pruefbar.
struct CatalogStockTests {

    private func eintrag(_ id: String, subjects: [String] = [],
                         lizenz: String? = nil) -> CatalogStockEntry {
        CatalogStockEntry(id: id, title: "Titel \(id)", creator: "Wer",
                          subjects: subjects, downloads: 1, licenseurl: lizenz, year: nil)
    }

    /// Die Fach-Zuordnung wandert vom Dienst in die App, und genau dort
    /// koennte die Teilstring-Klasse wieder auferstehen, die einmal ein
    /// Didaktik-Drama ins Krimi-Fach gestellt hat. Sie tut es nicht.
    @Test("die Fach-Zuordnung trifft GANZE Begriffe, nie Teilstuecke")
    func shelfAssignmentIsExact() {
        let krimi = ["crime", "detective"]
        #expect(CatalogStockRules.belongs(eintrag("a", subjects: ["Crime"]),
                                          toShelfTerms: krimi),
                "Gross- und Kleinschreibung darf nicht entscheiden")
        #expect(CatalogStockRules.belongs(
            eintrag("b", subjects: ["Fiction; Detective and mystery stories; Crime"]),
            toShelfTerms: krimi),
                "ein Begriff in einer Aufzaehlung wird nicht gefunden")

        // Rot-Probe: das Teilstueck trifft NICHT. „Crimea" enthaelt „crime",
        // und genau daran ist die alte Form gescheitert.
        #expect(!CatalogStockRules.belongs(eintrag("c", subjects: ["Crimea"]),
                                           toShelfTerms: krimi),
                "die Teilstring-Klasse ist lokal wieder auferstanden")
        #expect(!CatalogStockRules.belongs(eintrag("d", subjects: ["Detective work"]),
                                           toShelfTerms: krimi))
        // Und ohne Begriffe gehoert nichts irgendwohin.
        #expect(!CatalogStockRules.belongs(eintrag("e", subjects: ["Crime"]),
                                           toShelfTerms: []))
    }

    /// Die EINE Normierung (Go nach der Buendel-6-Messung): beide
    /// Zuordnungswege splitten jetzt auch die LCSH-Facette. Gemessen war
    /// der Riss 68 gegen 420 Romane; die Teilstring-Rot-Probe wandert mit.
    @Test("die Facetten-Haelfte zaehlt, das Teilstueck weiter nicht")
    func facetsCountSubstringsStillDoNot() {
        let romane = ["fiction"]
        // Die Facette traegt den Begriff als GANZE Haelfte: zaehlt.
        #expect(CatalogStockRules.belongs(
            eintrag("f", subjects: ["England -- Fiction"]), toShelfTerms: romane),
                "die Facetten-Haelfte erreicht das Fach nicht")
        // Beide Wege sehen denselben Titel (eine Wahrheit je Flaeche).
        #expect(CatalogGenreAxis.shelves(forSubjects: ["England -- Fiction"])
            .contains("fiction"))
        #expect(CatalogGenreAxis.shelves(
            forSubjects: ["Detective and mystery stories, English"])
            .contains("crime"),
                "der Kachel-Weg kennt den Komma-Split immer noch nicht")
        // Rot-Probe bleibt: „Juvenile fiction" ist KEIN ganzer Treffer
        // fuer „fiction", auch nicht als Facetten-Haelfte.
        #expect(!CatalogStockRules.belongs(
            eintrag("g", subjects: ["Juvenile fiction"]), toShelfTerms: romane),
                "die Teilstring-Klasse ist durch die Facette zurueckgekommen")
        #expect(!CatalogStockRules.belongs(
            eintrag("h", subjects: ["Historical -- Juvenile fiction"]),
            toShelfTerms: romane))
    }

    /// Das Stoebern-Fach macht den GANZEN Bestand erreichbar: gemessen
    /// tragen 84 Prozent der Archive-Hoerbuecher keine Subjects, kein
    /// Genre-Fach kann sie je zeigen. Hier zaehlt jeder Titel, die Zahl
    /// ist der ganze Bestand, und der Tages-Ausschnitt hat seinen EIGENEN
    /// Startwert (die Geteilter-Platz-Klasse ueberschrieb einst den Tag
    /// der Nachbar-Reihe).
    @Test("Stoebern erreicht das Subjektlose und traegt die ganze Zahl")
    func browseReachesTheSubjectless() throws {
        let eintraege = (1...40).map { i in
            CatalogStockEntry(id: "iar:\(i)", title: "T\(i)", creator: nil,
                              subjects: [], downloads: 1000 - i,
                              licenseurl: nil, year: nil)
        }
        let stock = CatalogStock(surface: "archiveBooks", takenAt: 0,
                                 watermark: nil, entries: eintraege)
        let antwort = try #require(CatalogShelfSource.localBrowse(rows: 12, stock: stock))
        guard case .archive(let docs, let total) = antwort else {
            Issue.record("falsche Antwort-Form"); return
        }
        #expect(total == 40, "die Zahl ist nicht der ganze Bestand")
        #expect(docs.count == 12)
        // Kein Fach sieht diese Titel; das Stoebern schon.
        #expect(!CatalogStockRules.belongs(eintraege[0], toShelfTerms: ["fiction"]))
        // Eigener Startwert: das Salz unterscheidet sich vom Beliebt-Weg
        // (Regel am Abdruck: browseAll hat seinen eigenen).
        #expect(CatalogRotation.salt(forShelf: CatalogGenreAxis.browseAllKey)
                != CatalogRotation.salt(forShelf: "popular"))
    }

    /// Ein Fehlschlag beim Nachladen darf den Bestand NIE zerstoeren, und
    /// eine gueltige leere Antwort auch nicht. Das ist die Klasse, in der
    /// ein Erzeuger sauber endete und eine tote Datei hinterliess.
    @Test("eine leere Antwort loescht den Bestand nicht")
    func anEmptySliceKeepsTheStock() {
        let bestand = [eintrag("1"), eintrag("2")]
        #expect(CatalogStockRules.merged(bestand, with: []) == bestand,
                "eine leere Antwort hat den Bestand geleert")

        // Rot-Probe am Instrument: eine NICHT leere Antwort wirkt sehr wohl,
        // und ein bekannter Eintrag wird ersetzt statt verdoppelt.
        let frisch = [eintrag("2", subjects: ["neu"]), eintrag("3")]
        let zusammen = CatalogStockRules.merged(bestand, with: frisch)
        #expect(zusammen.map(\.id) == ["1", "2", "3"])
        #expect(zusammen.first { $0.id == "2" }?.subjects == ["neu"],
                "der frische Eintrag hat den alten nicht abgeloest")
    }

    /// Der Nachlade-Takt haengt am selben Tageswechsel wie die Rotation und
    /// der Tages-Speicher. Eine eigene Frist waere die dritte Uhr.
    @Test("nachgeladen wird am Tageswechsel, nicht nach einer eigenen Frist")
    func refreshFollowsTheOneClock() {
        let heute = Date(timeIntervalSince1970: 1_756_000_000)
        let bestand = CatalogStock(surface: "librivoxaudio",
                                   takenAt: heute.timeIntervalSince1970,
                                   watermark: nil, entries: [])
        #expect(!CatalogStockRules.needsRefresh(bestand, now: heute))
        #expect(!CatalogStockRules.needsRefresh(bestand,
                                                now: heute.addingTimeInterval(3600)),
                "ein paar Stunden spaeter ist noch derselbe Tag")
        let morgen = heute.addingTimeInterval(24 * 3600)
        #expect(CatalogRotation.dayIndex(on: morgen) == CatalogRotation.dayIndex(on: heute) + 1)
        #expect(CatalogStockRules.needsRefresh(bestand, now: morgen))
    }

    /// Die Rechtelage reist im Bestand mit. Gemessen: der Schoepf-Endpunkt
    /// liefert `licenseurl` (netlabels 872 von 1000), georgeblood hat
    /// schlicht keine. Fehlt sie, bleibt sie leer statt geraten zu werden.
    @Test("die Rechtelage reist mit und wird nie erfunden")
    func theLicenceTravelsAndIsNeverInvented() {
        let mit = eintrag("a", lizenz: "https://creativecommons.org/licenses/by-sa/4.0/")
        let ohne = eintrag("b")
        #expect(mit.licenseurl != nil)
        #expect(ohne.licenseurl == nil, "eine fehlende Lizenz ist erfunden worden")
        // Und sie ueberlebt den Schreibweg: was gespeichert wird, muss
        // gelesen werden koennen, sonst waere die Kapsel eines Tages leer.
        let wieder = try? JSONDecoder().decode(
            CatalogStockEntry.self, from: JSONEncoder().encode(mit))
        #expect(wieder?.licenseurl == mit.licenseurl)
    }

    /// Der Bestand ist ABGELEITET: der Hebel raeumt ihn, und er liegt nicht
    /// bei den Nutzer-Sachen. Ohne diesen Fall raeumte der Hebel nur
    /// Schluessel und liesse das Groesste auf dem Geraet liegen.
    @Test("der Bestand ist abgeleitet und wird vom Hebel geraeumt")
    func theStockIsDerivedAndTheLeverClearsIt() throws {
        let store = CatalogStockStore.shared
        let name = "pruef-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: CatalogStockStore.fileURL(surface: name)) }

        #expect(store.load(surface: name) == nil, "der Bestand war schon da")
        let bestand = CatalogStock(surface: name, takenAt: 1_756_000_000,
                                   watermark: "2026-08-29", entries: [eintrag("1")])
        #expect(store.save(bestand), "der Bestand liess sich nicht schreiben")
        let gelesen = try #require(store.load(surface: name))
        #expect(gelesen.entries.map(\.id) == ["1"])
        #expect(gelesen.watermark == "2026-08-29",
                "die Marke fuer das Nachladen ueberlebt den Schreibweg nicht")
        #expect(store.keptSurfaces().contains(name))

        // Der Name des Hebel-Eintrags steht an EINER Stelle, damit Meldung
        // und Zaun dasselbe sagen.
        #expect(!DerivedStores.stockLabel.isEmpty)
        #expect(!DerivedStores.userOwnedPrefixes.contains { name.hasPrefix($0) },
                "der Bestand liegt bei den Nutzer-Sachen")
    }

    /// Ein Fach aus dem gehaltenen Bestand: dieselbe Ordnung wie vorher vom
    /// Server, nur ohne Netz. Und es antwortet NICHT, wo der Bestand die
    /// Popularitaet gar nicht kennt — dort waere jede lokale Reihenfolge
    /// erfunden.
    @Test("ein Fach kommt aus dem Bestand, aber nur mit echter Popularitaet")
    func aShelfComesFromTheStockOnlyWithRealPopularity() throws {
        func mit(_ id: String, _ downloads: Int?, _ subjects: [String]) -> CatalogStockEntry {
            CatalogStockEntry(id: id, title: "T\(id)", creator: nil, subjects: subjects,
                              downloads: downloads, licenseurl: nil, year: nil)
        }
        let begriffe = CatalogGenreAxis.subjects(forShelf: "crime")
        let begriff = try #require(begriffe.first)
        let bestand = CatalogStock(
            surface: "librivoxaudio", takenAt: 1_756_000_000, watermark: nil,
            entries: [mit("a", 10, [begriff]), mit("b", 99, [begriff]),
                      mit("c", 5, ["etwas anderes"])])

        let antwort = try #require(CatalogShelfSource.localShelf(
            surface: "librivoxaudio", shelf: "crime", rows: 12, stock: bestand))
        guard case .archive(let docs, let total) = antwort else {
            Issue.record("das Fach antwortet nicht mit Archive-Kacheln"); return
        }
        #expect(total == 2, "der fremde Eintrag ist im Fach gelandet")
        #expect(docs.first?.identifier == "b", "die Popularitaet ordnet nicht")

        // OHNE Popularitaet antwortet es gar nicht: der Gutenberg-Abzug
        // traegt keine Download-Zahlen, und eine erfundene Reihenfolge waere
        // schlimmer als eine Abfrage.
        let ohne = CatalogStock(surface: "gutenberg", takenAt: 1_756_000_000, watermark: nil,
                                entries: [mit("x", nil, [begriff])])
        #expect(CatalogShelfSource.localShelf(surface: "gutenberg", shelf: "crime",
                                              rows: 12, stock: ohne) == nil,
                "ein Fach ohne Popularitaet erfindet eine Reihenfolge")
    }

    /// Weg 3: die Popularitaet, die der Abzug nicht traegt, wird nachtraeglich
    /// aufgezaehlt. Eine HALBE Aufzaehlung darf ein Fach nicht ordnen, sonst
    /// staende dort die Reihenfolge dessen, was zufaellig schon geholt war.
    @Test("eine halbe Aufzaehlung ordnet kein Fach, eine ganze schon")
    func aPartialRankingOrdersNothing() throws {
        let begriff = try #require(CatalogGenreAxis.subjects(forShelf: "crime").first)
        func ohneZahl(_ id: String) -> CatalogStockEntry {
            CatalogStockEntry(id: id, title: "T\(id)", creator: nil, subjects: [begriff],
                              downloads: nil, licenseurl: nil, year: nil)
        }
        var bestand = CatalogStock(surface: "gutenberg", takenAt: 1_756_000_000,
                                   watermark: nil,
                                   entries: [ohneZahl("gut:1"), ohneZahl("gut:2")])
        bestand.popularity = ["gut:1": 10, "gut:2": 99]
        bestand.popularityComplete = false
        #expect(CatalogShelfSource.localShelf(surface: "gutenberg", shelf: "crime",
                                              rows: 12, stock: bestand) == nil,
                "eine halbe Aufzaehlung ordnet das Fach schon")

        // Ganz: jetzt ordnet sie, und zwar nach der echten Zahl.
        bestand.popularityComplete = true
        let antwort = try #require(CatalogShelfSource.localShelf(
            surface: "gutenberg", shelf: "crime", rows: 12, stock: bestand))
        guard case .archive(let docs, _) = antwort else {
            Issue.record("das Fach antwortet nicht"); return
        }
        #expect(docs.first?.identifier == "gut:2", "die aufgezaehlte Zahl ordnet nicht")
        // Und die eigene Zahl der Quelle schlaegt die aufgezaehlte, weil eine
        // Quelle, die sie nennt, der bessere Zeuge ist.
        let mitEigener = CatalogStockEntry(id: "gut:1", title: "T", creator: nil,
                                           subjects: [begriff], downloads: 500,
                                           licenseurl: nil, year: nil)
        #expect(bestand.downloads(of: mitEigener) == 500)
    }

    /// Alle dreissig Tage kommt die Sammlung ganz neu. Der taegliche Lauf
    /// holt nur Neuzugaenge, also wuerde er die driftenden Zahlen nie
    /// berichtigen.
    @Test("alle dreissig Tage wird die Sammlung ganz neu geholt")
    func everyThirtyDaysTheWholeCollectionComesAgain() {
        let heute = Date(timeIntervalSince1970: 1_756_000_000)
        let bestand = CatalogStock(surface: "librivoxaudio",
                                   takenAt: heute.timeIntervalSince1970,
                                   watermark: nil, entries: [])
        #expect(!CatalogStockRules.needsFullRefetch(bestand, now: heute))
        let fastGenug = heute.addingTimeInterval(29 * 24 * 3600)
        #expect(!CatalogStockRules.needsFullRefetch(bestand, now: fastGenug),
                "29 Tage sind noch keine 30")
        let dreissig = heute.addingTimeInterval(30 * 24 * 3600)
        #expect(CatalogStockRules.needsFullRefetch(bestand, now: dreissig))
        // Und der taegliche Takt bleibt davon unberuehrt.
        #expect(CatalogStockRules.needsRefresh(bestand, now: heute.addingTimeInterval(24 * 3600)))
    }

    /// Eine Statuszeile spricht Nutzersprache. Der Zustand traegt darum
    /// GAR KEINEN Text: er kann keinen Roh-Fehler, keine Adresse und keine
    /// Aufgaben-Kennung mehr auf eine Flaeche bringen.
    ///
    /// Genau das war passiert: die Beliebt-Vollseite trug den kompletten
    /// NSError samt Schoepf-Adresse mit Zeiger-Token, weil der Zustand
    /// nahm, was der Fehler beim Stringifizieren hergab.
    @Test("der Fehlzustand kann keinen Rohtext mehr tragen")
    func theFailedStateCannotCarryRawText() throws {
        // Der Zustand ist eine Aufzaehlung OHNE zugeordneten Wert. Waere er
        // es nicht, liesse sich hier ein beliebiger Text hineinlegen.
        let zustand = CatalogStockService.State.failed
        #expect(zustand == .failed)
        #expect(zustand != .idle)

        // Rot-Probe am Quelltext: der Zustand darf keinen String bekommen.
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewModels/CatalogStockService.swift"),
            encoding: .utf8)
        #expect(!text.contains("case failed(String)"),
                "der Fehlzustand traegt wieder Text von aussen")

        // Und die MELDESTELLE reicht keinen rohen Fehler an die Flaeche.
        // Auf die Funktion begrenzt, nicht auf die Datei: in einer LOG-Zeile
        // ist der rohe Fehler richtig, und ein Zaun ueber die ganze Datei
        // verbietet das Richtige mit. Genau daran ist er beim ersten Lauf
        // gerissen.
        let rumpf = try #require(functionBody(
            of: "private func report(_ error: Error, surface: String) {", in: text))
        #expect(rumpf.contains("guard !error.isCancellation"),
                "ein Abbruch wird wieder als Fehler der Flaeche gemeldet")
        #expect(!rumpf.contains("states[surface] = .failed(") ,
                "der Fehlzustand bekommt wieder einen Text gereicht")
    }

    /// Der Erstbezug UEBERLEBT. Ein App-Wechsel kostet die letzte Scheibe,
    /// nie den Lauf: das Erreichte wird mit dem Zeiger niedergeschrieben,
    /// an dem es stand.
    @Test("ein unterbrochener Erstbezug traegt seinen Zeiger und gilt nicht als heute")
    func anInterruptedFirstFetchKeepsItsCursor() throws {
        let store = CatalogStockStore.shared
        let name = "teil-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: CatalogStockStore.fileURL(surface: name)) }

        var teil = CatalogStock(surface: name, takenAt: 0, watermark: nil,
                                entries: [eintrag("1")])
        teil.fetchCursor = "abc123"
        #expect(store.save(teil))
        let gelesen = try #require(store.load(surface: name))
        #expect(gelesen.fetchCursor == "abc123", "der Zeiger ueberlebt den Schreibweg nicht")

        // Und der halbe Bestand gilt NICHT als Antwort von heute: sonst
        // haette die Auffrisch-Regel ihn fuer fertig gehalten und der Rest
        // waere nie geholt worden.
        #expect(CatalogStockRules.needsRefresh(gelesen),
                "ein halber Bestand gilt als die Antwort von heute")
    }

    /// Ohne WLAN wird GEFRAGT, nicht gesperrt — und die Frage nennt eine
    /// GEMESSENE Groesse. Eine geschaetzte Zahl in dieser Frage waere eine
    /// Behauptung ueber fremdes Geld.
    @Test("die Mobilfunk-Frage nennt eine gemessene Groesse je Sammlung")
    func theCellularQuestionNamesAMeasuredSize() {
        for flaeche in ["librivox", "archiveBooks", "oldTimeRadio", "netlabels",
                        "shellac-all", "gutenberg"] {
            let mb = CatalogStockFetch.transferMegabytes(surface: flaeche)
            #expect(mb != nil, "\(flaeche) hat keine Groesse fuer die Frage")
            #expect((mb ?? 0) > 0)
        }
        // Die Groessen folgen den Bestaenden: die groesste Sammlung kostet
        // am meisten. Ohne diese Probe koennte ueberall dieselbe Zahl stehen.
        let gross = CatalogStockFetch.transferMegabytes(surface: "shellac-all") ?? 0
        let klein = CatalogStockFetch.transferMegabytes(surface: "oldTimeRadio") ?? 0
        #expect(gross > klein * 5, "die Zahlen unterscheiden die Sammlungen nicht")
        // Rot-Probe: eine Flaeche, die es nicht gibt, hat keine Zahl.
        #expect(CatalogStockFetch.transferMegabytes(surface: "gibt-es-nicht") == nil)
    }
}
