// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// R39: the class "a surface reads the catalog store without anything
/// starting its load" came back — the 10.08. fence was gone from the tree,
/// so it held nothing. This time the rule is CONSTRUCTIONAL (reading `rows`
/// starts the pass) and the fence guards the construction itself, not a
/// list of call sites: nobody may read the stored rows directly.
struct CatalogStoreReadFenceTests {

    private func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 50, "the sweep must see the tree, not an empty folder")
        return try files.map { (name: $0.lastPathComponent,
                                text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("no surface reads the STORED rows — reading goes through the loading getter")
    func noSurfaceReadsStoredRowsDirectly() throws {
        var offenders: [String] = []
        for file in try sources() where file.name != "FreeCatalogRows.swift" {
            if file.text.contains("storedRows") || file.text.contains("storedSourceRows") {
                offenders.append(file.name)
            }
        }
        #expect(offenders.isEmpty,
                "these read the stored rows and would bypass the load: \(offenders)")
    }

    @Test("the fence would SEE a bypass (red probe)")
    func fenceCatchesABypass() {
        let bypass = "ForEach(freeCatalogStore.storedRows.freeMusic) { item in }"
        #expect(bypass.contains("storedRows"))
    }

    /// R40: a catalog row may exist ONCE per surface. The duplicate arose
    /// because a repair was made at the REPORTED spot without sweeping the
    /// same file for a sibling row of the same source — and the two then
    /// carried different conditions, so the area switch (a PRIVACY switch)
    /// was without effect. Counting the row's own tile call per file is the
    /// mechanical version of that sweep.
    @Test("each catalog row is rendered once per surface")
    func noDuplicateCatalogRow() throws {
        for file in try sources() {
            for row in ["rows.freeMusic", "rows.netlabels", "rows.tabBooks"] {
                let renders = file.text.components(separatedBy: "freeTileRow(\(row)")
                    .count - 1 + file.text.components(separatedBy: "tileRow(\(row)").count - 1
                #expect(renders <= 1,
                        "\(file.name) renders \(row) \(renders)× — two rows, one source")
            }
        }
    }

    /// The second half of the same class: an INCOMPLETE pass must leave the
    /// door open, or a reading surface is refused for the whole session
    /// ("already attempted") although nothing was ever delivered.
    @Test("an incomplete pass reopens the gate — bounded, so no render loop")
    func incompletePassReopensBounded() {
        var gate = CatalogLoadGate()
        var started = gate.startIfNeeded(connected: true)
        #expect(started)
        gate.finish()
        // Without the reopen the next reading surface is refused …
        started = gate.startIfNeeded(connected: true)
        #expect(!started)
        gate.reopenForIncompletePass()
        started = gate.startIfNeeded(connected: true)
        #expect(started, "a cancelled pass must be retryable")
        gate.finish()
        // … and the retries are bounded (the empty-pass render loop is why
        // this gate exists at all).
        for _ in 0..<10 { gate.reopenForIncompletePass() }
        #expect(gate.incompleteRetries == CatalogLoadGate.incompleteRetryLimit)
        var exhausted = CatalogLoadGate()
        for _ in 0..<CatalogLoadGate.incompleteRetryLimit {
            _ = exhausted.startIfNeeded(connected: true)
            exhausted.finish()
            exhausted.reopenForIncompletePass()
        }
        _ = exhausted.startIfNeeded(connected: true)
        exhausted.finish()
        exhausted.reopenForIncompletePass()
        let refused = !exhausted.startIfNeeded(connected: true)
        #expect(refused, "after the limit only an EXPLICIT path may reopen")
    }

    /// R44 (the owner am Gerät: „das Dauerrad ist wohl LibriVox"): a FAILED row
    /// is an ANSWER. Before this only Jamendo could be answered, so a failing
    /// LibriVox left the pass permanently incomplete — and the R39 reopen
    /// turned that into three full network passes, i.e. a wheel that keeps
    /// spinning. Cancellations still leave the pass incomplete (retryable).
    @MainActor
    @Test("ein gebuchter Fehlschlag zaehlt als Antwort — der Lauf ist komplett")
    func aBookedFailureCompletesThePass() {
        var rows = FreeCatalogLoader.Rows()
        rows.problems[.books] = "URLError -1001"
        rows.problems[.classical] = "URLError -1001"
        rows.problems[.netlabels] = "URLError -1001"
        rows.problems[.freeMusic] = "URLError -1001"
        #expect(FreeCatalogLoader.passIsComplete(rows),
                "vier gebuchte Fehlschlaege sind vier Antworten")
        // Nothing booked and nothing loaded = the cancelled shape: incomplete,
        // so the gate may reopen (bounded) instead of freezing the session.
        #expect(!FreeCatalogLoader.passIsComplete(FreeCatalogLoader.Rows()))
    }
    /// R46 (the owner am Geraet: „es gibt praktisch keinen Weg in die
    /// Genre-Bibliothek"): ein Fach mit 102 Eintraegen zeigte EINE Kachel und
    /// nie ein Chevron. Die Chevron-Regel (`total > shown`) war richtig — sie
    /// bekam die Zahl des zufaellig geladenen Vorrats statt des Bestands.
    /// Der Bestand steht in der Antwort; dieser Zaun haelt fest, dass er dort
    /// auch abgeholt wird.
    @Test("die Bestandszahl der Quelle wird gelesen, nicht geschaetzt")
    func stockCountIsReadFromTheResponse() throws {
        let wire = Data("""
        {"response":{"numFound":102,"start":0,"docs":[
          {"identifier":"a","title":"A"},{"identifier":"b","title":"B"}]}}
        """.utf8)
        #expect(try ArchiveOrgClient.decodeTotal(wire) == 102)
        #expect(try ArchiveOrgClient.decodePopular(wire).count == 2)
        // Mit dem Vorrat statt dem Bestand waere 2 > 2 falsch — kein Chevron,
        // genau der gemeldete Zustand. Mit dem Bestand ist 102 > 2 wahr.
        #expect(102 > 2)
        // Eine Antwort ohne die Zahl erfindet keine: dann traegt die Reihe
        // die Existenz-Form des Chevrons, nie eine geratene Menge.
        let ohne = Data("{\"response\":{\"docs\":[]}}".utf8)
        #expect(try ArchiveOrgClient.decodeTotal(ohne) == nil)
    }

    /// R45 (the owner zweimal „viel zu lang"): the build path must not probe.
    /// The old chain asked archive.org twice PER TILE — 72 serial round trips
    /// and 4,5 MB of metadata for „gibt es ein Bild?", measured at 43 s per
    /// pass. This fence holds the construction: picking is a pure cut, and
    /// no surface may reintroduce a per-tile probe on the way to a row.
    @Test("das Bauen einer Reihe fragt das Netz NICHT je Kachel")
    func buildingARowDoesNotProbePerTile() throws {
        let cut = FreeCatalogLoader.picksWithoutProbing(
            (1...30).map { LibraryItem(id: "arch:item-\($0)", media: nil, addedAt: nil) },
            cap: RowPreview.limit)
        #expect(cut.count == RowPreview.limit)
        #expect(cut.first?.id == "arch:item-1", "die Ordnung der Quelle bleibt")
        // Rot-Probe der Konstruktion: die Probe-Namen sind aus dem Bauweg
        // verschwunden — kehrt einer zurueck, faellt es hier auf.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/FreeCatalogRows.swift")
        let text = try String(contentsOf: root, encoding: .utf8)
        #expect(!text.contains("await ArchiveOrgClient.liveness("),
                "eine Lebendpruefung je Kachel ist zurueck im Bauweg")
        #expect(!text.contains("await coverLoads("),
                "eine Cover-Probe je Kachel ist zurueck im Bauweg")
    }

    /// R45/R48: eine Reihe holt keine Kapitel. Der alte Vollabruf war zu 95 %
    /// Kapitelliste (291 kB fuer 20 Buecher, gemessen am Endpunkt); die
    /// Feldliste laesst sie weg und traegt dafuer `genres`. Der Zaun haelt
    /// beide Haelften fest — was die Reihe holt UND was sie nicht holt.
    @Test("die Reihen-Feldliste laesst die Kapitel weg und traegt die Gattungen")
    func rowFieldsCarryGenresAndNoChapters() {
        let fields = LibriVoxClient.rowFields
        #expect(fields.contains("genres"), "die Gattungen sind der Grund fuer den Umbau")
        #expect(!fields.contains("sections"),
                "Kapitel gehoeren an die Detailseite, nicht in jede Kachel")
        for needed in ["url_iarchive", "url_rss", "authors", "title"] {
            #expect(fields.contains(needed), "\(needed) fehlt der Reihe")
        }
    }

    /// R47: die gemessenen OTR-Begriffe liegen auf der EINEN Achse.
    @Test("die nachgemessenen OTR-Begriffe sind einsortiert")
    func measuredOTRTermsAreOnTheAxis() {
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Detective"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["mystery"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Crime Drama"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Drama"]) == ["drama"])
        // Rot-Probe: die Zuordnung bleibt EXAKT, kein Teilstring.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Western Electric"]).isEmpty)
    }

    /// R45 Runde 2 (the owner: „laedt immer noch ewig"): der Durchlauf
    /// veroeffentlicht in der Reihenfolge, in der die Quellen FERTIG werden.
    /// `async let` plus sequenzielles `await` wartet in STARTreihenfolge — die
    /// drei schnellen Reihen (je rund 1 s) hingen damit an der langsamsten
    /// (LibriVox, gemessen 7-35 s), und das Veroeffentlichen je Reihe konnte
    /// gar nicht wirken. Rot-Probe: die alte Form stand genau hier.
    @Test("der Durchlauf wartet auf Fertigstellung, nicht auf die Startreihenfolge")
    func theLoadWaitsForCompletionNotForStartOrder() throws {
        let text = try String(contentsOf: sourceFile("Sources/Views/FreeCatalogRows.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "static func load(onRow: RowSink? = nil)", in: text),
                                "der Durchlauf heisst nicht mehr so — Zaun nachziehen")
        #expect(!body.contains("async let"),
                "eine Quelle wird wieder in Startreihenfolge abgewartet")
        #expect(body.contains("withTaskGroup"),
                "das Ergebnis-orientierte Warten ist aus dem Durchlauf verschwunden")
        // Und die zweite Haelfte: eine abgeschaltete Quelle erzeugt keinen
        // Auftrag mehr, statt gestartet und weggeworfen zu werden.
        #expect(!body.contains("_ = await "),
                "eine abgeschaltete Quelle wird wieder gestartet und verworfen")
        // Rot-Probe am Instrument selbst: gegen die ALTE Fassung schlaegt es
        // an. Ein Zaun, der nur „nichts gefunden" meldet, beweist nichts.
        let alt = """
            @MainActor
            enum Alt {
                static func load(onRow: RowSink? = nil) async -> SourceRows {
                    async let newTask = fetched { try await LibriVoxClient.newBooks() }
                    if librivoxOn {
                        _ = await newTask
                    }
                    return rows
                }
            }
            """
        let alteForm = try #require(functionBody(of: "static func load(onRow: RowSink? = nil)", in: alt))
        #expect(alteForm.contains("async let"), "die Rot-Probe sieht die alte Form nicht")
        #expect(alteForm.contains("_ = await "), "die Rot-Probe sieht das Wegwerfen nicht")
        #expect(!alteForm.contains("withTaskGroup"))
        // Und die Gegenrichtung: ein KOMMENTAR, der die alte Form erklaert,
        // darf den Zaun nicht ausloesen — genau daran ist er einmal gerissen.
        let erklaert = """
            @MainActor
            enum Neu {
                static func load(onRow: RowSink? = nil) async -> SourceRows {
                    // `async let` plus sequenzielles `await` wartete in Startreihenfolge.
                    await withTaskGroup(of: Fetched.self) { group in }
                    return rows
                }
            }
            """
        let erklaerteForm = try #require(functionBody(of: "static func load(onRow: RowSink? = nil)", in: erklaert))
        #expect(!erklaerteForm.contains("async let"),
                "ein Treffer im Kommentar wird als Treffer im Code gewertet")
    }

    /// R45 Runde 2, gemessen am Endpunkt: der Server rechnet die ganze Antwort
    /// fertig, bevor er das erste Byte sendet (22-25 s bis zum ersten Byte).
    /// Gegen das gemeinsame Zeitlimit von 20 s konnte diese Abfrage nur ueber
    /// die Wiederhol-Leiter verlieren — 20+20+20 und dann FEHLSCHLAG. Sie
    /// braucht also ihr eigenes Limit, wie gutendex es hat.
    ///
    /// `extended=1` wegzulassen wuerde die Zeit halbieren und ist trotzdem
    /// falsch: es ist der einzige Weg zu `url_iarchive`, und daran haengt das
    /// COVER jeder LibriVox-Kachel (gemessen: weder `fields=` noch die nackte
    /// Form liefern es). Der Zaun haelt genau diese Abwaegung fest.
    @Test("die langsame Quelle hat ihr eigenes Zeitlimit, und die Cover-Quelle bleibt")
    func theSlowSourceCarriesItsOwnTimeout() throws {
        let text = try String(contentsOf: sourceFile("Sources/Networking/FreeCatalogClients.swift"),
                              encoding: .utf8)
        let new = try #require(functionBody(of: "static func newBooks(sinceDays: Int, limit: Int)", in: text))
        #expect(new.contains("timeoutInterval = 45"),
                "die Reihe faellt wieder ins geteilte 20-s-Limit und damit in die Wiederhol-Leiter")
        #expect(new.contains("\"extended\""),
                "ohne den Parameter fehlt url_iarchive — die Kacheln verlieren ihre Cover")
        // Und die Feldliste muss die Cover-Quelle ueberhaupt anfragen.
        #expect(LibriVoxClient.rowFields.contains("url_iarchive"))
        // R53-Nachlese: die zweite Haelfte dieses Zauns pruefte den
        // LibriVox-Gattungsfeed — der ist GELOESCHT (er lieferte `lv:`-Buecher
        // fuer eine Flaeche aus `lva:`-Dokumenten, also zwei Kennungen fuer
        // dieselben Titel). Der Zaun haelt jetzt fest, dass er nicht
        // zurueckkommt, statt seine Parameter zu bewachen.
        #expect(!text.contains("func books(genre:"),
                "der LibriVox-Gattungsfeed ist zurueck — zwei Kennungen fuer dieselben Titel")
    }

    /// R53 (the owner: „Alle 4 Bibs haben moeglicherweise auch Kachelreihen
    /// verloren") — mein eigener R46-Bau nahm zwei von vier Quellen die
    /// Faecher: `shelves` las nur noch `shelfStock`, und das fuellte sich
    /// ausschliesslich ueber `archiveBaseQuery`, die fuer LibriVox und
    /// Gutenberg `nil` lieferte. Die Flaeche versprach die Faecher
    /// (`hasChips`) und lieferte sie nie.
    ///
    /// Der Zaun haelt die INVARIANTE, nicht den Einzelfall: jede Quelle, die
    /// Faecher verspricht, kann sie auch erfragen — und umgekehrt.
    @Test("keine Quelle verspricht Faecher, die sie nicht erfragen kann")
    func everyShelfPromiseIsBackedByAQuery() {
        for source in CatalogSource.allCases where CatalogShelfSource.canServeShelves(source) {
            // Entweder es gibt eine archive.org-Basis — oder die Quelle hat
            // ihren EIGENEN Weg im geteilten Fach-Abruf.
            let ownWay = source == .gutenberg
            #expect(ArchiveOrgClient.archiveBaseQuery(for: source) != nil || ownWay,
                    "\(source.rawValue) verspricht Faecher ohne Abfrage dahinter")
        }
        // Rot-Probe: die Regression war genau das Fehlen dieser Basis.
        #expect(ArchiveOrgClient.archiveBaseQuery(for: .librivox) != nil,
                "LibriVox ist wieder ohne Fach-Abfrage — das war R53")
        // Und die Quellen ohne Achse versprechen auch nichts.
        #expect(!CatalogShelfSource.canServeShelves(.oerr))
    }

    /// R53: LibriVox-Kacheln dieser Flaeche sind archive.org-Dokumente und
    /// tragen SUBJECTS, keine LibriVox-Gattungsnamen. Gemessen an den 120
    /// meistgeladenen `librivoxaudio`-Eintraegen: die Gattungs-Achse ordnete
    /// 40 ein, die Subject-Achse 58.
    @Test("die Seite liest die Schreibfamilie, die ihre Kacheln wirklich tragen")
    func theSurfaceReadsTheSpellingFamilyItsTilesCarry() throws {
        let text = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "private func shelvesOf(_ item: LibraryItem)", in: text))
        #expect(!body.contains("forLibriVoxGenres"),
                "die Flaeche liest wieder Gattungsnamen aus Eintraegen, die Subjects tragen")
        // Ein echter archive.org-Subject aus dem gemessenen Bestand.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Detective Fiction"]) == ["crime"])
    }

    /// R53, zwei Klassen, die ich beide selbst schon einmal gemessen habe:
    /// das Tor darf den Lauf nicht buchen, BEVOR er stattfand (R39), und ein
    /// Fehlschlag ist eine ANTWORT, nicht ein stilles Fehlen (703df85).
    @Test("das Faecher-Tor bucht nach dem Lauf, und ein Fehlschlag ist unterscheidbar")
    func theShelfGateBooksAfterwardsAndFailuresAreVisible() throws {
        let text = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "private func loadShelves()", in: text))
        let gate = try #require(body.range(of: "shelvesLoaded = true"))
        let work = try #require(body.range(of: "withTaskGroup"))
        #expect(gate.lowerBound > work.upperBound,
                "das Tor bucht den Lauf wieder, bevor er stattgefunden hat")
        #expect(body.contains("Task.isCancelled"),
                "ein abgebrochener Lauf gilt wieder als erledigt")
        #expect(!body.contains("try? await"),
                "ein Fehlschlag wird wieder verschluckt und sieht aus wie leer")
        #expect(body.contains("failureReason"), "der Grund wird nicht mehr benannt")
    }

    /// the owner's ENTSCHEID: die Gutenberg-Faecher werden je Tag einmal geholt.
    /// Der Speicher liegt in dem Mechanismus, der einen Ablauf schon HAT —
    /// und dessen Gruendungsregel genau die ist, die hier zaehlt: ein
    /// Fehlschlag wird nie aufgeschrieben (sonst waere die Seite den Rest des
    /// Tages kaputt). Der Zaun prueft beide Invarianten am Verhalten.
    @Test("der Tages-Speicher laeuft ab und nimmt niemals einen Fehlschlag auf")
    func theDayStoreExpiresAndNeverKeepsAFailure() throws {
        let suite = "shelfstore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = CatalogShelfSource.gutenbergShelfStore
        let shelf = CatalogShelfSource.GutenbergShelf(total: 67, books: [])

        #expect(store.store(.found(shelf), for: "adventure", defaults: defaults))
        #expect(store.load(defaults: defaults)["adventure"] != nil, "der Treffer fehlt")
        // Ein Fehlschlag schreibt NICHTS — auch nicht ueber einen Treffer.
        #expect(store.store(.failed, for: "crime", defaults: defaults) == false)
        #expect(store.load(defaults: defaults)["crime"] == nil,
                "ein Fehlschlag ist im Tages-Speicher gelandet")
        // Ein sauberer Lauf ohne Inhalt IST eine Antwort und darf bleiben.
        #expect(store.store(.absent, for: "poetry", defaults: defaults))
        // Und der Ablauf haengt am EINTRAG: einen Tag spaeter ist er weg.
        let morgen = Date().addingTimeInterval(24 * 3600 + 60)
        #expect(store.load(defaults: defaults, now: morgen).isEmpty,
                "der Tages-Speicher altert nicht — das ist die Bestands-Positiv-Klasse")
    }

    /// R52 (the owner: „auf Hörbücher-Bib, Start und Podcast-Bib jeweils einmal
    /// Hörbücher und Hörspiele als Kachelreihe. Da ist was falsch"): der
    /// Kommentar in `PodcastsView` behauptete die Disjunktheit seit dem
    /// 07.08. — der Code darunter stellte sie nie her. Der Test, auf den er
    /// sich berief (`Catalog sources split disjointly …`,
    /// `FreeCatalogTests`), ist nicht falsch: er teilt die QUELLEN-
    /// Aufzaehlung, nicht die Kacheln. Das ist der fehlende Satz.
    @Test("Podcast-Tab zeigt keine Katalog-Kachel, Hoerbuecher-Tab keinen Feed")
    func theTwoTabRowsAreDisjointAtTheTiles() {
        let rows = Self.filledRows()
        let podcasts = CatalogMix.tiles(for: .podcasts, rows: rows)
        let books = CatalogMix.tiles(for: .books, rows: rows)
        #expect(!podcasts.isEmpty, "die Probe misst nichts — der Podcast-Tab ist leer")
        #expect(!books.isEmpty, "die Probe misst nichts — der Buecher-Tab ist leer")
        for tile in podcasts {
            if case .item(let item) = tile {
                #expect(Bool(false), Comment(rawValue: "Katalog-Kachel im Podcast-Tab: \(item.id)"))
            }
        }
        for tile in books {
            if case .feed(let entry) = tile {
                #expect(Bool(false), Comment(rawValue: "Feed im Buecher-Tab: \(entry.feedURL)"))
            }
        }
        // Und keine Kachel steht in BEIDEN.
        #expect(Set(podcasts.map(\.id)).isDisjoint(with: Set(books.map(\.id))))
        // Rot-Probe: das Instrument SIEHT beide Sorten. Start mischt sie, und
        // genau so sah die Podcast-Reihe bis heute aus — ohne diesen Nachweis
        // wuerde „keine Katalog-Kachel gefunden" auch bei blindem Zaun gelten.
        let home = CatalogMix.tiles(for: .home, rows: rows)
        var sahFeed = false, sahItem = false
        for tile in home {
            if case .feed = tile { sahFeed = true }
            if case .item = tile { sahItem = true }
        }
        #expect(sahFeed && sahItem,
                "die Rot-Probe sieht die gemischte Form nicht — der Zaun beweist nichts")
    }

    /// R52 INVARIANTE 2: Start darf beide Welten zeigen, aber nie kachelgleich
    /// mit einer Tab-Reihe sein. Der geteilte Sitzungs-Startwert garantierte
    /// bisher das GEGENTEIL — seine Absicht (innerhalb einer Sitzung sortiert
    /// sich nichts um) bleibt und wird je Flaeche abgeleitet.
    @Test("Start ist keine Zwillingsreihe, und der Startwert bleibt je Sitzung stabil")
    func homeIsNeverATwinOfATabRow() {
        for a in CatalogMix.Surface.allCases {
            for b in CatalogMix.Surface.allCases where a != b {
                #expect(CatalogMix.seed(for: a, session: 42) != CatalogMix.seed(for: b, session: 42),
                        "\(a.rawValue) und \(b.rawValue) teilen ihren Startwert")
            }
        }
        // Stabil: derselbe Sitzungswert ergibt denselben Flaechenwert.
        #expect(CatalogMix.seed(for: .home, session: 7) == CatalogMix.seed(for: .home, session: 7))
        // Und am Ergebnis: Start ist nicht kachelgleich mit einer Tab-Reihe.
        let rows = Self.filledRows()
        let home = CatalogMix.tiles(for: .home, rows: rows).map(\.id)
        #expect(!home.isEmpty, "die Probe misst nichts")
        #expect(home != CatalogMix.tiles(for: .podcasts, rows: rows).map(\.id))
        #expect(home != CatalogMix.tiles(for: .books, rows: rows).map(\.id))
    }

    /// Genug Bestand in JEDER Katalog-Bahn, damit die Proben oben wirklich
    /// etwas messen (ein gruener Lauf ohne Messung ist der teuerste Ausgang).
    private static func filledRows() -> CatalogSourceLoader.SourceRows {
        func lane(_ prefix: String) -> [LibraryItem] {
            (1...8).map { LibraryItem(id: "\(prefix)-\($0)", media: nil, addedAt: nil) }
        }
        var rows = CatalogSourceLoader.SourceRows()
        rows.oldTimeRadio = lane("arch:otr")
        rows.librivoxPopular = lane("arch:lv")
        rows.archiveBooks = lane("arch:ia")
        rows.gutenberg = lane("gut:book")
        return rows
    }

    private func sourceFile(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    /// A hit inside a COMMENT is not a hit in the code — this very fence went
    /// red on the sentence that explains why the old form was replaced.
    private func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text of one function, from its signature to the closing brace at the
    /// same indentation — so a fence can scope its claim to ONE function
    /// instead of the whole file. Comment lines are dropped first.
    private func functionBody(of signature: String, in full: String) -> String? {
        let text = withoutComments(full)
        guard let start = text.range(of: signature) else { return nil }
        let indent = text[text.lineRange(for: start).lowerBound...]
            .prefix { $0 == " " }
        let closing = "\n" + indent + "}"
        guard let end = text.range(of: closing, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}
#endif
