// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

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
}
