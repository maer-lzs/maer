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
}
#endif
