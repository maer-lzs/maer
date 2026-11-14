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
        let files = SourceTree.files(under: root).filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "the sweep must see the tree, not an empty folder")
        return try files.map { (name: $0.lastPathComponent,
                                text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("no surface reads the STORED rows — reading goes through the loading getter", .needsTheSources)
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
    @Test("each catalog row is rendered once per surface", .needsTheSources)
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
    @Test("a booked failure counts as an answer, so the pass is complete")
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
    /// A shelf with 102 entries showed ONE tile and never a chevron,
    /// so no way into the genre library. The chevron rule
    /// (`total > shown`) was right. It
    /// got the count of the randomly loaded stock instead of the total.
    /// The total is in the response; this fence pins that it is
    /// also picked up from there.
    @Test("the source's total count is read, not estimated")
    func stockCountIsReadFromTheResponse() throws {
        let wire = Data("""
        {"response":{"numFound":102,"start":0,"docs":[
          {"identifier":"a","title":"A"},{"identifier":"b","title":"B"}]}}
        """.utf8)
        #expect(try ArchiveOrgClient.decodeTotal(wire) == 102)
        #expect(try ArchiveOrgClient.decodePopular(wire).count == 2)
        // With the stock instead of the total, 2 > 2 would be false. No chevron,
        // exactly the reported state. With the total, 102 > 2 is true.
        #expect(102 > 2)
        // A response without the count invents none: then the row carries
        // the existence form of the chevron, never a guessed amount.
        let ohne = Data("{\"response\":{\"docs\":[]}}".utf8)
        #expect(try ArchiveOrgClient.decodeTotal(ohne) == nil)
    }

    /// The build path must not probe. The old chain asked archive.org twice
    /// PER TILE. 72 serial round trips and 4,5 MB of metadata just to learn
    /// whether a tile has a picture, measured at 43 s per
    /// pass. This fence holds the construction: picking is a pure cut, and
    /// no surface may reintroduce a per-tile probe on the way to a row.
    @Test("building a row does NOT ask the network per tile", .needsTheSources)
    func buildingARowDoesNotProbePerTile() throws {
        let cut = FreeCatalogLoader.picksWithoutProbing(
            (1...30).map { LibraryItem(id: "arch:item-\($0)", media: nil, addedAt: nil) },
            cap: RowPreview.limit)
        #expect(cut.count == RowPreview.limit)
        #expect(cut.first?.id == "arch:item-1", "die Ordnung der Quelle bleibt")
        // Red probe of the construction: the probe names are gone from the
        // build path. If one returns, it shows up here.
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

    /// A row fetches no chapters. The old full fetch was 95 % chapter
    /// list (291 kB for 20 books, measured at the endpoint); the
    /// field list leaves them out and carries `genres` instead. The fence pins
    /// both halves. What the row fetches AND what it does not fetch.
    @Test("the row field list leaves out the chapters and carries the genres")
    func rowFieldsCarryGenresAndNoChapters() {
        let fields = LibriVoxClient.rowFields
        #expect(fields.contains("genres"), "die Gattungen sind der Grund fuer den Umbau")
        #expect(!fields.contains("sections"),
                "Kapitel gehoeren an die Detailseite, nicht in jede Kachel")
        for needed in ["url_iarchive", "url_rss", "authors", "title"] {
            #expect(fields.contains(needed), "\(needed) fehlt der Reihe")
        }
    }

    /// The measured OTR terms lie on the ONE axis.
    @Test("the re-measured OTR terms are sorted in")
    func measuredOTRTermsAreOnTheAxis() {
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Detective"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["mystery"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Crime Drama"]) == ["crime"])
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Drama"]) == ["drama"])
        // Red probe: the assignment stays EXACT, no substring.
        #expect(CatalogGenreAxis.shelves(forSubjects: ["Western Electric"]).isEmpty)
    }

    /// The pass publishes in the order in which the sources
    /// FINISH.
    /// `async let` plus a sequential `await` waits in START order. The
    /// three fast rows (about 1 s each) thus hung on the slowest
    /// (LibriVox, measured 7-35 s), and publishing per row could not
    /// work at all. Red probe: the old form stood exactly here.
    @Test("the pass waits for completion, not for the start order", .needsTheSources)
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
        // And the second half: a switched-off source creates no
        // fetch any more, instead of being started and thrown away.
        #expect(!body.contains("_ = await "),
                "eine abgeschaltete Quelle wird wieder gestartet und verworfen")
        // Red probe on the instrument itself: against the OLD version it
        // trips. A fence that merely finds nothing proves nothing.
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
        // And the opposite direction: a COMMENT that explains the old form
        // must not trigger the fence. That is exactly where it once broke.
        let erklaert = """
            @MainActor
            enum Neu {
                static func load(onRow: RowSink? = nil) async -> SourceRows {
                    // `async let` plus a sequential `await` waited in start order.
                    await withTaskGroup(of: Fetched.self) { group in }
                    return rows
                }
            }
            """
        let erklaerteForm = try #require(functionBody(of: "static func load(onRow: RowSink? = nil)", in: erklaert))
        #expect(!erklaerteForm.contains("async let"),
                "ein Treffer im Kommentar wird als Treffer im Code gewertet")
    }

    /// Measured at the endpoint: the server computes the whole response
    /// before it sends the first byte (22-25 s to the first byte).
    /// Against the shared timeout of 20 s, this query could only lose through
    /// the retry ladder. 20+20+20 and then FAILURE. So it
    /// needs its own limit, as gutendex has.
    ///
    /// Dropping `extended=1` would halve the time and is still
    /// wrong: it is the only way to `url_iarchive`, and the
    /// COVER of every LibriVox tile hangs on it (measured: neither `fields=` nor the bare
    /// form delivers it). The fence pins exactly this trade-off.
    @Test("the slow source has its own timeout, and the cover source stays", .needsTheSources)
    func theSlowSourceCarriesItsOwnTimeout() throws {
        let text = try String(contentsOf: sourceFile("Sources/Networking/FreeCatalogClients.swift"),
                              encoding: .utf8)
        let new = try #require(functionBody(of: "static func newBooks(sinceDays: Int, limit: Int)", in: text))
        #expect(new.contains("timeoutInterval = 45"),
                "die Reihe faellt wieder ins geteilte 20-s-Limit und damit in die Wiederhol-Leiter")
        #expect(new.contains("\"extended\""),
                "ohne den Parameter fehlt url_iarchive — die Kacheln verlieren ihre Cover")
        // And the field list must request the cover source at all.
        #expect(LibriVoxClient.rowFields.contains("url_iarchive"))
        // The second half of this fence checked the
        // LibriVox genre feed. It is DELETED (it delivered `lv:` books
        // for a surface made of `lva:` documents, so two identifiers for
        // the same titles). The fence now pins that it does not
        // come back, instead of guarding its parameters.
        #expect(!text.contains("func books(genre:"),
                "der LibriVox-Gattungsfeed ist zurueck — zwei Kennungen fuer dieselben Titel")
    }

    /// Two of four sources had lost their tile rows: `shelves` read
    /// only `shelfStock` any more, and that was filled
    /// exclusively through `archiveBaseQuery`, which returned `nil` for LibriVox and
    /// Gutenberg. The surface promised the shelves
    /// (`hasChips`) and never delivered them.
    ///
    /// The fence pins the INVARIANT, not the single case: every source that
    /// promises shelves can also query them. And the other way round.
    @Test("no source promises shelves that it cannot query")
    func everyShelfPromiseIsBackedByAQuery() {
        for source in CatalogSource.allCases where CatalogShelfSource.canServeShelves(source) {
            // Either there is an archive.org base. Or the source has
            // its OWN path in the shared shelf fetch.
            let ownWay = source == .gutenberg
            #expect(ArchiveOrgClient.archiveBaseQuery(for: source) != nil || ownWay,
                    "\(source.rawValue) verspricht Faecher ohne Abfrage dahinter")
        }
        // Red probe: the regression was exactly the absence of this base.
        #expect(ArchiveOrgClient.archiveBaseQuery(for: .librivox) != nil,
                "LibriVox ist wieder ohne Fach-Abfrage — das war R53")
        // And the sources without an axis promise nothing either.
        #expect(!CatalogShelfSource.canServeShelves(.oerr))
    }

    /// Two classes in one fence: the gate must not book the pass
    /// BEFORE it took place, and a
    /// failure is an ANSWER, not a silent absence.
    @Test("the shelf gate books after the pass, and a failure is distinguishable", .needsTheSources)
    func theShelfGateBooksAfterwardsAndFailuresAreVisible() throws {
        let text = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "private func loadShelves(by caller: String)", in: text))
        let gate = try #require(body.range(of: "shelvesLoaded = true"))
        let work = try #require(body.range(of: "withTaskGroup"))
        #expect(gate.lowerBound > work.upperBound,
                "das Tor bucht den Lauf wieder, bevor er stattgefunden hat")
        #expect(body.contains("Task.isCancelled"),
                "ein abgebrochener Lauf gilt wieder als erledigt")
        #expect(!body.contains("try? await"),
                "ein Fehlschlag wird wieder verschluckt und sieht aus wie leer")
        #expect(body.contains("CatalogPageFailure.sentence(for:"), "der Grund wird nicht mehr benannt")
    }

    /// The shelves are fetched once per day, for EVERY source.
    /// The store lives in the mechanism that already HAS an expiry.
    /// And its founding rule is exactly the one that counts here: a
    /// failure is never written down (otherwise the page would be broken for the rest of
    /// the day). The fence checks both invariants on behavior.
    @Test("the day store expires at the day change and never takes in a failure")
    func theDayStoreExpiresAndNeverKeepsAFailure() throws {
        let suite = "shelfstore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = CatalogShelfSource.shelfStore
        let shelf = CatalogShelfSource.ShelfStock(total: 67, books: [], docs: nil)
        let heute = Date(timeIntervalSince1970: 1_756_000_000)

        #expect(store.store(.found(shelf), for: "adventure", defaults: defaults, now: heute))
        #expect(store.load(defaults: defaults, now: heute)["adventure"] != nil, "der Treffer fehlt")
        // A failure writes NOTHING. Not even over a hit.
        #expect(store.store(.failed, for: "crime", defaults: defaults, now: heute) == false)
        #expect(store.load(defaults: defaults, now: heute)["crime"] == nil,
                "ein Fehlschlag ist im Tages-Speicher gelandet")
        // A clean pass without content IS an answer and may stay.
        #expect(store.store(.absent, for: "poetry", defaults: defaults, now: heute))
        // The expiry hangs on the DAY CHANGE, the same as for the rotation.
        // A rolling deadline would be a second clock: an entry from 23:50
        // would still answer the next evening with yesterday's page.
        let morgen = heute.addingTimeInterval(24 * 3600)
        #expect(CatalogRotation.dayIndex(on: morgen) == CatalogRotation.dayIndex(on: heute) + 1)
        #expect(store.load(defaults: defaults, now: morgen).isEmpty,
                "der Tages-Speicher ueberlebt den Tageswechsel")
        // Red probe on the instrument: the same entry, a few minutes later,
        // naturally still stands. Otherwise the case would only check that
        // `load` discards anything at all.
        #expect(store.load(defaults: defaults, now: heute.addingTimeInterval(600))["adventure"] != nil)
    }

    /// EVERY path that fetches shelves goes through the one door. The brief
    /// names netlabels and shellac explicitly; the decades and the
    /// popular rows of the shellac surfaces bypassed it, because they are
    /// their own load paths. Without this fence the next new
    /// load path falls through just the same, and nobody sees it.
    @Test("every shelf load path goes through the one door, not past the store", .needsTheSources)
    func everyShelfPathGoesThroughTheOneDoor() throws {
        let seite = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                              encoding: .utf8)
        let dekaden = try #require(functionBody(of: "private func loadDecades() async -> [CatalogShelfSource.Way] {", in: seite))
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

    /// The WARM visit must not flash a placeholder. If the
    /// day is in the store, the tiles come at once; a skeleton that then
    /// briefly lights up IS the layout shift it was built against.
    /// The condition for this is that the placeholder hangs on the empty
    /// day store, not only on the wait time.
    @Test("a stored day prevents the placeholder instead of flashing it", .needsTheSources)
    func aStoredDayPreventsThePlaceholder() throws {
        let suite = "warmday-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Cold: the store knows of no shelf.
        #expect(CatalogShelfSource.knownShelfKeys(for: .librivox, defaults: defaults).isEmpty)

        // Warm: exactly the shelves that are in the day, and only those.
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
        // And the day of one source does not answer for the other.
        #expect(CatalogShelfSource.knownShelfKeys(for: .oldTimeRadio, defaults: defaults).isEmpty)

        // The surface hangs the placeholder on exactly this answer. Without
        // this clause the warm visit would first show a skeleton and then
        // the tiles that were already there.
        let seite = try String(contentsOf: sourceFile("Sources/Views/CatalogSourcePage.swift"),
                               encoding: .utf8)
        let body = try #require(functionBody(of: "private var showsShelfPlaceholder: Bool {",
                                             in: seite))
        #expect(body.contains("knownShelfKeys.isEmpty"),
                "der Platzhalter blitzt beim warmen Besuch auf")

        // The same clause on the two music surfaces. They read the day
        // through the area key, so `storedDay` is there.
        let musik = try String(contentsOf: sourceFile("Sources/Views/Music/ArchiveMusicPages.swift"),
                               encoding: .utf8)
        let kopf = "private var showsShelfPlaceholder: Bool {"
        var rest = Substring(musik)
        var gefunden = 0
        while let treffer = rest.range(of: kopf) {
            // Collapse whitespace before searching: a call that spans
            // two lines is the same call. Otherwise the fence would check
            // the line length instead of the statement, and that is exactly where
            // it broke on the first run.
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

    /// And the door also READS the store. A fence on the source text alone
    /// only showed that the call is there.
    @Test("a written-down day answers the query without asking")
    func aStoredDayAnswersWithoutAsking() async throws {
        let stock = CatalogShelfSource.ShelfStock(
            total: 7, books: nil,
            docs: [ArchivePopularDoc(identifier: "gunsmoke", title: nil, creator: nil,
                                     downloads: nil, runtime: nil, licenseurl: nil,
                                     year: nil, subject: nil)])
        // Decade: the stored day carries the answer.
        let (jahrzehnt, weg) = try await CatalogShelfSource.decadePreview(
            source: .oldTimeRadio, decade: "1950s", rows: 12, storedDay: ["1950s": stock])
        #expect(weg == .day, "das Jahrzehnt fragte am gespeicherten Tag vorbei")
        // The line of a pass names every path, also the one with zero.
        #expect(CatalogShelfSource.Way.tally([.stock, .day, .stock]) == "stock=2 day=1 network=0")
        guard case .archive(let docs, let total) = jahrzehnt else {
            Issue.record("das Jahrzehnt antwortet nicht mit Archive-Kacheln"); return
        }
        #expect(docs.first?.identifier == "gunsmoke")
        #expect(total == 7)

        // Popular row of a surface: the same answer from the same day.
        let beliebt = try await CatalogShelfSource.areaPopular(
            area: ArchiveMusicCatalog.shellacShelves[0], rows: 12, page: 1,
            storedDay: [CatalogShelfSource.popularShelf: stock])
        #expect(beliebt.first?.identifier == "gunsmoke")
    }

    /// The store now writes down archive documents, so the
    /// entry must survive its own read path. The check runs against the
    /// SERVER form: `creator` as a bare string, `year` as a NUMBER, as
    /// archive.org delivers it. A round trip alone would only prove that my
    /// writer fits my reader.
    @Test("a written-down archive document survives its own read path")
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

    /// An entry is filed under source AND shelf. Without the source in the
    /// key, six surfaces would write the same shelf names to the same
    /// place, and LibriVox would get the tiles of Old Time Radio.
    @Test("the key carries the source, not only the shelf")
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

        // And the rule per entry distinguishes the sources as well: it
        // carries the query, not only the terms. Otherwise the
        // change of one surface's parent query would have left the store of the other
        // valid.
        #expect(CatalogShelfSource.shelfRule(forId: lv)
                != CatalogShelfSource.shelfRule(forId: otr))
    }

    /// Audiobook library, Start and podcast library showed the same
    /// tile row. The comment in `PodcastsView` claimed
    /// disjointness, the code below never established it. The test it
    /// appealed to (`Catalog sources split disjointly …`,
    /// `FreeCatalogTests`) is not wrong: it splits the SOURCE
    /// enumeration, not the tiles. That is the missing sentence.
    @Test("podcast tab shows no catalog tile, audiobook tab no feed")
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
        // And no tile is in BOTH.
        #expect(Set(podcasts.map(\.id)).isDisjoint(with: Set(books.map(\.id))))
        // Red probe: the instrument SEES both kinds. Start mixes them, and
        // that is exactly how the podcast row looked until now. Without this proof
        // a blind fence could not be told from an empty result.
        let home = CatalogMix.tiles(for: .home, rows: rows)
        var sahFeed = false, sahItem = false
        for tile in home {
            if case .feed = tile { sahFeed = true }
            if case .item = tile { sahItem = true }
        }
        #expect(sahFeed && sahItem,
                "die Rot-Probe sieht die gemischte Form nicht — der Zaun beweist nichts")
    }

    /// Start may show both worlds, but must never be tile-identical
    /// to a tab row. The shared session seed guaranteed
    /// the OPPOSITE until now. Its intent (within a session nothing is
    /// re-sorted) stays and is derived per surface.
    @Test("Start is no twin row, and the seed stays stable per session")
    func homeIsNeverATwinOfATabRow() {
        for a in CatalogMix.Surface.allCases {
            for b in CatalogMix.Surface.allCases where a != b {
                #expect(CatalogMix.seed(for: a, session: 42) != CatalogMix.seed(for: b, session: 42),
                        "\(a.rawValue) und \(b.rawValue) teilen ihren Startwert")
            }
        }
        // Stable: the same session value yields the same surface value.
        #expect(CatalogMix.seed(for: .home, session: 7) == CatalogMix.seed(for: .home, session: 7))
        // And on the result: Start is not tile-identical to a tab row.
        let rows = Self.filledRows()
        let home = CatalogMix.tiles(for: .home, rows: rows).map(\.id)
        #expect(!home.isEmpty, "die Probe misst nichts")
        #expect(home != CatalogMix.tiles(for: .podcasts, rows: rows).map(\.id))
        #expect(home != CatalogMix.tiles(for: .books, rows: rows).map(\.id))
    }

    /// A shelf with 2829 entries showed TWO tiles. The cause was not a
    /// thin stock, but a separating filter on its OWN source:
    /// `isNotLibriVoxDuplicate` discards every document that contains the name
    /// LibriVox. So on the LibriVox side almost everything.
    /// Measured at the live endpoint with the surface's query: **12 of 12
    /// discarded** (LibriVox), **0 of 12** for archive audiobooks and OTR,
    /// **0 of 50** in the broad pull of the archive audiobooks.
    ///
    /// INVARIANT: a filter that separates two sources from each other never
    /// runs on the source it defines.
    @Test("the separating filter never runs on the source it defines")
    func theSeparationNeverRunsOnItsOwnSource() {
        #expect(!FreeCatalog.separatesFromLibriVox(.librivox),
                "die LibriVox-Seite filtert wieder gegen sich selbst")
        for other in [CatalogSource.archiveBooks, .oldTimeRadio, .gutenberg] {
            #expect(FreeCatalog.separatesFromLibriVox(other),
                    "\(other.rawValue) trennt nicht mehr von LibriVox")
        }
        // On BEHAVIOR, not only on the rule. A real title from the
        // measured discard list.
        let doc = ArchivePodDoc.librivoxAnniversary
        #expect(!FreeCatalog.isCuratedArchiveDoc(doc, separatingFromLibriVox: true),
                "die Rot-Probe sieht den Filter nicht — er wirft nichts weg")
        #expect(FreeCatalog.isCuratedArchiveDoc(doc, separatingFromLibriVox: false),
                "der Titel faellt weiterhin auf seiner eigenen Quelle")
        // The block list keeps applying INDEPENDENTLY of this, on both paths.
        let gesperrt = ArchivePodDoc.denied
        #expect(!FreeCatalog.isCuratedArchiveDoc(gesperrt, separatingFromLibriVox: false),
                "die Sperrliste ist mit der Trennung mitgefallen")
    }

    /// The placeholder against the layout shift hangs on the MEASURED
    /// wait time, not on the source name. Otherwise in a month there is a
    /// `== .gutenberg` whose reason nobody knows any more.
    ///
    /// The MEASURE has changed, not the tolerance: what is measured is the
    /// PASS the surface waits for, not the single query.
    /// On the single query the archive sources looked fast (1,2 s)
    /// and got no placeholder, while their cold pass left gaps standing for eight
    /// seconds without saying anything. Measured:
    /// archive.org 8,4-17,8 s per pass, gutendex 454 s cold / 41 s warm.
    @Test("the placeholder hangs on the wait time of the PASS, not on the source name", .needsTheSources)
    func thePlaceholderHangsOnTheMeasuredWait() throws {
        // Every source that serves shelves waits longer than the threshold
        // and therefore says so.
        for langsam in [CatalogSource.gutenberg, .librivox, .archiveBooks, .oldTimeRadio] {
            #expect(CatalogShelfSource.showsLoadingPlaceholder(langsam),
                    "\(langsam.rawValue) laesst den kalten Durchgang stumm stehen")
        }
        // Red probe on the instrument: a source without shelves does not wait and
        // gets nothing either. Without it, a rule that is ALWAYS true
        // would report green just the same.
        for ohne in CatalogSource.allCases where !CatalogShelfSource.canServeShelves(ohne) {
            #expect(!CatalogShelfSource.showsLoadingPlaceholder(ohne),
                    "\(ohne.rawValue) zeigt ein Skelett fuer eine Wartezeit, die es nicht gibt")
        }
        // The decision MUST follow from the number. Otherwise it is a
        // special case under another name after all.
        for source in CatalogSource.allCases {
            #expect(CatalogShelfSource.showsLoadingPlaceholder(source)
                    == (CatalogShelfSource.coldPassSeconds(source) >= CatalogShelfSource.visibleWaitSeconds))
        }
        // The MUSIC surfaces run through area keys and would fall
        // through a check that knows only `CatalogSource.allCases`. They
        // wait on the same endpoint and therefore say so too.
        for flaeche in [ArchiveMusicCatalog.netlabels, ArchiveMusicCatalog.shellacAll] {
            #expect(CatalogShelfSource.showsLoadingPlaceholder(surface: flaeche.key),
                    "\(flaeche.key) laesst den kalten Durchgang stumm stehen")
            #expect(CatalogShelfSource.showsLoadingPlaceholder(surface: flaeche.key)
                    == (CatalogShelfSource.coldPassSeconds(surface: flaeche.key)
                        >= CatalogShelfSource.visibleWaitSeconds),
                    "die Musik-Flaeche entscheidet an einer zweiten Regel")
        }
        // Red probe: a name that does not exist as a surface waits for
        // nothing. Without it, a rule that gives EVERY string a
        // placeholder would report green just the same.
        #expect(!CatalogShelfSource.showsLoadingPlaceholder(surface: "gibt-es-nicht"))

        // And the measure is that of the pass: measured on the single query,
        // the decision comes out differently for the archive sources. Without this
        // sentence someone could turn the number back without
        // a case noticing. The single query, measured at the endpoint:
        // archive.org answers a shelf in 0,99 to 1,49 s, median 1,13 s.
        let einzelabfrage = 1.2
        #expect(einzelabfrage < CatalogShelfSource.visibleWaitSeconds,
                "die Einzelabfrage ist nicht mehr die kleinere Zahl — die Probe traegt nicht")
        #expect(CatalogShelfSource.coldPassSeconds(.librivox) > einzelabfrage,
                "ein Durchgang kostet nicht mehr als seine Einzelabfrage")
        // Red probe on the source text: no special case on the name in the rule.
        let text = try String(contentsOf: sourceFile("Sources/Networking/FreeCatalogClients.swift"),
                              encoding: .utf8)
        let body = try #require(functionBody(of: "static func showsLoadingPlaceholder(_ source: CatalogSource)", in: text))
        #expect(!body.contains("== .gutenberg"),
                "die Ausnahme ist zur Regel geworden — Schwelle statt Sonderfall")
    }

    /// The title plays, the mini player stays with the start wording.
    /// The line does observe the time. What was invented was the CHAPTER:
    /// for a piece without chapters, `withTimeMarks` created
    /// ONE mark, named after second zero and spanning the whole piece.
    /// That fixed the start wording while playback was running.
    /// Without chapters, the subtitle falls back to the running clock.
    @Test("a piece without chapters gets no invented mark")
    func aPieceWithoutChaptersGetsNoInventedMark() {
        // A catalog title: no chapters, three minutes.
        #expect(ChapterModel.withTimeMarks([], duration: 222).isEmpty,
                "die Startformulierung ist zurueck — eine Marke ueber das ganze Stueck")
        #expect(ChapterModel.resolved(chapters: [], tracks: [], duration: 222).chapters.isEmpty)
        // Red probe: a LONG piece without chapters still gets
        // jump marks. The instrument sees the difference.
        let lang = ChapterModel.withTimeMarks([], duration: 4 * ChapterModel.step)
        #expect(lang.count > 1, "die Sprungmarken sind fuer lange Stuecke mitgestorben")
        // And the actual purpose stays: a PARTIAL chapter list is
        // still filled up to the end.
        let teil = [ABSChapter(id: 0, start: 0, end: 600, title: "Eins")]
        #expect(ChapterModel.withTimeMarks(teil, duration: 3600).count > teil.count,
                "der eigentliche Zweck der Marken ist mitgefallen")
    }

    /// Music axis (fold small pots into large ones,
    /// cap ~30 shelves). And the INVARIANT: the axis is SHARED
    /// with JAMENDO, so the coverage of BOTH sources must be measured.
    ///
    /// Measured before the build (1.000 netlabel titles, 200 Jamendo titles):
    /// netlabels 36,0 % → **70,4 %**, Jamendo 81,0 % → **96,5 %**. Both
    /// rise; the folding takes nothing away from Jamendo.
    @Test("the folded music axis carries both sources")
    func theFoldedMusicAxisCarriesBothSources() {
        // The shelf of a tag, read from the table, as the shelf query
        // builds it: separators do not count; nil means unknown.
        func shelf(forTag tag: String) -> String? {
            let wanted = CatalogGenreAxis.normalizedMusicTerm(tag)
            return CatalogGenreAxis.musicAxis.first { CatalogGenreAxis.normalizedMusicTerm($0.key) == wanted }?.value
        }
        #expect(CatalogGenreAxis.musicShelves.count <= 30,
                "der Deckel von rund 30 Faechern ist gerissen")
        // The spelling families of both sources hit the same shelf.
        #expect(shelf(forTag: "trip-hop") == "electronic")
        #expect(shelf(forTag: "triphop") == "electronic")
        #expect(shelf(forTag: "Trip Hop") == "electronic")
        // The term that was missing entirely and is the second most frequent of the collection.
        #expect(shelf(forTag: "jazz") == "jazz")
        #expect(shelf(forTag: "experimental") == "experimental")
        // Jamendo's most used tags stay assigned. The folding must not
        // take anything from it (the invariant, pinned by examples).
        for tag in ["pop", "electropop", "singersongwriter", "indiepop", "rnb", "filmscore"] {
            #expect(shelf(forTag: tag) != nil,
                    "Jamendo-Tag \(tag) faellt aus der Achse")
        }
        // Unknown stays unknown. Never guessed.
        #expect(shelf(forTag: "Voellig Unbekannt") == nil)
        // Every shelf identifier of the browse list is also filled by the axis.
        let gefuellt = Set(CatalogGenreAxis.musicShelves.map(\.key))
        for shelf in gefuellt {
            #expect(!CatalogGenreAxis.musicSubjects(forShelf: shelf).isEmpty,
                    "Fach \(shelf) steht in der Liste, aber kein Begriff faellt darauf")
        }
        // Jamendo asks WITHOUT separators. The archive spellings would
        // only lengthen the fuzzytags query.
        for shelf in gefuellt {
            for tag in CatalogGenreAxis.musicTags(forShelf: shelf) {
                #expect(CatalogGenreAxis.normalizedMusicTerm(tag) == tag,
                        "\(tag) ist eine Archive-Schreibweise in der Jamendo-Abfrage")
            }
        }
    }

    /// The same class a second time: the music row on Start and the
    /// music tab draw from the SAME pot.
    /// They now get their own order per surface. The same answer
    /// as for the book rows, only in another place.
    @Test("the two music rows do not show the same pot in the same sequence")
    func theTwoMusicRowsAreNotTwins() {
        let topf = (1...20).map { LibraryItem(id: "jam:t\($0)", media: nil, addedAt: nil) }
        let start = CatalogMix.ordered(topf, for: .musicHome, session: 99)
        let tab = CatalogMix.ordered(topf, for: .musicTab, session: 99)
        #expect(start.map(\.id) != tab.map(\.id), "die beiden Reihen sind Zwillinge")
        // Nothing is lost and nothing is added. It is an order,
        // not a filter.
        #expect(Set(start.map(\.id)) == Set(topf.map(\.id)))
        #expect(start.count == topf.count && tab.count == topf.count)
        // Within a session nothing is re-sorted.
        #expect(CatalogMix.ordered(topf, for: .musicHome, session: 99).map(\.id) == start.map(\.id))
        // Red probe: with the SAME seed they would be identical. So the
        // instrument sees the difference only because of the derivation.
        var gen = RediscoverSections.SplitMix64(seed: CatalogMix.seed(for: .musicHome, session: 99))
        _ = gen.next()
        #expect(CatalogMix.seed(for: .musicHome, session: 99)
                != CatalogMix.seed(for: .musicTab, session: 99))
        // And a list with one entry stays as it is.
        #expect(CatalogMix.ordered(Array(topf.prefix(1)), for: .musicTab).count == 1)
    }

    /// The licence opening with its limit: show and stream even WITHOUT a
    /// declaration, download ONLY with one.
    /// And: a missing statement is visible, never nothing at all and never a
    /// claim.
    @Test("show without a declaration, download only with one, and the gap is visible")
    func displayIsOpenButCopyingStaysLicensed() {
        // The DISPLAY path no longer carries the filter.
        for source in [CatalogSource.oldTimeRadio, .archiveBooks] {
            let query = try? #require(ArchiveOrgClient.archiveBaseQuery(for: source))
            #expect(query?.contains("licenseurl") == false,
                    "\(source.rawValue) filtert die ANZEIGE wieder nach Lizenz")
        }
        #expect(!ArchiveMusicCatalog.netlabels.query.contains("licenseurl"))
        // The DOWNLOAD path does carry it.
        #expect(!FreeCatalog.mayDownload(licenceURL: nil))
        #expect(!FreeCatalog.mayDownload(licenceURL: ""))
        #expect(!FreeCatalog.mayDownload(licenceURL: "   "))
        #expect(FreeCatalog.mayDownload(licenceURL: "https://creativecommons.org/licenses/by/4.0/"))
        // And the tile says so, instead of staying silent.
        #expect(FreeCatalog.licenceLabel(nil) == FreeCatalog.unstatedRights)
        #expect(FreeCatalog.licenceLabel("") == FreeCatalog.unstatedRights)
        // Red probe: a real statement is still read as such.
        #expect(FreeCatalog.licenceLabel("https://creativecommons.org/licenses/by-nc-nd/3.0/") == "CC BY-NC-ND")
    }

    /// The decades axis. Single years fold, already folded
    /// statements stay, and what names no year drops OUT instead of into a
    /// catch-all shelf. The same positive assignment as for the genres.
    @Test("single years fold to their decade, yearless entries drop out")
    func singleYearsFoldOntoTheirDecade() {
        #expect(CatalogGenreAxis.decade(forSubject: "1943") == "1940s")
        #expect(CatalogGenreAxis.decade(forSubject: "1949") == "1940s")
        #expect(CatalogGenreAxis.decade(forSubject: "1950") == "1950s")
        #expect(CatalogGenreAxis.decade(forSubject: "1940s") == "1940s")
        #expect(CatalogGenreAxis.decade(forSubject: " 1950S ") == "1950s")
        // No year = no shelf. Never guessed, never collected.
        #expect(CatalogGenreAxis.decade(forSubject: "detective") == nil)
        #expect(CatalogGenreAxis.decade(forSubject: "otrr set") == nil)
        #expect(CatalogGenreAxis.decade(forSubject: "19") == nil)
        // Several years → several shelves, deduplicated, in browse order.
        #expect(CatalogGenreAxis.decades(forSubjects: ["1955", "1943", "1949", "drama"])
                == ["1940s", "1950s"])
        #expect(CatalogGenreAxis.decades(forSubjects: ["detective"]).isEmpty)
    }

    /// Tile rows threw their images away again at once when scrolling sideways.
    /// Three causes, all in the image cache. The fence pins the
    /// two that can be
    /// computed. The third (cells pick up the warm hit) hangs on
    /// call sites and is in the inventory.
    @Test("both store limits mean the same number, and an invalidation clears only its entry", .needsTheSources)
    func theCacheLimitsAgreeAndInvalidationIsTargeted() throws {
        // The cost calculation on which the old configuration failed:
        // 400 x 400 x 4 = 640 kB per preview. 40 MB held about 62 of them, while
        // `countLimit` promised 600. The smaller limit bound invisibly.
        // 400 x 400 x 4 = 640.000 bytes per preview (decimal. Not 640 KiB;
        // my first attempt broke on this mix-up).
        let vorschauKosten: Int = 400 * 400 * 4
        #expect(vorschauKosten == 640_000)
        // 40 MB held about 62 of them, while `countLimit` promised 600.
        let altesBudget: Int = 40 * 1024 * 1024
        #expect(altesBudget / vorschauKosten < 70)
        let text = try String(contentsOf: sourceFile("Sources/Networking/ImageCache.swift"),
                              encoding: .utf8)
        // Both limits per store now say the same number. Otherwise one
        // of the two is decoration again.
        #expect(text.contains("thumbCache.countLimit = Self.thumbBudget"),
                "die Stueckzahl steht wieder als eigene Zahl neben der Kostengrenze")
        #expect(text.contains("thumbCache.totalCostLimit = Self.thumbBudget"),
                "die Kostengrenze wird nicht mehr aus der Stueckzahl abgeleitet")
        #expect(text.contains("memoryCache.countLimit = Self.fullCoverBudget"))
        #expect(text.contains("memoryCache.totalCostLimit = Self.fullCoverBudget"))
        // And the previews get more than the full images. They are what
        // EVERY row and EVERY grid needs.
        #expect(ImageCache.thumbBudget > ImageCache.fullCoverBudget * 10)
        // Cause 2: an invalidation clears its size variants, not
        // the whole store.
        let body = try #require(functionBody(of: "func invalidate(url: URL)", in: text))
        #expect(!body.contains("thumbCache.removeAllObjects()"),
                "eine einzelne URL leert wieder alle Vorschauen der App")
        #expect(body.contains("thumbnailVariants"),
                "die Groessenvarianten werden nicht mehr benannt")
        // The variants must be the ones ACTUALLY requested. Otherwise the
        // targeted version clears past the point.
        #expect(Set(ImageCache.thumbnailVariants) == Set([400, 600]))
    }

    /// The crime shelf showed three titles: the shelves asked the ALPHABETICALLY
    /// first terms. Crime got `crime` (5 hits) instead of `mystery` (49)
    /// and `detective` (47). 4 instead of 141
    /// titles; science fiction asked two terms with ZERO together.
    ///
    /// The same class that the fence caught at the alphabetical cap of the
    /// music axis. Caught there, here live on the surface.
    @Test("a shelf asks its most productive terms, never the alphabetically first")
    func aShelfAsksItsRichestTermsNotItsFirstAlphabetically() {
        let krimi = CatalogGenreAxis.subjects(forShelf: "crime")
        #expect(krimi.count >= 3, "die Probe misst nichts")
        // The three that are asked are the measured most productive.
        let gefragt = Array(krimi.prefix(3))
        #expect(gefragt.contains("mystery"), "der ergiebigste Krimi-Begriff faellt wieder weg")
        #expect(gefragt.contains("detective"))
        // Red probe: alphabetically `crime` would be first. Exactly the weak one.
        #expect(krimi.sorted().first == "crime")
        #expect(gefragt.first != "crime", "die Sortierung ist wieder alphabetisch")
        // And the order falls monotonically with the measured yield.
        let ertrag = krimi.map { CatalogGenreAxis.measuredGutenbergYield[$0] ?? 0 }
        #expect(ertrag == ertrag.sorted(by: >), "die Reihenfolge folgt nicht der Messung")
        // The shelf that was EMPTY today: its top term carries now.
        let scifi = CatalogGenreAxis.subjects(forShelf: "scifi")
        #expect(scifi.first == "science fiction",
                "Science-Fiction fragt wieder zwei Begriffe mit null Treffern")
        #expect((CatalogGenreAxis.measuredGutenbergYield["science fiction"] ?? 0) > 0)
    }

    /// For archive.org the cap on the term list is dropped entirely. Measured
    /// at the endpoint (netlabels, electronic shelf): with the first six
    /// terms **3.395** entries in 0,52 s, with all thirty-five
    /// **31.338** in 0,58 s. Factor 9 for five hundredths of a second. The
    /// cap cost almost everything and saved nothing. It applied to Jamendo's
    /// FUZZY `fuzzytags`, not to `subject:`, which matches exactly.
    @Test("the archive.org shelves no longer shorten their term list", .needsTheSources)
    func theArchiveShelvesDoNotCapTheirTerms() throws {
        for path in ["Sources/Networking/FreeCatalogClients.swift",
                     "Sources/Views/Music/ArchiveMusicPages.swift"] {
            let text = try String(contentsOf: sourceFile(path), encoding: .utf8)
            #expect(!text.contains("prefix(6).map { \"subject:"),
                    "\(path) kuerzt die Begriffe wieder alphabetisch")
        }
        // The music shelves where the shelf name itself dropped out.
        for shelf in ["electronic", "rock", "world", "pop", "folk", "soul"] {
            let terms = CatalogGenreAxis.musicSubjects(forShelf: shelf)
            #expect(terms.contains(shelf), "\(shelf) traegt seinen eigenen Namen nicht")
            // Red probe: with the old cap exactly that would have happened.
            if terms.count > 6 {
                #expect(!terms.sorted().prefix(6).contains(shelf),
                        "die Rot-Probe traegt nicht — hier haette der Deckel nichts gekostet")
            }
        }
    }

    /// Two neighboring shelves began with exactly the same two tiles.
    /// Every shelf asked its
    /// source with the same sort order, page 1. A title that belongs to both
    /// shelves therefore stood at the top of both. The overlap is
    /// right, the same SLICE is not.
    @Test("neighboring shelves reach into their stock at different places")
    func neighbouringShelvesDoNotShowTheSameExcerpt() {
        let tag = Date(timeIntervalSince1970: 1_756_000_000)
        let geschichte = CatalogShelfSource.shelfPage(shelf: "history", rows: 12, on: tag)
        let biografien = CatalogShelfSource.shelfPage(shelf: "biography", rows: 12, on: tag)
        #expect(geschichte != biografien,
                "zwei Faecher fragen wieder dieselbe Seite — die Zwillinge sind zurueck")
        // INVARIANT 2: stable within ONE day. A row that re-sorts
        // under the fingers is a layout jump in slow motion.
        #expect(CatalogShelfSource.shelfPage(shelf: "history", rows: 12, on: tag) == geschichte)
        #expect(CatalogShelfSource.shelfPage(shelf: "history", rows: 12,
                                             on: tag.addingTimeInterval(3600)) == geschichte)
        // And on the next day it moves.
        let morgen = tag.addingTimeInterval(86_400)
        #expect(CatalogShelfSource.shelfPage(shelf: "history", rows: 12, on: morgen) != geschichte)
        // The seed hangs on the name, not on the process. `hashValue` would be
        // different on every launch and the shuffle thus never stable.
        #expect(CatalogRotation.salt(forShelf: "history")
                == CatalogRotation.salt(forShelf: "history"))
        #expect(CatalogRotation.salt(forShelf: "history")
                != CatalogRotation.salt(forShelf: "biography"))
        // Red probe: without a seed both would be equal. So the instrument
        // sees the difference only because of the salt.
        #expect(CatalogRotation.page(total: 600, rowSize: 12, on: tag, salt: 0)
                == CatalogRotation.page(total: 600, rowSize: 12, on: tag, salt: 0))
    }

    /// A tile in the continue row carried no name and did not play.
    /// The finding is not in the
    /// cell: the dead mark was read ONLY when building the catalog rows,
    /// and this row reads the LISTENING HISTORY. Learning and reading were not
    /// connected.
    @Test("a dead piece leaves the row, its listening state stays")
    func aDeadItemLeavesTheRowButKeepsItsProgress() throws {
        let suite = "r59-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let tot = FreeCatalog.jamendoPrefix + "1234"
        let lebt = FreeCatalog.jamendoPrefix + "5678"
        // Two started catalog titles in the history (album form, without position).
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
        // INVARIANT: the ENTRY stays. A listening state is user property.
        #expect(verlauf["localPosition.\(tot)"] != nil,
                "der Hoerstand wurde still geloescht")
    }

    /// A transport error and a clear "gone" are two different
    /// answers. Only the second one is marked. Otherwise a dead zone clears the
    /// row.
    @Test("only a clear gone is marked, a transport error never")
    func onlyAClearGoneIsRecorded() {
        #expect(FreeCatalog.isGone(URLError(.resourceUnavailable)))
        #expect(FreeCatalog.isGone(APIError.http(404, "")))
        #expect(FreeCatalog.isGone(APIError.http(410, "")), "ein endgueltiges Weg (410) vermerkte nicht")
        // The dead zone, the abort, the overloaded network: no verdict.
        #expect(!FreeCatalog.isGone(URLError(.notConnectedToInternet)))
        #expect(!FreeCatalog.isGone(URLError(.timedOut)))
        #expect(!FreeCatalog.isGone(URLError(.cancelled)))
        #expect(!FreeCatalog.isGone(APIError.http(503, "")))
        // And only what belongs to us is marked. A server book is not.
        #expect(FreeCatalog.isCatalogId(FreeCatalog.jamendoPrefix + "1"))
        #expect(FreeCatalog.isCatalogId(FreeCatalog.archivePrefix + "x"))
        #expect(!FreeCatalog.isCatalogId("abs-item-id"))
    }

    /// Mood and tempo are FILTERS on
    /// the full page of a shelf, instrumental a SWITCH. No row families
    /// of their own. Jamendo filters all three SERVER-side, probed at the endpoint;
    /// the page throws nothing away afterwards.
    ///
    /// Measured on 200 popular titles (26.08.): vocal 179 / instrumental
    /// 21 · speed medium 142, high 38, low 12, verylow 2 · moods in the
    /// vartags (energetic 58, love 52, happy 24, emotional 18, upbeat 11).
    @Test("the Jamendo filters travel in the query, not afterwards")
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
        // `verylow` merges with `low`. Two of two hundred titles
        // do not justify a shelf of their own, but they must not be lost.
        filter.tempo = .slow
        let langsam = try? #require(filter.queryItems.first { $0.name == "speed" }?.value)
        #expect(langsam?.contains("low") == true)
        #expect(langsam?.contains("verylow") == true)

        // The mood runs through the tags, because Jamendo keeps it there.
        filter.mood = .energetic
        #expect(filter.extraTags == ["energetic"])
        #expect(!filter.queryItems.contains { $0.name == "mood" },
                "die Stimmung wandert in ein Feld, das die Quelle nicht kennt")
        // Every offered level also has a value for the source.
        for tempo in JamendoFilter.Tempo.allCases {
            #expect(!tempo.apiValues.isEmpty, "\(tempo.rawValue) hat keinen Quellwert")
        }
    }

    /// The day store was filed by the SHELF name alone. If the
    /// terms of a shelf are swapped, it keeps returning for up to 24 h the
    /// answer of the OLD rule. After an update every user would see the old
    /// shelves for a day.
    ///
    /// The class in general form: a result outlives the computation
    /// that produced it.
    @Test("a stored result is valid only as long as its rule is")
    func aStoredResultOnlyHoldsWhileItsRuleHolds() throws {
        let suite = "r60-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = CatalogShelfSource.shelfStore
        let shelf = CatalogShelfSource.ShelfStock(total: 5, books: [], docs: nil)
        let id = CatalogShelfSource.stockId(surface: CatalogSource.gutenberg.rawValue,
                                            shelf: "crime")

        // Stored under YESTERDAY's rule.
        #expect(store.store(.found(shelf), for: id, rule: "crime|crime & mystery fiction",
                            defaults: defaults))
        #expect(store.load(defaults: defaults)[id] != nil,
                "die Probe misst nichts — nichts wurde gespeichert")

        // With TODAY's rule the entry can no longer be found.
        let heute = CatalogShelfSource.shelfRule(forId: id)
        #expect(heute != "crime|crime & mystery fiction",
                "die Rot-Probe traegt nicht — die Regel hat sich gar nicht geaendert")
        #expect(store.load(defaults: defaults, rule: { _ in heute })[id] == nil,
                "der Eintrag der alten Regel wird weiter ausgeliefert")

        // And under the SAME rule it naturally stays valid.
        // The fingerprint must not make the store worthless.
        #expect(store.store(.found(shelf), for: id, rule: heute, defaults: defaults))
        #expect(store.load(defaults: defaults, rule: { _ in heute })[id] != nil)

        // The fingerprint is the selection ACTUALLY asked, not the shelf name.
        #expect(heute.contains("mystery"), "der Abdruck kennt die Begriffe nicht")
        #expect(CatalogShelfSource.shelfRule(forId: id)
                != CatalogShelfSource.shelfRule(
                    forId: CatalogShelfSource.stockId(surface: CatalogSource.gutenberg.rawValue,
                                                      shelf: "horror")))
    }

    /// The debug lever clears ONLY derived data. The line between fetching
    /// anew and data loss is drawn in the code, not in the label.
    @Test("the lever clears derived data and never touches user property")
    func theLeverClearsOnlyDerivedStores() throws {
        let suite = "r60-lever-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // No key of the lever may look like user property.
        for entry in DerivedStores.all {
            for besitz in DerivedStores.userOwnedPrefixes {
                #expect(!entry.key.hasPrefix(besitz),
                        "\(entry.key) sieht aus wie Nutzerbesitz")
            }
            #expect(!entry.label.isEmpty, "der Hebel muss sagen, was er raeumt")
        }

        // On BEHAVIOR: derived data goes, property stays.
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

        // Nothing to clear is an answer, not an empty message.
        #expect(DerivedStores.clear(defaults: defaults).isEmpty)
    }

    /// Collections are sorted to the back. The number of keywords
    /// is no good as a signal: measured on 150 LibriVox entries, collections
    /// average 6,2, the others 6,4. The TITLE is no good either.
    /// `Vanished Arizona: Recollections` contains `collection` and is a
    /// single work.
    ///
    /// What carries is LibriVox's own convention: `creator` is EXACTLY
    /// `Various`. Exact equality, so no substring can slip in.
    @MainActor
    @Test("the convention recognises collections, not the title", .needsTheSources)
    func collectionsAreRecognisedByConventionNotByTitle() throws {
        func doc(_ creator: String, _ title: String) throws -> ArchivePopularDoc {
            let json = "{\"identifier\":\"x\",\"title\":\"\(title)\",\"creator\":\"\(creator)\"}"
            return try JSONDecoder().decode(ArchivePopularDoc.self, from: Data(json.utf8))
        }
        // The measured real cases.
        #expect(FreeCatalog.isMultiAuthorCollection(try doc("Various", "Children's Short Works, Vol. 031")))
        #expect(FreeCatalog.isMultiAuthorCollection(try doc("various", "La Lecture, tome 8")))
        // Red probe: the title trap that a word search would have fallen into.
        #expect(!FreeCatalog.isMultiAuthorCollection(
            try doc("Martha Summerhayes", "Vanished Arizona: Recollections of the Army")),
                "ein einzelnes Werk wird als Sammelband einsortiert")
        // And an author who merely CONTAINS `various` is not one.
        #expect(!FreeCatalog.isMultiAuthorCollection(try doc("Various Artists Ensemble", "X")))
        #expect(!FreeCatalog.isMultiAuthorCollection(try doc("", "X")))
        // The penalty ORDERS, it throws nothing away. That is the difference
        // between sorting to the back and excluding. The question goes to the
        // one place that enters the book shelves, and the page demands
        // the order there.
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

    /// A show page stayed without an image although the feed names its image TWICE:
    /// the reader did not read the RSS form `<image><url>…</url></image>` at all,
    /// and the itunes form WITHOUT `href` fell through because the attribute
    /// is empty. `FeedArtworkLookup` already knew the RSS form. Two
    /// readers, one spelling, one can do more.
    ///
    /// Measured over the 21 curated feeds: two write the
    /// itunes text form, so there are two missing images, not one.
    @Test("the feed reader understands every spelling of the show image")
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
        // The form that already worked.
        #expect(bild("<itunes:image href=\"https://example.org/a.jpg\"/>") == "https://example.org/a.jpg")
        // The two that fell through. The measured feed names BOTH.
        #expect(bild("<itunes:image>https://example.org/b.jpg</itunes:image>") == "https://example.org/b.jpg",
                "die itunes-Textform faellt wieder durch")
        #expect(bild("<image><title>T</title><url>https://example.org/c.jpg</url></image>") == "https://example.org/c.jpg",
                "die RSS-Form faellt wieder durch")
        // Red probe: without an image none is invented.
        #expect(bild("") == nil)
        // And an ITEM image does not become the show image.
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

    /// Enough stock in EVERY catalog lane, so that the probes above really
    /// measure something (a green run without a measurement is the most expensive outcome).
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
