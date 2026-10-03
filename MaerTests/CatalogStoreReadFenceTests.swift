// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The class "a surface reads the catalog store without anything
/// starting its load" came back. The 10.08. fence was gone from the tree,
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
        for file in try sources() where file.name != "FreeCatalogStore.swift" {
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

    /// A catalog row may exist ONCE per surface. The duplicate arose
    /// because a repair was made at the REPORTED spot without sweeping the
    /// same file for a sibling row of the same source. And the two then
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

    /// A FAILED row is an ANSWER. When only Jamendo could be answered, a
    /// failing LibriVox left the pass permanently incomplete. And the reopen
    /// turned that into three full network passes, i.e. a spinner that never
    /// stops. Cancellations still leave the pass incomplete (retryable).
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
    /// Ein Fach mit 102 Eintraegen zeigte EINE Kachel und nie ein Chevron,
    /// also keinen Weg in die Genre-Bibliothek. Die Chevron-Regel
    /// (`total > shown`) war richtig. Sie
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
        // Mit dem Vorrat statt dem Bestand waere 2 > 2 falsch. Kein Chevron,
        // genau der gemeldete Zustand. Mit dem Bestand ist 102 > 2 wahr.
        #expect(102 > 2)
        // Eine Antwort ohne die Zahl erfindet keine: dann traegt die Reihe
        // die Existenz-Form des Chevrons, nie eine geratene Menge.
        let ohne = Data("{\"response\":{\"docs\":[]}}".utf8)
        #expect(try ArchiveOrgClient.decodeTotal(ohne) == nil)
    }

    /// The build path must not probe. The old chain asked archive.org twice
    /// PER TILE. 72 serial round trips and 4,5 MB of metadata just to learn
    /// whether a tile has a picture, measured at 43 s per
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
        // verschwunden. Kehrt einer zurueck, faellt es hier auf.
        // The build path is the two loaders; both are read.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try ["Sources/ViewModels/FreeCatalogLoader.swift", "Sources/ViewModels/CatalogSourceLoader.swift"]
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        #expect(text.contains("static func picks("), "der Zeuge liest den Bauweg nicht mehr")
        #expect(!text.contains("await ArchiveOrgClient.liveness("),
                "eine Lebendpruefung je Kachel ist zurueck im Bauweg")
        #expect(!text.contains("await coverLoads("),
                "eine Cover-Probe je Kachel ist zurueck im Bauweg")
    }

    /// Eine Reihe holt keine Kapitel. Der alte Vollabruf war zu 95 %
    /// Kapitelliste (291 kB fuer 20 Buecher, gemessen am Endpunkt); die
    /// Feldliste laesst sie weg und traegt dafuer `genres`. Der Zaun haelt
    /// beide Haelften fest. Was die Reihe holt UND was sie nicht holt.
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

    /// Die gemessenen OTR-Begriffe liegen auf der EINEN Achse.
    @Test("die nachgemessenen OTR-Begriffe sind einsortiert")
    func measuredOTRTermsAreOnTheAxis() {
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Detective"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["mystery"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Crime Drama"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Drama"]) == ["drama"])
        // Rot-Probe: die Zuordnung bleibt EXAKT, kein Teilstring.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Western Electric"]).isEmpty)
    }

    /// Der Durchlauf veroeffentlicht in der Reihenfolge, in der die Quellen
    /// FERTIG werden.
    /// `async let` plus sequenzielles `await` wartet in STARTreihenfolge. Die
    /// drei schnellen Reihen (je rund 1 s) hingen damit an der langsamsten
    /// (LibriVox, gemessen 7-35 s), und das Veroeffentlichen je Reihe konnte
    /// gar nicht wirken. Rot-Probe: die alte Form stand genau hier.
    @Test("der Durchlauf wartet auf Fertigstellung, nicht auf die Startreihenfolge")
    func theLoadWaitsForCompletionNotForStartOrder() throws {
        let text = try String(contentsOf: sourceFile("Sources/ViewModels/CatalogSourceLoader.swift"),
                              encoding: .utf8)
        // The signature continues with the clients and gates a witness hands
        // in; the anchor is the part that names this pass.
        let body = try #require(functionBody(of: "static func load(onRow: RowSink? = nil", in: text),
                                "der Durchlauf heisst nicht mehr so — Zaun nachziehen")
        #expect(!body.contains("async let"),
                "eine Quelle wird wieder in Startreihenfolge abgewartet")
        #expect(body.contains("withTaskGroup"),
                "das Ergebnis-orientierte Warten ist aus dem Durchlauf verschwunden")
        // Und die zweite Haelfte: eine abgeschaltete Quelle erzeugt keinen
        // Abruf mehr, statt gestartet und weggeworfen zu werden.
        #expect(!body.contains("_ = await "),
                "eine abgeschaltete Quelle wird wieder gestartet und verworfen")
        // Rot-Probe am Instrument selbst: gegen die ALTE Fassung schlaegt es
        // an. Ein Zaun, der nur nichts findet, beweist nichts.
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
        // darf den Zaun nicht ausloesen. Genau daran ist er einmal gerissen.
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

    /// Am Endpunkt gemessen: der Server rechnet die ganze Antwort
    /// fertig, bevor er das erste Byte sendet (22-25 s bis zum ersten Byte).
    /// Gegen das gemeinsame Zeitlimit von 20 s konnte diese Abfrage nur ueber
    /// die Wiederhol-Leiter verlieren. 20+20+20 und dann FEHLSCHLAG. Sie
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
        // Die zweite Haelfte dieses Zauns pruefte den
        // LibriVox-Gattungsfeed. Der ist GELOESCHT (er lieferte `lv:`-Buecher
        // fuer eine Flaeche aus `lva:`-Dokumenten, also zwei Kennungen fuer
        // dieselben Titel). Der Zaun haelt jetzt fest, dass er nicht
        // zurueckkommt, statt seine Parameter zu bewachen.
        #expect(!text.contains("func books(genre:"),
                "der LibriVox-Gattungsfeed ist zurueck — zwei Kennungen fuer dieselben Titel")
    }

    /// Zwei von vier Quellen hatten ihre Kachelreihen verloren: `shelves` las
    /// nur noch `shelfStock`, und das fuellte sich
    /// ausschliesslich ueber `archiveBaseQuery`, die fuer LibriVox und
    /// Gutenberg `nil` lieferte. Die Flaeche versprach die Faecher
    /// (`hasChips`) und lieferte sie nie.
    ///
    /// Der Zaun haelt die INVARIANTE, nicht den Einzelfall: jede Quelle, die
    /// Faecher verspricht, kann sie auch erfragen. Und umgekehrt.
    @Test("keine Quelle verspricht Faecher, die sie nicht erfragen kann")
    func everyShelfPromiseIsBackedByAQuery() {
        for source in CatalogSource.allCases where CatalogShelfSource.canServeShelves(source) {
            // Entweder es gibt eine archive.org-Basis. Oder die Quelle hat
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

    /// Zwei Klassen in einem Zaun: das Tor darf den Lauf nicht buchen,
    /// BEVOR er stattfand, und ein
    /// Fehlschlag ist eine ANTWORT, nicht ein stilles Fehlen.
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

    /// Die Faecher werden je Tag einmal geholt, fuer JEDE Quelle.
    /// Der Speicher liegt in dem Mechanismus, der einen Ablauf schon HAT.
    /// Und dessen Gruendungsregel genau die ist, die hier zaehlt: ein
    /// Fehlschlag wird nie aufgeschrieben (sonst waere die Seite den Rest des
    /// Tages kaputt). Der Zaun prueft beide Invarianten am Verhalten.
    @Test("der Tages-Speicher laeuft am Tageswechsel ab und nimmt nie einen Fehlschlag auf")
    func theDayStoreExpiresAndNeverKeepsAFailure() throws {
        let suite = "shelfstore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = CatalogShelfSource.shelfStore
        let shelf = CatalogShelfSource.ShelfStock(total: 67, books: [], docs: nil)
        let heute = Date(timeIntervalSince1970: 1_756_000_000)

        #expect(store.store(.found(shelf), for: "adventure", defaults: defaults, now: heute))
        #expect(store.load(defaults: defaults, now: heute)["adventure"] != nil, "der Treffer fehlt")
        // Ein Fehlschlag schreibt NICHTS. Auch nicht ueber einen Treffer.
        #expect(store.store(.failed, for: "crime", defaults: defaults, now: heute) == false)
        #expect(store.load(defaults: defaults, now: heute)["crime"] == nil,
                "ein Fehlschlag ist im Tages-Speicher gelandet")
        // Ein sauberer Lauf ohne Inhalt IST eine Antwort und darf bleiben.
        #expect(store.store(.absent, for: "poetry", defaults: defaults, now: heute))
        // Der Ablauf haengt am TAGESWECHSEL, derselbe wie bei der Rotation.
        // Eine rollende Frist waere eine zweite Uhr: ein Eintrag von 23:50
        // antwortete am naechsten Abend noch mit der Seite von gestern.
        let morgen = heute.addingTimeInterval(24 * 3600)
        #expect(CatalogRotation.dayIndex(on: morgen) == CatalogRotation.dayIndex(on: heute) + 1)
        #expect(store.load(defaults: defaults, now: morgen).isEmpty,
                "der Tages-Speicher ueberlebt den Tageswechsel")
        // Rot-Probe am Instrument: derselbe Eintrag, wenige Minuten spaeter,
        // steht selbstverstaendlich noch. Sonst pruefte der Fall nur, dass
        // `load` ueberhaupt etwas verwirft.
        #expect(store.load(defaults: defaults, now: heute.addingTimeInterval(600))["adventure"] != nil)
    }

    /// JEDER Weg, der Faecher holt, geht durch die eine Tuer. Der Auftrag
    /// nennt Netlabels und Schellack ausdruecklich; die Jahrzehnte und die
    /// Beliebt-Reihen der Schellack-Flaechen liefen an ihr vorbei, weil sie
    /// eigene Ladewege sind. Ohne diesen Zaun faellt der naechste neue
    /// Ladeweg genauso durch, und niemand sieht es.
    @Test("jeder Faecher-Ladeweg geht durch die eine Tuer, nicht am Speicher vorbei")
    func everyShelfPathGoesThroughTheOneDoor() throws {
        let seite = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                              encoding: .utf8)
        let dekaden = try #require(functionBody(of: "private func loadDecades() async {", in: seite))
        #expect(dekaden.contains("decadePreview("),
                "die Jahrzehnte fragen wieder ohne Speicher")
        #expect(!dekaden.contains("CatalogShelfSource.decadePage("),
                "die Jahrzehnte gehen an der Tuer vorbei")

        let musik = try String(contentsOf: sourceFile("Sources/Views/Music/ArchiveMusicPages.swift"),
                               encoding: .utf8)
        #expect(musik.contains("CatalogShelfSource.musicPage("),
                "die Musik-Faecher bauen ihre Abfrage wieder selbst")
        #expect(musik.contains("CatalogShelfSource.areaPopular("),
                "die Beliebt-Reihen der Schellack-Flaechen laufen wieder ohne Speicher")
        #expect(!musik.contains("ArchiveOrgClient.popularMusic(area: shelf"),
                "die Schellack-Schleife fragt den Client wieder direkt")
    }

    /// Der WARME Besuch darf keinen Platzhalter aufblitzen lassen. Liegt der
    /// Tag im Speicher, kommen die Kacheln sofort; ein Skelett, das dann
    /// kurz aufleuchtet, IST der Layout-Shift, gegen den es gebaut wurde.
    /// Die Bedingung dafuer ist, dass der Platzhalter am leeren
    /// Tages-Speicher haengt, nicht nur an der Wartezeit.
    @Test("ein gespeicherter Tag verhindert den Platzhalter, statt ihn aufblitzen zu lassen")
    func aStoredDayPreventsThePlaceholder() throws {
        let suite = "warmday-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Kalt: der Speicher weiss von keinem Fach.
        #expect(CatalogShelfSource.knownShelfKeys(for: .librivox, defaults: defaults).isEmpty)

        // Warm: genau die Faecher, die im Tag stehen, und nur die.
        let id = CatalogShelfSource.stockId(surface: CatalogSource.librivox.rawValue,
                                            shelf: "crime")
        CatalogShelfSource.shelfStore.store(
            .found(CatalogShelfSource.ShelfStock(
                total: 3, books: nil,
                docs: [ArchivePopularDoc(identifier: "a", title: nil, creator: nil,
                                         downloads: nil, runtime: nil, licenseurl: nil,
                                         year: nil, subject: nil)])),
            for: id, rule: CatalogShelfSource.shelfRule(forId: id), defaults: defaults)
        #expect(CatalogShelfSource.knownShelfKeys(for: .librivox, defaults: defaults) == ["crime"])
        // Und der Tag der einen Quelle beantwortet nicht die andere.
        #expect(CatalogShelfSource.knownShelfKeys(for: .oldTimeRadio, defaults: defaults).isEmpty)

        // Die Flaeche haengt den Platzhalter an genau diese Antwort. Ohne
        // diese Klausel zeigte der warme Besuch erst ein Skelett und danach
        // die Kacheln, die schon dalagen.
        let seite = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                               encoding: .utf8)
        let body = try #require(functionBody(of: "private var showsShelfPlaceholder: Bool {",
                                             in: seite))
        #expect(body.contains("knownShelfKeys.isEmpty"),
                "der Platzhalter blitzt beim warmen Besuch auf")

        // Dieselbe Klausel auf den beiden Musik-Flaechen. Sie lesen den Tag
        // ueber den Bereichs-Schluessel, also steht dort `storedDay`.
        let musik = try String(contentsOf: sourceFile("Sources/Views/Music/ArchiveMusicPages.swift"),
                               encoding: .utf8)
        let kopf = "private var showsShelfPlaceholder: Bool {"
        var rest = Substring(musik)
        var gefunden = 0
        while let treffer = rest.range(of: kopf) {
            // Leerraum zusammenziehen, bevor gesucht wird: ein Aufruf, der
            // ueber zwei Zeilen laeuft, ist derselbe Aufruf. Sonst pruefte
            // der Zaun die Zeilenlaenge statt der Aussage, und genau daran
            // ist er beim ersten Lauf gerissen.
            let rumpf = try #require(functionBody(of: kopf, in: String(rest)))
                .split(whereSeparator: \.isWhitespace).joined()
            #expect(rumpf.contains("storedDay(surface:"),
                    "eine Musik-Flaeche blitzt beim warmen Besuch auf")
            #expect(rumpf.contains("showsLoadingPlaceholder(surface:"),
                    "eine Musik-Flaeche entscheidet ohne die geteilte Regel")
            gefunden += 1
            rest = rest[treffer.upperBound...]
        }
        #expect(gefunden == 2, "beide Musik-Flaechen tragen die Klausel nicht")
    }

    /// Und die Tuer LIEST den Speicher auch. Ein Zaun am Quelltext allein
    /// zeigte nur, dass der Aufruf dasteht.
    @Test("ein niedergeschriebener Tag beantwortet die Abfrage, ohne zu fragen")
    func aStoredDayAnswersWithoutAsking() async throws {
        let stock = CatalogShelfSource.ShelfStock(
            total: 7, books: nil,
            docs: [ArchivePopularDoc(identifier: "gunsmoke", title: nil, creator: nil,
                                     downloads: nil, runtime: nil, licenseurl: nil,
                                     year: nil, subject: nil)])
        // Jahrzehnt: der gespeicherte Tag traegt die Antwort.
        let jahrzehnt = try await CatalogShelfSource.decadePreview(
            source: .oldTimeRadio, decade: "1950s", rows: 12, storedDay: ["1950s": stock])
        guard case .archive(let docs, let total) = jahrzehnt else {
            Issue.record("das Jahrzehnt antwortet nicht mit Archive-Kacheln"); return
        }
        #expect(docs.first?.identifier == "gunsmoke")
        #expect(total == 7)

        // Beliebt-Reihe einer Flaeche: dieselbe Antwort aus demselben Tag.
        let beliebt = try await CatalogShelfSource.areaPopular(
            area: ArchiveMusicCatalog.shellacShelves[0], rows: 12, page: 1,
            storedDay: [CatalogShelfSource.popularShelf: stock])
        #expect(beliebt.first?.identifier == "gunsmoke")
    }

    /// Der Speicher schreibt jetzt Archive-Dokumente nieder, also muss der
    /// Eintrag seinen eigenen Leseweg ueberleben. Geprueft wird gegen die
    /// SERVER-Form: `creator` als blanke Zeichenkette, `year` als ZAHL, wie
    /// archive.org es liefert. Ein Rundlauf allein bewiese nur, dass mein
    /// Schreiber zu meinem Leser passt.
    @Test("ein niedergeschriebenes Archive-Dokument ueberlebt seinen eigenen Leseweg")
    func aStoredArchiveDocSurvivesItsOwnReading() throws {
        let serverForm = Data("""
        {"identifier":"gunsmoke","title":"Gunsmoke","creator":"CBS","downloads":42,
         "runtime":"0:29:12","licenseurl":"http://creativecommons.org/licenses/by/4.0/",
         "year":1955,"subject":["western","radio"],"collection":"oldtimeradio"}
        """.utf8)
        let vomServer = try JSONDecoder().decode(ArchivePopularDoc.self, from: serverForm)
        #expect(vomServer.year?.values == ["1955"], "die Zahl-Form kommt nicht mehr an")

        let wieder = try JSONDecoder().decode(
            ArchivePopularDoc.self, from: try JSONEncoder().encode(vomServer))
        #expect(wieder.identifier == "gunsmoke")
        #expect(wieder.title?.values == ["Gunsmoke"])
        #expect(wieder.creator?.values == ["CBS"])
        #expect(wieder.year?.values == ["1955"], "das Jahr faellt beim Niederschreiben heraus")
        #expect(wieder.subject?.values == ["western", "radio"])
        #expect(wieder.collection?.values == ["oldtimeradio"], "die Sammlung entscheidet die FORM")
        #expect(wieder.runtime == vomServer.runtime)
        #expect(wieder.licenseurl == vomServer.licenseurl, "die Rechtelage faellt heraus")
        #expect(wieder.downloads == vomServer.downloads)
    }

    /// Ein Eintrag wird unter Quelle UND Fach abgelegt. Ohne die Quelle im
    /// Schluessel wuerden sechs Flaechen dieselben Fach-Namen auf denselben
    /// Platz schreiben, und LibriVox bekaeme die Kacheln von Old Time Radio.
    @Test("der Schluessel traegt die Quelle, nicht nur das Fach")
    func theStoreKeyCarriesTheSurface() throws {
        let suite = "shelfstore-surface-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = CatalogShelfSource.shelfStore
        let heute = Date(timeIntervalSince1970: 1_756_000_000)

        let lv = CatalogShelfSource.stockId(surface: CatalogSource.librivox.rawValue, shelf: "crime")
        let otr = CatalogShelfSource.stockId(surface: CatalogSource.oldTimeRadio.rawValue, shelf: "crime")
        #expect(lv != otr, "zwei Quellen teilen sich einen Platz")
        store.store(.found(CatalogShelfSource.ShelfStock(total: 1, books: nil, docs: [])),
                    for: lv, defaults: defaults, now: heute)
        #expect(store.load(defaults: defaults, now: heute)[lv] != nil)
        #expect(store.load(defaults: defaults, now: heute)[otr] == nil,
                "der Eintrag der einen Quelle beantwortet die andere")

        // Und die Regel je Eintrag unterscheidet die Quellen ebenfalls: sie
        // traegt die Abfrage, nicht nur die Begriffe. Sonst haette der
        // Wechsel der Eltern-Abfrage einer Flaeche den Speicher der anderen
        // gueltig gelassen.
        #expect(CatalogShelfSource.shelfRule(forId: lv)
                != CatalogShelfSource.shelfRule(forId: otr))
    }

    /// Hoerbuecher-Bibliothek, Start und Podcast-Bibliothek zeigten dieselbe
    /// Kachelreihe. Der Kommentar in `PodcastsView` behauptete die
    /// Disjunktheit, der Code darunter stellte sie nie her. Der Test, auf den
    /// er sich berief (`Catalog sources split disjointly …`,
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
        // genau so sah die Podcast-Reihe bis heute aus. Ohne diesen Nachweis
        // waere ein blinder Zaun von einem leeren Ergebnis nicht zu trennen.
        let home = CatalogMix.tiles(for: .home, rows: rows)
        var sahFeed = false, sahItem = false
        for tile in home {
            if case .feed = tile { sahFeed = true }
            if case .item = tile { sahItem = true }
        }
        #expect(sahFeed && sahItem,
                "die Rot-Probe sieht die gemischte Form nicht — der Zaun beweist nichts")
    }

    /// Start darf beide Welten zeigen, aber nie kachelgleich
    /// mit einer Tab-Reihe sein. Der geteilte Sitzungs-Startwert garantierte
    /// bisher das GEGENTEIL. Seine Absicht (innerhalb einer Sitzung sortiert
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

    /// Ein Fach mit 2829 Eintraegen zeigte ZWEI Kacheln. Die Ursache war kein
    /// duenner Bestand, sondern ein Trennfilter auf seiner EIGENEN Quelle:
    /// `isNotLibriVoxDuplicate` verwirft jedes Dokument, das den Namen
    /// LibriVox enthaelt. Auf der LibriVox-Seite also fast alles.
    /// Am lebenden Endpunkt mit der Abfrage der Flaeche gemessen: **12 von 12
    /// verworfen** (LibriVox), **0 von 12** bei Archive-Hoerbuechern und OTR,
    /// **0 von 50** im breiten Abzug der Archive-Hoerbuecher.
    ///
    /// INVARIANTE: ein Filter, der zwei Quellen voneinander trennt, laeuft
    /// nie auf der Quelle, die er definiert.
    @Test("der Trennfilter laeuft nie auf der Quelle, die er definiert")
    func theSeparationNeverRunsOnItsOwnSource() {
        #expect(!FreeCatalog.separatesFromLibriVox(.librivox),
                "die LibriVox-Seite filtert wieder gegen sich selbst")
        for other in [CatalogSource.archiveBooks, .oldTimeRadio, .gutenberg] {
            #expect(FreeCatalog.separatesFromLibriVox(other),
                    "\(other.rawValue) trennt nicht mehr von LibriVox")
        }
        // Am VERHALTEN, nicht nur an der Regel. Ein echter Titel aus der
        // gemessenen Verworfen-Liste.
        let doc = ArchivePodDoc.librivoxAnniversary
        #expect(!FreeCatalog.isCuratedArchiveDoc(doc, separatingFromLibriVox: true),
                "die Rot-Probe sieht den Filter nicht — er wirft nichts weg")
        #expect(FreeCatalog.isCuratedArchiveDoc(doc, separatingFromLibriVox: false),
                "der Titel faellt weiterhin auf seiner eigenen Quelle")
        // Die Sperrliste gilt UNABHAENGIG davon weiter, auf beiden Wegen.
        let gesperrt = ArchivePodDoc.denied
        #expect(!FreeCatalog.isCuratedArchiveDoc(gesperrt, separatingFromLibriVox: false),
                "die Sperrliste ist mit der Trennung mitgefallen")
    }

    /// Der Platzhalter gegen den Layout-Shift haengt an der GEMESSENEN
    /// Wartezeit, nicht am Quellennamen. Sonst steht in einem Monat ein
    /// `== .gutenberg` da, dessen Grund niemand mehr kennt.
    ///
    /// Die GROESSE hat gewechselt, nicht die Toleranz: gemessen wird der
    /// DURCHGANG, auf den die Flaeche wartet, nicht die einzelne Abfrage.
    /// An der Einzelabfrage sahen die Archive-Quellen schnell aus (1,2 s)
    /// und bekamen keinen Platzhalter, waehrend ihr kalter Durchgang acht
    /// Sekunden lang Luecken stehen liess, ohne etwas zu sagen. Gemessen:
    /// archive.org 8,4-17,8 s je Durchgang, gutendex 454 s kalt / 41 s warm.
    @Test("der Platzhalter haengt an der Wartezeit des DURCHGANGS, nicht am Quellennamen")
    func thePlaceholderHangsOnTheMeasuredWait() throws {
        // Jede Quelle, die Faecher bedient, wartet laenger als die Schwelle
        // und sagt es deshalb.
        for langsam in [CatalogSource.gutenberg, .librivox, .archiveBooks, .oldTimeRadio] {
            #expect(CatalogShelfSource.showsLoadingPlaceholder(langsam),
                    "\(langsam.rawValue) laesst den kalten Durchgang stumm stehen")
        }
        // Rot-Probe am Instrument: eine Quelle ohne Faecher wartet nicht und
        // bekommt auch nichts. Ohne sie meldete eine Regel, die IMMER wahr
        // ist, genauso gruen.
        for ohne in CatalogSource.allCases where !CatalogShelfSource.canServeShelves(ohne) {
            #expect(!CatalogShelfSource.showsLoadingPlaceholder(ohne),
                    "\(ohne.rawValue) zeigt ein Skelett fuer eine Wartezeit, die es nicht gibt")
        }
        // Die Entscheidung MUSS aus der Zahl folgen. Sonst ist es doch ein
        // Sonderfall mit anderem Namen.
        for source in CatalogSource.allCases {
            #expect(CatalogShelfSource.showsLoadingPlaceholder(source)
                    == (CatalogShelfSource.coldPassSeconds(source) >= CatalogShelfSource.visibleWaitSeconds))
        }
        // Die MUSIK-Flaechen laufen ueber Bereichs-Schluessel und fielen
        // durch eine Pruefung, die nur `CatalogSource.allCases` kennt. Sie
        // warten am selben Endpunkt und sagen es deshalb auch.
        for flaeche in [ArchiveMusicCatalog.netlabels, ArchiveMusicCatalog.shellacAll] {
            #expect(CatalogShelfSource.showsLoadingPlaceholder(surface: flaeche.key),
                    "\(flaeche.key) laesst den kalten Durchgang stumm stehen")
            #expect(CatalogShelfSource.showsLoadingPlaceholder(surface: flaeche.key)
                    == (CatalogShelfSource.coldPassSeconds(surface: flaeche.key)
                        >= CatalogShelfSource.visibleWaitSeconds),
                    "die Musik-Flaeche entscheidet an einer zweiten Regel")
        }
        // Rot-Probe: ein Name, den es als Flaeche nicht gibt, wartet auf
        // nichts. Ohne sie meldete eine Regel, die JEDER Zeichenkette einen
        // Platzhalter gibt, genauso gruen.
        #expect(!CatalogShelfSource.showsLoadingPlaceholder(surface: "gibt-es-nicht"))

        // Und die Groesse ist die des Durchgangs: an der Einzelabfrage
        // gemessen faellt die Entscheidung fuer die Archive-Quellen anders
        // aus. Ohne diesen Satz koennte jemand die Zahl zurueckdrehen, ohne
        // dass ein Fall es merkt.
        #expect(CatalogShelfSource.coldShelfSeconds(.librivox)
                < CatalogShelfSource.visibleWaitSeconds,
                "die Einzelabfrage ist nicht mehr die kleinere Zahl — die Probe traegt nicht")
        #expect(CatalogShelfSource.coldPassSeconds(.librivox)
                > CatalogShelfSource.coldShelfSeconds(.librivox),
                "ein Durchgang kostet nicht mehr als seine Einzelabfrage")
        // Rot-Probe am Quelltext: kein Sonderfall auf den Namen in der Regel.
        let text = try String(contentsOf: sourceFile("Sources/Networking/FreeCatalogClients.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "static func showsLoadingPlaceholder(_ source: CatalogSource)", in: text))
        #expect(!body.contains("== .gutenberg"),
                "die Ausnahme ist zur Regel geworden — Schwelle statt Sonderfall")
    }

    /// Der Titel laeuft, der Mini-Player bleibt bei der Startformulierung.
    /// Die Zeile beobachtet die Zeit sehr wohl. Erfunden war das KAPITEL:
    /// fuer ein Stueck ohne Kapitel legte `withTimeMarks`
    /// EINE Marke an, benannt nach Sekunde null und ueber das ganze Stueck.
    /// Damit stand die Startformulierung fest, waehrend die Wiedergabe lief.
    /// Ohne Kapitel faellt der Untertitel auf die laufende Uhr zurueck.
    @Test("ein Stueck ohne Kapitel bekommt keine erfundene Marke")
    func aPieceWithoutChaptersGetsNoInventedMark() {
        // Ein Katalog-Titel: keine Kapitel, drei Minuten.
        #expect(ChapterModel.withTimeMarks([], duration: 222).isEmpty,
                "die Startformulierung ist zurueck — eine Marke ueber das ganze Stueck")
        #expect(ChapterModel.resolved(chapters: [], tracks: [], duration: 222).chapters.isEmpty)
        // Rot-Probe: ein LANGES Stueck ohne Kapitel bekommt weiterhin
        // Sprungmarken. Das Instrument sieht den Unterschied.
        let lang = ChapterModel.withTimeMarks([], duration: 4 * ChapterModel.step)
        #expect(lang.count > 1, "die Sprungmarken sind fuer lange Stuecke mitgestorben")
        // Und der eigentliche Zweck bleibt: eine TEILweise Kapitelliste wird
        // weiterhin bis zum Ende aufgefuellt.
        let teil = [ABSChapter(id: 0, start: 0, end: 600, title: "Eins")]
        #expect(ChapterModel.withTimeMarks(teil, duration: 3600).count > teil.count,
                "der eigentliche Zweck der Marken ist mitgefallen")
    }

    /// Musik-Achse (kleine Toepfe in grosse falten,
    /// Deckel ~30 Faecher). Und die INVARIANTE: die Achse ist mit JAMENDO
    /// GETEILT, also muss die Deckung BEIDER Quellen gemessen sein.
    ///
    /// Gemessen vor dem Bau (1.000 Netlabel-Titel, 200 Jamendo-Titel):
    /// Netlabels 36,0 % → **70,4 %**, Jamendo 81,0 % → **96,5 %**. Beide
    /// steigen; die Faltung nimmt Jamendo nichts weg.
    @Test("die gefaltete Musik-Achse traegt beide Quellen")
    func theFoldedMusicAxisCarriesBothSources() {
        #expect(CatalogGenreAxis.musicShelves.count <= 30,
                "der Deckel von rund 30 Faechern ist gerissen")
        // Die Schreibfamilien beider Quellen treffen dasselbe Fach.
        #expect(CatalogGenreAxis.musicShelf(forTag: "trip-hop") == "electronic")
        #expect(CatalogGenreAxis.musicShelf(forTag: "triphop") == "electronic")
        #expect(CatalogGenreAxis.musicShelf(forTag: "Trip Hop") == "electronic")
        // Der Begriff, der ganz fehlte und der zweithaeufigste der Sammlung ist.
        #expect(CatalogGenreAxis.musicShelf(forTag: "jazz") == "jazz")
        #expect(CatalogGenreAxis.musicShelf(forTag: "experimental") == "experimental")
        // Jamendos meistgenutzte Tags bleiben zugeordnet. Die Faltung darf
        // ihm nichts nehmen (die Invariante, an Beispielen festgehalten).
        for tag in ["pop", "electropop", "singersongwriter", "indiepop", "rnb", "filmscore"] {
            #expect(CatalogGenreAxis.musicShelf(forTag: tag) != nil,
                    "Jamendo-Tag \(tag) faellt aus der Achse")
        }
        // Unbekanntes bleibt unbekannt. Nie geraten.
        #expect(CatalogGenreAxis.musicShelf(forTag: "Voellig Unbekannt") == nil)
        // Jede Fach-Kennung der Browse-Liste wird von der Achse auch gefuellt.
        let gefuellt = Set(CatalogGenreAxis.musicShelves.map(\.key))
        for shelf in gefuellt {
            #expect(!CatalogGenreAxis.musicSubjects(forShelf: shelf).isEmpty,
                    "Fach \(shelf) steht in der Liste, aber kein Begriff faellt darauf")
        }
        // Jamendo fragt OHNE Trennzeichen. Die Archive-Schreibweisen wuerden
        // die fuzzytags-Abfrage nur verlaengern.
        for shelf in gefuellt {
            for tag in CatalogGenreAxis.musicTags(forShelf: shelf) {
                #expect(CatalogGenreAxis.normalizedMusicTerm(tag) == tag,
                        "\(tag) ist eine Archive-Schreibweise in der Jamendo-Abfrage")
            }
        }
    }

    /// Dieselbe Klasse ein zweites Mal: die Musik-Reihe auf Start und der
    /// Musik-Tab schoepfen aus DEMSELBEN Topf.
    /// Sie bekommen jetzt je Flaeche ihre eigene Ordnung. Dieselbe Antwort
    /// wie bei den Buch-Reihen, nur an einem anderen Ort.
    @Test("die beiden Musik-Reihen zeigen denselben Topf nicht in derselben Folge")
    func theTwoMusicRowsAreNotTwins() {
        let topf = (1...20).map { LibraryItem(id: "jam:t\($0)", media: nil, addedAt: nil) }
        let start = CatalogMix.ordered(topf, for: .musicHome, session: 99)
        let tab = CatalogMix.ordered(topf, for: .musicTab, session: 99)
        #expect(start.map(\.id) != tab.map(\.id), "die beiden Reihen sind Zwillinge")
        // Nichts geht verloren und nichts kommt dazu. Es ist eine Ordnung,
        // kein Filter.
        #expect(Set(start.map(\.id)) == Set(topf.map(\.id)))
        #expect(start.count == topf.count && tab.count == topf.count)
        // Innerhalb einer Sitzung sortiert sich nichts um.
        #expect(CatalogMix.ordered(topf, for: .musicHome, session: 99).map(\.id) == start.map(\.id))
        // Rot-Probe: mit DEMSELBEN Startwert waeren sie identisch. Das
        // Instrument sieht den Unterschied also nur wegen der Ableitung.
        var gen = RediscoverSections.SplitMix64(seed: CatalogMix.seed(for: .musicHome, session: 99))
        _ = gen.next()
        #expect(CatalogMix.seed(for: .musicHome, session: 99)
                != CatalogMix.seed(for: .musicTab, session: 99))
        // Und eine Liste mit einem Eintrag bleibt, wie sie ist.
        #expect(CatalogMix.ordered(Array(topf.prefix(1)), for: .musicTab).count == 1)
    }

    /// Die Lizenz-Oeffnung mit ihrer Grenze: anzeigen und streamen auch OHNE
    /// Deklaration, herunterladen NUR mit.
    /// Und: eine fehlende Angabe ist sichtbar, nie gar nichts und nie eine
    /// Behauptung.
    @Test("anzeigen ohne Deklaration, laden nur mit — und die Luecke ist sichtbar")
    func displayIsOpenButCopyingStaysLicensed() {
        // Der ANZEIGE-Weg traegt den Filter nicht mehr.
        for source in [CatalogSource.oldTimeRadio, .archiveBooks] {
            let query = try? #require(ArchiveOrgClient.archiveBaseQuery(for: source))
            #expect(query?.contains("licenseurl") == false,
                    "\(source.rawValue) filtert die ANZEIGE wieder nach Lizenz")
        }
        #expect(!ArchiveMusicCatalog.netlabels.query.contains("licenseurl"))
        // Der LADE-Weg tut es sehr wohl.
        #expect(!FreeCatalog.mayDownload(licenceURL: nil))
        #expect(!FreeCatalog.mayDownload(licenceURL: ""))
        #expect(!FreeCatalog.mayDownload(licenceURL: "   "))
        #expect(FreeCatalog.mayDownload(licenceURL: "https://creativecommons.org/licenses/by/4.0/"))
        // Und die Kachel sagt es, statt zu schweigen.
        #expect(FreeCatalog.licenceLabel(nil) == FreeCatalog.unstatedRights)
        #expect(FreeCatalog.licenceLabel("") == FreeCatalog.unstatedRights)
        // Rot-Probe: eine echte Angabe wird weiterhin als solche gelesen.
        #expect(FreeCatalog.licenceLabel("https://creativecommons.org/licenses/by-nc-nd/3.0/") == "CC BY-NC-ND")
    }

    /// Die Jahrzehnte-Achse. Einzeljahre falten, bereits gefaltete
    /// Angaben bleiben, und was kein Jahr nennt, faellt HERAUS statt in ein
    /// Sammelfach. Dieselbe positive Zuordnung wie bei den Gattungen.
    @Test("Einzeljahre falten auf ihr Jahrzehnt, Jahrloses faellt heraus")
    func singleYearsFoldOntoTheirDecade() {
        #expect(CatalogGenreAxis.decade(forSubject: "1943") == "1940s")
        #expect(CatalogGenreAxis.decade(forSubject: "1949") == "1940s")
        #expect(CatalogGenreAxis.decade(forSubject: "1950") == "1950s")
        #expect(CatalogGenreAxis.decade(forSubject: "1940s") == "1940s")
        #expect(CatalogGenreAxis.decade(forSubject: " 1950S ") == "1950s")
        // Kein Jahr = kein Fach. Nie geraten, nie gesammelt.
        #expect(CatalogGenreAxis.decade(forSubject: "detective") == nil)
        #expect(CatalogGenreAxis.decade(forSubject: "otrr set") == nil)
        #expect(CatalogGenreAxis.decade(forSubject: "19") == nil)
        // Mehrere Jahre → mehrere Faecher, dedupliziert, in Browse-Ordnung.
        #expect(CatalogGenreAxis.decades(forSubjects: ["1955", "1943", "1949", "drama"])
                == ["1940s", "1950s"])
        #expect(CatalogGenreAxis.decades(forSubjects: ["detective"]).isEmpty)
    }

    /// Kachelreihen warfen ihre Bilder beim seitlichen Scrollen sofort wieder
    /// weg. Drei Ursachen, alle im Bild-Zwischenspeicher. Der Zaun haelt die
    /// beiden, die sich rechnen
    /// lassen. Die dritte (Zellen holen den warmen Treffer ab) haengt an
    /// Aufrufstellen und steht im Inventar.
    @Test("beide Speichergrenzen meinen dieselbe Zahl, und eine Ungueltigkeit raeumt nur ihren Eintrag")
    func theCacheLimitsAgreeAndInvalidationIsTargeted() throws {
        // Die Kostenrechnung, an der die alte Konfiguration scheiterte:
        // 400 x 400 x 4 = 640 kB je Vorschau. 40 MB fassten davon ~62, waehrend
        // `countLimit` 600 versprach. Die kleinere Grenze band unsichtbar.
        // 400 x 400 x 4 = 640.000 Bytes je Vorschau (dezimal. Nicht 640 KiB;
        // an dieser Verwechslung ist mein erster Anlauf gerissen).
        let vorschauKosten: Int = 400 * 400 * 4
        #expect(vorschauKosten == 640_000)
        // 40 MB fassten davon rund 62, waehrend `countLimit` 600 versprach.
        let altesBudget: Int = 40 * 1024 * 1024
        #expect(altesBudget / vorschauKosten < 70)
        let text = try String(contentsOf: sourceFile("Sources/Networking/ImageCache.swift"),
                              encoding: .utf8)
        // Beide Grenzen je Speicher sagen jetzt dieselbe Zahl. Sonst ist eine
        // von beiden wieder Zierde.
        #expect(text.contains("thumbCache.countLimit = Self.thumbBudget"),
                "die Stueckzahl steht wieder als eigene Zahl neben der Kostengrenze")
        #expect(text.contains("thumbCache.totalCostLimit = Self.thumbBudget"),
                "die Kostengrenze wird nicht mehr aus der Stueckzahl abgeleitet")
        #expect(text.contains("memoryCache.countLimit = Self.fullCoverBudget"))
        #expect(text.contains("memoryCache.totalCostLimit = Self.fullCoverBudget"))
        // Und die Vorschauen bekommen mehr als die Vollbilder. Sie sind das,
        // was JEDE Reihe und JEDES Raster braucht.
        #expect(ImageCache.thumbBudget > ImageCache.fullCoverBudget * 10)
        // Ursache 2: eine Ungueltigkeit raeumt ihre Groessenvarianten, nicht
        // den ganzen Speicher.
        let body = try #require(functionBody(of: "func invalidate(url: URL)", in: text))
        #expect(!body.contains("thumbCache.removeAllObjects()"),
                "eine einzelne URL leert wieder alle Vorschauen der App")
        #expect(body.contains("thumbnailVariants"),
                "die Groessenvarianten werden nicht mehr benannt")
        // Die Varianten muessen die WIRKLICH angefragten sein. Sonst raeumt
        // die gezielte Fassung an der Sache vorbei.
        #expect(Set(ImageCache.thumbnailVariants) == Set([400, 600]))
    }

    /// Das Krimi-Fach zeigte drei Titel: die Faecher fragten die ALPHABETISCH
    /// ersten Begriffe. Krimi bekam `crime` (5 Treffer) statt `mystery` (49)
    /// und `detective` (47). 4 statt 141
    /// Titel; Science-Fiction fragte zwei Begriffe mit zusammen NULL.
    ///
    /// Dieselbe Klasse, die der Zaun beim alphabetischen Deckel der
    /// Musik-Achse gefangen hat. Dort gefangen, hier live auf der Flaeche.
    @Test("ein Fach fragt seine ergiebigsten Begriffe, nie die alphabetisch ersten")
    func aShelfAsksItsRichestTermsNotItsFirstAlphabetically() {
        let krimi = CatalogGenreAxis.subjects(forShelf: "crime")
        #expect(krimi.count >= 3, "die Probe misst nichts")
        // Die drei, die gefragt werden, sind die gemessen ergiebigsten.
        let gefragt = Array(krimi.prefix(3))
        #expect(gefragt.contains("mystery"), "der ergiebigste Krimi-Begriff faellt wieder weg")
        #expect(gefragt.contains("detective"))
        // Rot-Probe: alphabetisch waere `crime` vorn. Genau der schwache.
        #expect(krimi.sorted().first == "crime")
        #expect(gefragt.first != "crime", "die Sortierung ist wieder alphabetisch")
        // Und die Ordnung faellt monoton mit der gemessenen Ergiebigkeit.
        let ertrag = krimi.map { CatalogGenreAxis.measuredGutenbergYield[$0] ?? 0 }
        #expect(ertrag == ertrag.sorted(by: >), "die Reihenfolge folgt nicht der Messung")
        // Das Fach, das heute LEER war: seine Spitze traegt jetzt.
        let scifi = CatalogGenreAxis.subjects(forShelf: "scifi")
        #expect(scifi.first == "science fiction",
                "Science-Fiction fragt wieder zwei Begriffe mit null Treffern")
        #expect((CatalogGenreAxis.measuredGutenbergYield["science fiction"] ?? 0) > 0)
    }

    /// Bei archive.org faellt der Deckel auf der Begriffsliste ganz. Gemessen
    /// am Endpunkt (Netlabels, Elektronik-Fach): mit den ersten sechs
    /// Begriffen **3.395** Eintraege in 0,52 s, mit allen fuenfunddreissig
    /// **31.338** in 0,58 s. Faktor 9 fuer fuenf Hundertstelsekunden. Der
    /// Deckel kostete fast alles und sparte nichts. Er galt fuer Jamendos
    /// UNSCHARFE `fuzzytags`, nicht fuer `subject:`, das exakt trifft.
    @Test("die archive.org-Faecher kuerzen ihre Begriffsliste nicht mehr")
    func theArchiveShelvesDoNotCapTheirTerms() throws {
        for path in ["Sources/Networking/FreeCatalogClients.swift",
                     "Sources/Views/Music/ArchiveMusicPages.swift"] {
            let text = try String(contentsOf: sourceFile(path), encoding: .utf8)
            #expect(!text.contains("prefix(6).map { \"subject:"),
                    "\(path) kuerzt die Begriffe wieder alphabetisch")
        }
        // Die Musik-Faecher, bei denen der Fach-Name selbst herausfiel.
        for shelf in ["electronic", "rock", "world", "pop", "folk", "soul"] {
            let terms = CatalogGenreAxis.musicSubjects(forShelf: shelf)
            #expect(terms.contains(shelf), "\(shelf) traegt seinen eigenen Namen nicht")
            // Rot-Probe: mit dem alten Deckel waere genau das passiert.
            if terms.count > 6 {
                #expect(!terms.sorted().prefix(6).contains(shelf),
                        "die Rot-Probe traegt nicht — hier haette der Deckel nichts gekostet")
            }
        }
    }

    /// Zwei benachbarte Faecher begannen mit exakt denselben zwei Kacheln.
    /// Jedes Fach fragte seine
    /// Quelle mit derselben Sortierung, Seite 1. Ein Titel, der beide
    /// Faecher traegt, stand also in beiden oben. Die Ueberschneidung ist
    /// richtig, der gleiche AUSSCHNITT nicht.
    @Test("benachbarte Faecher greifen an verschiedenen Stellen ihres Bestands")
    func neighbouringShelvesDoNotShowTheSameExcerpt() {
        let tag = Date(timeIntervalSince1970: 1_756_000_000)
        let geschichte = CatalogShelfSource.shelfPage(shelf: "history", rows: 12, on: tag)
        let biografien = CatalogShelfSource.shelfPage(shelf: "biography", rows: 12, on: tag)
        #expect(geschichte != biografien,
                "zwei Faecher fragen wieder dieselbe Seite — die Zwillinge sind zurueck")
        // INVARIANTE 2: innerhalb EINES Tages stabil. Eine Reihe, die sich
        // unter den Fingern umsortiert, ist ein Layout-Sprung in Zeitlupe.
        #expect(CatalogShelfSource.shelfPage(shelf: "history", rows: 12, on: tag) == geschichte)
        #expect(CatalogShelfSource.shelfPage(shelf: "history", rows: 12,
                                             on: tag.addingTimeInterval(3600)) == geschichte)
        // Und am naechsten Tag bewegt sie sich.
        let morgen = tag.addingTimeInterval(86_400)
        #expect(CatalogShelfSource.shelfPage(shelf: "history", rows: 12, on: morgen) != geschichte)
        // Der Startwert haengt am Namen, nicht am Prozess. `hashValue` waere
        // je Start ein anderer und die Mischung damit nie stabil.
        #expect(CatalogRotation.salt(forShelf: "history")
                == CatalogRotation.salt(forShelf: "history"))
        #expect(CatalogRotation.salt(forShelf: "history")
                != CatalogRotation.salt(forShelf: "biography"))
        // Rot-Probe: ohne Startwert waeren beide gleich. Das Instrument
        // sieht den Unterschied also nur wegen des Salzes.
        #expect(CatalogRotation.page(total: 600, rowSize: 12, on: tag, salt: 0)
                == CatalogRotation.page(total: 600, rowSize: 12, on: tag, salt: 0))
    }

    /// Eine Kachel in der Fortsetzen-Reihe trug keinen Namen und lief nicht.
    /// Der Fund liegt nicht in der
    /// Zelle: der Tot-Vermerk wurde NUR beim Bauen der Katalogreihen gelesen,
    /// und diese Reihe liest den HOERVERLAUF. Lernen und Lesen waren nicht
    /// verbunden.
    @Test("ein totes Stueck verlaesst die Reihe, sein Hoerstand bleibt")
    func aDeadItemLeavesTheRowButKeepsItsProgress() throws {
        let suite = "r59-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let tot = FreeCatalog.jamendoPrefix + "1234"
        let lebt = FreeCatalog.jamendoPrefix + "5678"
        // Zwei angefangene Katalog-Titel im Verlauf (Album-Form, positionslos).
        let verlauf: [String: Any] = [
            "localPosition.\(tot)": [12.0, 1_756_000_000_000.0, 180.0, 1.0],
            "localPosition.\(lebt)": [30.0, 1_756_000_000_000.0, 200.0, 1.0],
        ]
        let vorher = ContinueSources.positionless(in: verlauf, serverKnows: [],
                                                  deadStore: defaults)
        #expect(vorher.count == 2, "die Probe misst nichts — der Verlauf ist leer")

        DeadCatalogItems.note(.dead, for: tot, defaults: defaults)
        let nachher = ContinueSources.positionless(in: verlauf, serverKnows: [],
                                                   deadStore: defaults)
        #expect(nachher.map(\.id) == [lebt], "das tote Stueck steht weiter in der Reihe")
        // INVARIANTE: der EINTRAG bleibt. Ein Hoerstand ist Nutzerbesitz.
        #expect(verlauf["localPosition.\(tot)"] != nil,
                "der Hoerstand wurde still geloescht")
    }

    /// Ein Transportfehler und ein klares Weg sind zwei verschiedene
    /// Antworten. Nur die zweite vermerkt. Sonst raeumt ein Funkloch die
    /// Reihe.
    @Test("nur ein klares Weg vermerkt, ein Transportfehler nie")
    func onlyAClearGoneIsRecorded() {
        #expect(FreeCatalog.isGone(URLError(.resourceUnavailable)))
        #expect(FreeCatalog.isGone(APIError.http(404, "")))
        // Das Funkloch, der Abbruch, das ueberlastete Netz: kein Urteil.
        #expect(!FreeCatalog.isGone(URLError(.notConnectedToInternet)))
        #expect(!FreeCatalog.isGone(URLError(.timedOut)))
        #expect(!FreeCatalog.isGone(URLError(.cancelled)))
        #expect(!FreeCatalog.isGone(APIError.http(503, "")))
        // Und vermerkt wird nur, was uns gehoert. Ein Server-Buch nicht.
        #expect(FreeCatalog.isCatalogId(FreeCatalog.jamendoPrefix + "1"))
        #expect(FreeCatalog.isCatalogId(FreeCatalog.archivePrefix + "x"))
        #expect(!FreeCatalog.isCatalogId("abs-item-id"))
    }

    /// Stimmung und Tempo sind FILTER auf
    /// der Vollseite eines Fachs, Instrumental ein SCHALTER. Keine eigenen
    /// Reihen-Familien. Alle drei filtert Jamendo SERVER-seitig, am Endpunkt
    /// verprobt; die Seite wirft nichts nachtraeglich weg.
    ///
    /// Gemessen an 200 populaeren Titeln (26.08.): vocal 179 / instrumental
    /// 21 · speed medium 142, high 38, low 12, verylow 2 · Stimmungen in den
    /// vartags (energetic 58, love 52, happy 24, emotional 18, upbeat 11).
    @Test("die Jamendo-Filter reisen in der Abfrage, nicht im Nachhinein")
    func theJamendoFiltersTravelInTheQuery() {
        #expect(!JamendoFilter.none.isActive)
        #expect(JamendoFilter.none.queryItems.isEmpty)
        #expect(JamendoFilter.none.extraTags.isEmpty)

        var filter = JamendoFilter()
        filter.instrumentalOnly = true
        #expect(filter.isActive)
        #expect(filter.queryItems.contains { $0.name == "vocalinstrumental" && $0.value == "instrumental" })

        filter.tempo = .fast
        #expect(filter.queryItems.contains { $0.name == "speed" && $0.value == "high" })
        // `verylow` faellt mit `low` zusammen. Zwei von zweihundert Titeln
        // rechtfertigen kein eigenes Fach, aber sie duerfen nicht verloren
        // gehen.
        filter.tempo = .slow
        let langsam = try? #require(filter.queryItems.first { $0.name == "speed" }?.value)
        #expect(langsam?.contains("low") == true)
        #expect(langsam?.contains("verylow") == true)

        // Die Stimmung laeuft ueber die Tags, weil Jamendo sie dort fuehrt.
        filter.mood = .energetic
        #expect(filter.extraTags == ["energetic"])
        #expect(!filter.queryItems.contains { $0.name == "mood" },
                "die Stimmung wandert in ein Feld, das die Quelle nicht kennt")
        // Jede angebotene Stufe hat auch einen Wert fuer die Quelle.
        for tempo in JamendoFilter.Tempo.allCases {
            #expect(!tempo.apiValues.isEmpty, "\(tempo.rawValue) hat keinen Quellwert")
        }
    }

    /// Der Tages-Speicher war allein nach dem FACH-Namen abgelegt. Werden die
    /// Begriffe eines Fachs ausgetauscht, liefert er bis zu 24 h weiter die
    /// Antwort der ALTEN Regel. Nach einem Update saehe jeder Nutzer einen
    /// Tag lang die alten Faecher.
    ///
    /// Die Klasse in allgemeiner Form: ein Ergebnis ueberlebt die Berechnung,
    /// die es hervorgebracht hat.
    @Test("ein gespeichertes Ergebnis gilt nur, solange seine Regel gilt")
    func aStoredResultOnlyHoldsWhileItsRuleHolds() throws {
        let suite = "r60-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = CatalogShelfSource.shelfStore
        let shelf = CatalogShelfSource.ShelfStock(total: 5, books: [], docs: nil)
        let id = CatalogShelfSource.stockId(surface: CatalogSource.gutenberg.rawValue,
                                            shelf: "crime")

        // Gespeichert unter der Regel von GESTERN.
        #expect(store.store(.found(shelf), for: id, rule: "crime|crime & mystery fiction",
                            defaults: defaults))
        #expect(store.load(defaults: defaults)[id] != nil,
                "die Probe misst nichts — nichts wurde gespeichert")

        // Mit der Regel von HEUTE ist der Eintrag nicht mehr auffindbar.
        let heute = CatalogShelfSource.shelfRule(forId: id)
        #expect(heute != "crime|crime & mystery fiction",
                "die Rot-Probe traegt nicht — die Regel hat sich gar nicht geaendert")
        #expect(store.load(defaults: defaults, rule: { _ in heute })[id] == nil,
                "der Eintrag der alten Regel wird weiter ausgeliefert")

        // Und unter DERSELBEN Regel bleibt er selbstverstaendlich gueltig.
        // Der Abdruck darf den Speicher nicht wertlos machen.
        #expect(store.store(.found(shelf), for: id, rule: heute, defaults: defaults))
        #expect(store.load(defaults: defaults, rule: { _ in heute })[id] != nil)

        // Der Abdruck ist die WIRKLICH gefragte Auswahl, nicht der Fach-Name.
        #expect(heute.contains("mystery"), "der Abdruck kennt die Begriffe nicht")
        #expect(CatalogShelfSource.shelfRule(forId: id)
                != CatalogShelfSource.shelfRule(
                    forId: CatalogShelfSource.stockId(surface: CatalogSource.gutenberg.rawValue,
                                                      shelf: "horror")))
    }

    /// Der Debug-Hebel raeumt NUR Abgeleitetes. Die Grenze zwischen neu
    /// holen und Datenverlust steht am Code, nicht in der Beschriftung.
    @Test("der Hebel raeumt Abgeleitetes und fasst Nutzerbesitz nie an")
    func theLeverClearsOnlyDerivedStores() throws {
        let suite = "r60-lever-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Kein Schluessel des Hebels darf wie Nutzerbesitz aussehen.
        for entry in DerivedStores.all {
            for besitz in DerivedStores.userOwnedPrefixes {
                #expect(!entry.key.hasPrefix(besitz),
                        "\(entry.key) sieht aus wie Nutzerbesitz")
            }
            #expect(!entry.label.isEmpty, "der Hebel muss sagen, was er raeumt")
        }

        // Am VERHALTEN: Abgeleitetes geht, Besitz bleibt.
        for entry in DerivedStores.all { defaults.set(["x": 1.0], forKey: entry.key) }
        defaults.set([12.0, 1.0], forKey: "localPosition.jam:1")
        defaults.set(["meine"], forKey: "maerPlaylists")

        let geleert = DerivedStores.clear(defaults: defaults)
        #expect(geleert.count == DerivedStores.all.count,
                "der Hebel meldet nicht, was er wirklich geraeumt hat")
        for entry in DerivedStores.all {
            #expect(defaults.object(forKey: entry.key) == nil, "\(entry.key) liegt noch")
        }
        #expect(defaults.object(forKey: "localPosition.jam:1") != nil,
                "ein HOERSTAND wurde geraeumt — das ist Datenverlust")
        #expect(defaults.object(forKey: "maerPlaylists") != nil,
                "eine PLAYLIST wurde geraeumt — das ist Datenverlust")

        // Nichts zu raeumen ist eine Antwort, keine leere Meldung.
        #expect(DerivedStores.clear(defaults: defaults).isEmpty)
    }

    /// Sammelbaende werden nach hinten sortiert. Die Zahl der Schlagworte
    /// taugt nicht als Signal: gemessen an 150 LibriVox-Eintraegen haben
    /// Sammelbaende im Mittel 6,2, die uebrigen 6,4. Der TITEL auch nicht.
    /// `Vanished Arizona: Recollections` enthaelt `collection` und ist ein
    /// einzelnes Werk.
    ///
    /// Was traegt, ist LibriVox' eigene Konvention: `creator` ist GENAU
    /// `Various`. Exakte Gleichheit, also kann kein Teilstring hineinrutschen.
    @MainActor
    @Test("Sammelbaende erkennt die Konvention, nicht der Titel")
    func collectionsAreRecognisedByConventionNotByTitle() throws {
        func doc(_ creator: String, _ title: String) throws -> ArchivePopularDoc {
            let json = "{\"identifier\":\"x\",\"title\":\"\(title)\",\"creator\":\"\(creator)\"}"
            return try JSONDecoder().decode(ArchivePopularDoc.self, from: Data(json.utf8))
        }
        // Die gemessenen echten Faelle.
        #expect(FreeCatalog.isMultiAuthorCollection(try doc("Various", "Children's Short Works, Vol. 031")))
        #expect(FreeCatalog.isMultiAuthorCollection(try doc("various", "La Lecture, tome 8")))
        // Rot-Probe: die Titel-Falle, die eine Wortsuche gefangen haette.
        #expect(!FreeCatalog.isMultiAuthorCollection(
            try doc("Martha Summerhayes", "Vanished Arizona: Recollections of the Army")),
                "ein einzelnes Werk wird als Sammelband einsortiert")
        // Und ein Urheber, der `various` nur ENTHAELT, ist keiner.
        #expect(!FreeCatalog.isMultiAuthorCollection(try doc("Various Artists Ensemble", "X")))
        #expect(!FreeCatalog.isMultiAuthorCollection(try doc("", "X")))
        // Der Malus ORDNET, er wirft nichts weg. Das ist der Unterschied
        // zwischen nach hinten sortieren und ausschliessen. Gefragt wird die
        // eine Stelle, die die Buch-Regale eintraegt, und die Seite verlangt
        // die Ordnung dort.
        let sammlung = ArchivePopularDoc(
            identifier: "collection-\(UUID().uuidString)", title: ArchiveStringList(["S"]),
            creator: ArchiveStringList(["Various"]), downloads: 1, runtime: nil, licenseurl: nil,
            year: nil, subject: nil, collection: ArchiveStringList(["etree"]))
        let werk = ArchivePopularDoc(
            identifier: "single-\(UUID().uuidString)", title: ArchiveStringList(["W"]),
            creator: ArchiveStringList(["A"]), downloads: 1, runtime: nil, licenseurl: nil,
            year: nil, subject: nil, collection: ArchiveStringList(["etree"]))
        let regal = try #require(CatalogShelfEntries.shelf(
            .archive(docs: [sammlung, werk], total: 2), source: .archiveBooks, collectionsLast: true))
        #expect(regal.items.map(\.id) == [werk, sammlung].map { FreeCatalog.archivePrefix + ($0.identifier ?? "") },
                "die Sammelbaende werden nicht mehr angehaengt, sondern verworfen")
        let text = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "private func applyShelf(", in: text))
        #expect(body.contains("collectionsLast: true"),
                "die Buch-Regale verlangen die Ordnung nicht mehr")
    }

    /// Eine Sendungsseite blieb ohne Bild, obwohl der Feed sein Bild ZWEIMAL
    /// nennt: die RSS-Form `<image><url>…</url></image>` las der Leser gar
    /// nicht, und die itunes-Form OHNE `href` fiel durch, weil das Attribut
    /// leer ist. `FeedArtworkLookup` kannte die RSS-Form bereits. Zwei
    /// Leser, eine Schreibweise, einer kann mehr.
    ///
    /// Gemessen ueber die 21 kuratierten Feeds: zwei schreiben die
    /// itunes-Textform, es sind also zwei fehlende Bilder, nicht eines.
    @Test("der Feed-Leser versteht jede Schreibweise des Sendungsbilds")
    func theFeedReaderUnderstandsEverySpelling() {
        func bild(_ kanal: String) -> String? {
            let xml = """
            <?xml version="1.0"?><rss version="2.0"><channel>
            <title>T</title>\(kanal)
            <item><title>E</title><guid>g1</guid>
            <enclosure url="https://example.org/a.mp3" type="audio/mpeg"/></item>
            </channel></rss>
            """
            return RSSFeedParser(feedURL: "https://example.org/feed.xml")
                .parse(Data(xml.utf8))?.artworkURL
        }
        // Die Form, die schon ging.
        #expect(bild("<itunes:image href=\"https://example.org/a.jpg\"/>") == "https://example.org/a.jpg")
        // Die beiden, die durchfielen. Der gemessene Feed nennt BEIDE.
        #expect(bild("<itunes:image>https://example.org/b.jpg</itunes:image>") == "https://example.org/b.jpg",
                "die itunes-Textform faellt wieder durch")
        #expect(bild("<image><title>T</title><url>https://example.org/c.jpg</url></image>") == "https://example.org/c.jpg",
                "die RSS-Form faellt wieder durch")
        // Rot-Probe: ohne Bild wird keines erfunden.
        #expect(bild("") == nil)
        // Und ein ITEM-Bild wird nicht zum Sendungsbild.
        let ausItem = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>T</title>
        <item><title>E</title><guid>g1</guid>
        <itunes:image>https://example.org/folge.jpg</itunes:image>
        <enclosure url="https://example.org/a.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """
        #expect(RSSFeedParser(feedURL: "https://example.org/feed.xml")
            .parse(Data(ausItem.utf8))?.artworkURL == nil,
                "ein Folgenbild wird zum Sendungsbild erklaert")
    }

    private enum ArchivePodDoc {
        static let librivoxAnniversary = try! JSONDecoder().decode(
            ArchivePopularDoc.self,
            from: Data(#"{"identifier":"librivox_8th_anniversary","title":"LibriVox 8th Anniversary Collection"}"#.utf8))
        static let denied = try! JSONDecoder().decode(
            ArchivePopularDoc.self,
            from: Data(#"{"identifier":"HMSUlyssesAM","title":"HMS Ulysses"}"#.utf8))
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

    /// A hit inside a COMMENT is not a hit in the code. This very fence went
    /// red on the sentence that explains why the old form was replaced.
    private func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text of one function, from its signature to the closing brace at the
    /// same indentation. So a fence can scope its claim to ONE function
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
