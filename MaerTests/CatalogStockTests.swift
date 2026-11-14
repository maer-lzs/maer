// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The permanently held catalog stock: the rules about it are pure,
/// so they can be checked without network and without disk.
struct CatalogStockTests {

    private func eintrag(_ id: String, subjects: [String] = [],
                         lizenz: String? = nil) -> CatalogStockEntry {
        CatalogStockEntry(id: id, title: "Titel \(id)", creator: "Wer",
                          subjects: subjects, downloads: 1, licenseurl: lizenz, year: nil)
    }

    /// The popularity page is laid onto the CURRENT stock: if a retrieval
    /// finishes between two pages, its entries, stamp and the deleted
    /// pointer stay in place. The old snapshot would have written them
    /// back, and the next start would have re-indexed the
    /// whole collection.
    @Test("a popularity page does not overwrite a finished retrieval")
    func popularityPageKeepsTheFinishedRun() {
        // Page 1 on a half stock (pointer, stamp 0).
        let halb = CatalogStockRules.partial(nil, surface: "gutenberg",
                                             entries: [eintrag("a")], cursor: "c1")
        let seite1 = CatalogStockRules.withPopularity(halb, counts: ["a": 5], nextPage: 2, complete: false)
        #expect(seite1.entries.map(\.id) == ["a"] && seite1.takenAt == 0 && seite1.fetchCursor == "c1")
        // In between the retrieval finishes: new entries, stamp today, no pointer.
        var fertig = seite1
        fertig.entries = [eintrag("a"), eintrag("b")]
        fertig.takenAt = 1_700_000_000
        fertig.fetchCursor = nil
        // Page 2 on the FRESHLY loaded stock.
        let seite2 = CatalogStockRules.withPopularity(fertig, counts: ["a": 5, "b": 7], nextPage: 3, complete: true)
        #expect(seite2.entries.map(\.id) == ["a", "b"], "der fertige Bezug hat seine Eintraege verloren")
        #expect(seite2.takenAt == 1_700_000_000, "der Stempel lief rueckwaerts")
        #expect(seite2.fetchCursor == nil, "der Zeiger ist zurueckgekommen")
        #expect(seite2.popularity == ["a": 5, "b": 7] && seite2.popularityComplete == true)
        // Red test: the old snapshot (seite1) would have done exactly that.
        #expect(seite1.entries.count == 1 && seite1.takenAt == 0)
    }

    /// A pointer next to a valid stamp cannot arise: the
    /// half form always sets the stamp to zero, and the verdict on
    /// loading reads the same invariant.
    @Test("half means pointer AND stamp zero; the verdict says resume")
    func partialAlwaysCarriesAZeroStamp() {
        var voll = CatalogStock(surface: "netlabels", takenAt: 1_700_000_000,
                                watermark: nil, entries: [eintrag("x")])
        voll.popularity = ["x": 1]
        let halb = CatalogStockRules.partial(voll, surface: "netlabels",
                                             entries: [eintrag("x"), eintrag("y")], cursor: "c9")
        #expect(halb.takenAt == 0 && halb.fetchCursor == "c9")
        #expect(halb.popularity == ["x": 1], "die Popularitaet bleibt beim Halb-Schreiben erhalten")
        #expect(CatalogStockRules.loadVerdict(halb, isDump: false) == "resume")
        #expect(CatalogStockRules.loadVerdict(voll, isDump: false) != "resume")
    }

    /// The shelf assignment moves from the service into the app, and right
    /// there the substring class could rise again, which once put a
    /// didactic drama on the crime shelf. It does not.
    @Test("the shelf assignment matches WHOLE terms, never fragments")
    func shelfAssignmentIsExact() {
        let krimi = ["crime", "detective"]
        #expect(CatalogStockRules.belongs(eintrag("a", subjects: ["Crime"]),
                                          toShelfTerms: krimi),
                "Gross- und Kleinschreibung darf nicht entscheiden")
        #expect(CatalogStockRules.belongs(
            eintrag("b", subjects: ["Fiction; Detective and mystery stories; Crime"]),
            toShelfTerms: krimi),
                "ein Begriff in einer Aufzaehlung wird nicht gefunden")

        // Red test: the fragment does NOT match. „Crimea" enthaelt „crime",
        // and that is exactly where the old form failed.
        #expect(!CatalogStockRules.belongs(eintrag("c", subjects: ["Crimea"]),
                                           toShelfTerms: krimi),
                "die Teilstring-Klasse ist lokal wieder auferstanden")
        #expect(!CatalogStockRules.belongs(eintrag("d", subjects: ["Detective work"]),
                                           toShelfTerms: krimi))
        // And without terms nothing belongs anywhere.
        #expect(!CatalogStockRules.belongs(eintrag("e", subjects: ["Crime"]),
                                           toShelfTerms: []))
    }

    /// The ONE normalization (go after the bundle-6 measurement): both
    /// assignment routes now also split the LCSH facet. The measured
    /// gap was 68 against 420 novels; the substring red test moves along.
    @Test("the facet half counts, the fragment still does not")
    func facetsCountSubstringsStillDoNot() {
        let romane = ["fiction"]
        // The facet carries the term as a WHOLE half: counts.
        #expect(CatalogStockRules.belongs(
            eintrag("f", subjects: ["England -- Fiction"]), toShelfTerms: romane),
                "die Facetten-Haelfte erreicht das Fach nicht")
        // Both routes see the same title (one truth per surface).
        #expect(CatalogGenreAxis.shelves(forSubjects: ["England -- Fiction"])
            .contains("fiction"))
        #expect(CatalogGenreAxis.shelves(
            forSubjects: ["Detective and mystery stories, English"])
            .contains("crime"),
                "der Kachel-Weg kennt den Komma-Split immer noch nicht")
        // Red test stays: „Juvenile fiction" is NOT a whole match
        // for „fiction", not even as a facet half.
        #expect(!CatalogStockRules.belongs(
            eintrag("g", subjects: ["Juvenile fiction"]), toShelfTerms: romane),
                "die Teilstring-Klasse ist durch die Facette zurueckgekommen")
        #expect(!CatalogStockRules.belongs(
            eintrag("h", subjects: ["Historical -- Juvenile fiction"]),
            toShelfTerms: romane))
    }

    /// The Browse shelf makes the WHOLE stock reachable: measured,
    /// 84 percent of the Archive audiobooks carry no subjects, no
    /// genre shelf can ever show them. Here every title counts, the count
    /// is the whole stock, and the daily excerpt has its OWN
    /// start value (the shared-place class once overwrote the day
    /// of the neighboring row).
    @Test("Browse reaches the subjectless; the gate lets in only what is declared")
    func browseReachesTheSubjectless() throws {
        // 40 with a declared license, 10 without: the popularity order
        // had pushed pirate uploads to the top, so the
        // declared license is the inclusion gate and the carried count
        // the FILTERED one.
        var eintraege = (1...40).map { i in
            CatalogStockEntry(id: "iar:\(i)", title: "T\(i)", creator: nil,
                              subjects: [], downloads: 1000 - i,
                              licenseurl: "https://creativecommons.org/x", year: nil)
        }
        eintraege += (41...50).map { i in
            CatalogStockEntry(id: "iar:\(i)", title: "Pirat\(i)", creator: nil,
                              subjects: [], downloads: 5000,
                              licenseurl: nil, year: nil)
        }
        let stock = CatalogStock(surface: "archiveBooks", takenAt: 0,
                                 watermark: nil, entries: eintraege)
        let antwort = try #require(CatalogShelfSource.localBrowse(
            rows: 12, stock: stock, source: .archiveBooks))
        guard case .archive(let docs, let total) = antwort else {
            Issue.record("falsche Antwort-Form"); return
        }
        #expect(total == 40, "die Zahl ist nicht der gefilterte Bestand")
        #expect(docs.count == 12)
        // The unlicensed ones are NOT in despite the highest downloads.
        #expect(!docs.contains { ($0.title?.first ?? "").hasPrefix("Pirat") })
        // Other sources pass the gate unfiltered (different
        // nature of stock; the red test of the rule).
        #expect(CatalogStockRules.browseEligible(eintraege[45], source: .oldTimeRadio))
        #expect(!CatalogStockRules.browseEligible(eintraege[45], source: .archiveBooks))
        // No shelf sees these titles; Browse does.
        #expect(!CatalogStockRules.belongs(eintraege[0], toShelfTerms: ["fiction"]))
        // Own start value: the salt differs from the Popular route
        // (rule on the imprint: browseAll has its own).
        #expect(CatalogRotation.salt(forShelf: CatalogGenreAxis.browseAllKey)
                != CatalogRotation.salt(forShelf: "popular"))
    }

    /// The gate of the browse shelf and the gate of a copy are one
    /// question: is a licence declared. A title the page labels "Rights
    /// not stated" never passes either.
    @Test("the gate of Browse asks the rule of the download; without a declared license never a yes", .needsTheSources)
    func browseAsksTheCopyRule() throws {
        for licence in [nil, "", "   "] as [String?] {
            let entry = CatalogStockEntry(id: "iar:x", title: "T", creator: nil, subjects: [],
                                          downloads: 1, licenseurl: licence, year: nil)
            #expect(!CatalogStockRules.browseEligible(entry, source: .archiveBooks), "\(String(describing: licence))")
            #expect(CatalogStockRules.browseEligible(entry, source: .archiveBooks)
                    == FreeCatalog.mayDownload(licenceURL: licence))
        }
        for licence in [nil, ""] as [String?] {
            #expect(FreeCatalog.licenceLabel(licence) == FreeCatalog.unstatedRights)
        }
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/CatalogStock.swift"), encoding: .utf8))
        #expect(code.contains("FreeCatalog.mayDownload(licenceURL: entry.licenseurl)"), "the browse gate decides past the copy rule")
    }

    /// A failure while reloading must NEVER destroy the stock, and
    /// neither may a valid empty answer. That is the class in which
    /// a producer ended cleanly and left a dead file behind.
    @Test("an empty answer does not delete the stock")
    func anEmptySliceKeepsTheStock() {
        let bestand = [eintrag("1"), eintrag("2")]
        #expect(CatalogStockRules.merged(bestand, with: []) == bestand,
                "eine leere Antwort hat den Bestand geleert")

        // Red test on the instrument: a NON-empty answer certainly takes effect,
        // and a known entry is replaced instead of doubled.
        let frisch = [eintrag("2", subjects: ["neu"]), eintrag("3")]
        let zusammen = CatalogStockRules.merged(bestand, with: frisch)
        #expect(zusammen.map(\.id) == ["1", "2", "3"])
        #expect(zusammen.first { $0.id == "2" }?.subjects == ["neu"],
                "der frische Eintrag hat den alten nicht abgeloest")
    }

    /// The reload cadence hangs on the same day change as the rotation and
    /// the day store. A deadline of its own would be the third clock.
    @Test("reloading happens at the day change, not after a deadline of its own")
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

    /// The rights situation travels with the stock. Measured: the scoop endpoint
    /// delivers `licenseurl` (netlabels 872 of 1000), georgeblood simply
    /// has none. If it is missing, it stays empty instead of being guessed.
    @Test("the rights situation travels along and is never invented")
    func theLicenceTravelsAndIsNeverInvented() {
        let mit = eintrag("a", lizenz: "https://creativecommons.org/licenses/by-sa/4.0/")
        let ohne = eintrag("b")
        #expect(mit.licenseurl != nil)
        #expect(ohne.licenseurl == nil, "eine fehlende Lizenz ist erfunden worden")
        // And it survives the write path: what is stored must
        // be readable, otherwise the capsule would one day be empty.
        let wieder = try? JSONDecoder().decode(
            CatalogStockEntry.self, from: JSONEncoder().encode(mit))
        #expect(wieder?.licenseurl == mit.licenseurl)
    }

    /// The stock is DERIVED: the lever clears it, and it does not lie
    /// among the user's things. Without this case the lever would clear only
    /// keys and leave the largest part on the device.
    @Test("the stock is derived and is cleared by the lever")
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

        // The name of the lever entry stands in ONE place, so that report
        // and fence say the same thing.
        #expect(!DerivedStores.stockLabel.isEmpty)
        #expect(!DerivedStores.userOwnedPrefixes.contains { name.hasPrefix($0) },
                "der Bestand liegt bei den Nutzer-Sachen")
    }

    /// A shelf from the held stock: the same order as before from the
    /// server, only without network. And it does NOT answer where the stock does not
    /// know the popularity at all. There every local order would be
    /// invented.
    @Test("a shelf comes from the stock, but only with real popularity")
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

        // WITHOUT popularity it does not answer at all: the Gutenberg dump
        // carries no download counts, and an invented order would be
        // worse than a query.
        // The rule itself, not the surface entry: a Gutenberg shelf does not
        // answer from the stock at all, and that would hide what is asked here.
        let ohne = CatalogStock(surface: "gutenberg", takenAt: 1_756_000_000, watermark: nil,
                                entries: [mit("x", nil, [begriff])])
        #expect(CatalogShelfSource.localShelf(terms: CatalogGenreAxis.subjects(forShelf: "crime"),
                                              shelf: "crime", rows: 12, stock: ohne) == nil,
                "ein Fach ohne Popularitaet erfindet eine Reihenfolge")
    }

    /// Route 3: the popularity that the dump does not carry is enumerated
    /// afterwards. A HALF enumeration must not order a shelf, otherwise
    /// the order of whatever happened to be fetched already would stand there.
    @Test("a half enumeration orders no shelf, a whole one does")
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
        let terms = CatalogGenreAxis.subjects(forShelf: "crime")
        #expect(CatalogShelfSource.localShelf(terms: terms, shelf: "crime",
                                              rows: 12, stock: bestand) == nil,
                "eine halbe Aufzaehlung ordnet das Fach schon")

        // Whole: now it orders, and by the real count.
        bestand.popularityComplete = true
        let antwort = try #require(CatalogShelfSource.localShelf(
            terms: terms, shelf: "crime", rows: 12, stock: bestand))
        guard case .archive(let docs, _) = antwort else {
            Issue.record("das Fach antwortet nicht"); return
        }
        #expect(docs.first?.identifier == "gut:2", "die aufgezaehlte Zahl ordnet nicht")
        // And the source's own count beats the enumerated one, because a
        // source that names it is the better witness.
        let mitEigener = CatalogStockEntry(id: "gut:1", title: "T", creator: nil,
                                           subjects: [begriff], downloads: 500,
                                           licenseurl: nil, year: nil)
        #expect(bestand.downloads(of: mitEigener) == 500)
    }

    /// Every thirty days the collection comes anew in full. The daily run
    /// fetches only new arrivals, so it would never correct the
    /// drifting counts.
    @Test("every thirty days the collection is fetched anew in full")
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
        // And the daily cadence stays untouched by it.
        #expect(CatalogStockRules.needsRefresh(bestand, now: heute.addingTimeInterval(24 * 3600)))
    }

    /// A status line speaks the user's language. The state therefore carries
    /// NO text at all: it can no longer bring a raw error, an address or a
    /// task identifier onto a surface.
    ///
    /// That is exactly what had happened: the Popular full page carried the complete
    /// NSError including the scoop address with the pointer token, because the state
    /// took whatever the error yielded when stringified.
    @Test("the failed state can no longer carry raw text", .needsTheSources)
    func theFailedStateCannotCarryRawText() throws {
        // The state is an enumeration WITHOUT an associated value. If it were
        // not, any text could be put in here.
        let zustand = CatalogStockService.State.failed
        #expect(zustand == .failed)
        #expect(zustand != .idle)

        // Red test on the source text: the state must not get a string.
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewModels/CatalogStockService.swift"),
            encoding: .utf8)
        #expect(!text.contains("case failed(String)"),
                "der Fehlzustand traegt wieder Text von aussen")

        // And the REPORTING POINT passes no raw error to the surface.
        // Limited to the function, not to the file: in a LOG line
        // the raw error is right, and a fence across the whole file
        // forbids the right thing too. That is exactly where it failed
        // on the first run.
        let rumpf = try #require(functionBody(
            of: "private func report(_ error: Error, surface: String) {", in: text))
        #expect(rumpf.contains("guard !error.isCancellation"),
                "ein Abbruch wird wieder als Fehler der Flaeche gemeldet")
        #expect(!rumpf.contains("states[surface] = .failed(") ,
                "der Fehlzustand bekommt wieder einen Text gereicht")
    }

    /// The first retrieval SURVIVES. An app switch costs the last slice,
    /// never the run: what was reached is written down with the pointer
    /// at which it stood.
    @Test("an interrupted first retrieval carries its pointer and does not count as today")
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

        // And the half stock does NOT count as an answer from today: otherwise
        // the refresh rule would have taken it for finished and the rest
        // would never have been fetched.
        #expect(CatalogStockRules.needsRefresh(gelesen),
                "ein halber Bestand gilt als die Antwort von heute")
    }

    /// Without Wi-Fi the user is ASKED, not blocked, and the question names a
    /// MEASURED size. An estimated number in this question would be a
    /// claim about someone else's money.
    @Test("the cellular question names a measured size per collection")
    func theCellularQuestionNamesAMeasuredSize() {
        for flaeche in ["librivox", "archiveBooks", "oldTimeRadio", "netlabels",
                        ArchiveMusicCatalog.shellacAll.key, "gutenberg"] {
            let mb = CatalogStockFetch.transferMegabytes(surface: flaeche)
            #expect(mb != nil, "\(flaeche) hat keine Groesse fuer die Frage")
            #expect((mb ?? 0) > 0)
        }
        // The sizes follow the stocks: the largest collection costs
        // the most. Without this check the same number could stand everywhere.
        let gross = CatalogStockFetch.transferMegabytes(surface: "netlabels") ?? 0
        let klein = CatalogStockFetch.transferMegabytes(surface: "oldTimeRadio") ?? 0
        #expect(gross > klein * 5, "die Zahlen unterscheiden die Sammlungen nicht")
        // Red test: a surface that does not exist has no number.
        #expect(CatalogStockFetch.transferMegabytes(surface: "gibt-es-nicht") == nil)
    }

    /// The word the start log carries for a loaded stock. A partial run
    /// keeps `takenAt` at zero; without the cursor being read it looked
    /// like "never fetched" at every start.
    @Test("the load verdict: ready, delta, resume, full")
    func loadVerdict() {
        let now = Date(timeIntervalSince1970: 1_756_900_000)
        let today = now.timeIntervalSince1970 - 60
        var stock = CatalogStock(surface: "archiveBooks", takenAt: today, watermark: nil, entries: [])
        #expect(CatalogStockRules.loadVerdict(stock, isDump: false, now: now) == "ready")
        stock.takenAt = today - 2 * 86_400
        #expect(CatalogStockRules.loadVerdict(stock, isDump: false, now: now) == "delta")
        stock.takenAt = today - 40 * 86_400
        #expect(CatalogStockRules.loadVerdict(stock, isDump: false, now: now) == "full")
        stock.takenAt = 0
        #expect(CatalogStockRules.loadVerdict(stock, isDump: false, now: now) == "full")
        stock.fetchCursor = "page-7"
        #expect(CatalogStockRules.loadVerdict(stock, isDump: false, now: now) == "resume")
        #expect(CatalogStockRules.loadVerdict(nil, isDump: false, now: now) == "full")
    }

    /// A full refetch replaces the stock and never appends to it; a stock
    /// that holds an id twice is healed once at its next read.
    @Test("a full refetch replaces and does not append; a doubled stock is de-duplicated once")
    func aFullRefetchReplaces() {
        let old = [eintrag("a"), eintrag("b")]
        var fresher = eintrag("a")
        fresher.downloads = 9
        let doubled = old + [fresher, eintrag("b"), eintrag("c")]
        let healed = CatalogStockRules.deduplicated(doubled)
        #expect(healed.map(\.id) == ["a", "b", "c"], "an id stayed twice: \(healed.map(\.id))")
        #expect(healed.first?.downloads == 9, "the older entry won over the fresher")
        #expect(CatalogStockRules.deduplicated(old) == old)
    }

    @Test("the full refetch does not seed from a whole stock and writes no part over it", .needsTheSources)
    func theRefetchLeavesTheWholeStockStanding() throws {
        let service = try FetchAnswerTests.squeezedSource("Sources/ViewModels/CatalogStockService.swift")
        #expect(service.contains("let replacesWhole = stored != nil && stored?.fetchCursor == nil let angefangen = replacesWhole ? nil : stored"),
                "the refetch seeds from the whole stock again")
        #expect(service.contains("if cursor != nil, !replacesWhole { keepPartial("), "a partial is written over the whole stock")
        #expect(service.contains("stock.entries = CatalogStockRules.deduplicated(entries)"))
        let store = try FetchAnswerTests.squeezedSource("Sources/Networking/CatalogStockStore.swift")
        #expect(store.contains("let once = CatalogStockRules.deduplicated(stock.entries)"), "a doubled stock is not healed at its read")
    }
}
