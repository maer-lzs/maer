// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// Der Gutenberg-Abzug gegen seine ECHTEN Bytes: ein Ausschnitt aus
/// `pg_catalog.csv`, so wie der Dienst ihn liefert, mit CRLF am Zeilenende
/// und einem Zeilenumbruch in einem Feld. Ein Swift-Literal verliert genau
/// das Unsichtbare; der Leser las die ganze Datei als eine Zeile.
struct GutenbergDumpTests {
    static func excerpt() throws -> Data {
        try CorpusFixture.data("pg_catalog-excerpt", ext: "csv", subdirectory: "GutenbergDump")
    }

    @Test("Der Abzug mit CRLF wird Zeile fuer Zeile gelesen, ein Zeilenumbruch im Feld bleibt im Feld")
    func theRealBytesAreRead() throws {
        let data = try Self.excerpt()
        let text = try #require(String(data: data, encoding: .utf8))
        try #require(data.count == 4586, "the fixture is the cut of the real file")
        try #require(text.utf8.split(separator: 10).count > 10 && data.contains(Data("\r\n".utf8)),
                     "the fixture carries CRLF, else the case measures nothing")
        let rows = CatalogStockFetch.csvRows(text)
        #expect(rows.count == 16, "header and fifteen records")
        #expect(rows.allSatisfy { $0.count == 9 }, "every record has the nine columns of the header")
        let mersenne = try #require(rows.first { $0.first == "69" })
        #expect(mersenne[3] == "The 32nd Mersenne Prime\nPredicted by Mersenne",
                "the newline inside the quoted title stays in the title")
        let works = CatalogStockFetch.gutenbergEntries(fromCSV: text)
        #expect(works.map(\.id) == ["gut:3002", "gut:5884"], "the two audio works of the cut")
        #expect(works.first?.title == "Society's Child (audiofile)")
    }

    /// A wire that answers the dump by its Range header, `chunk` bytes at a
    /// time, naming the total it is given; a changed total models a file
    /// that is rewritten upstream while it is fetched.
    final class DumpWire: Sendable {
        let file: Data
        let chunk: Int
        private let state: Mutex<(totals: [Int], requests: Int)>

        init(file: Data, chunk: Int, totals: [Int] = []) {
            self.file = file
            self.chunk = chunk
            state = Mutex((totals, 0))
        }

        var requests: Int {
            get { state.withLock { $0.requests } }
            set { state.withLock { $0.requests = newValue } }
        }

        func answer(_ request: URLRequest) -> (Data, HTTPURLResponse?) {
            let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
            let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "0") ?? 0
            let total = state.withLock { held -> Int in
                held.requests += 1
                return held.totals.isEmpty ? file.count : held.totals.removeFirst()
            }
            let url = request.url!
            guard start < file.count else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 416, httpVersion: nil, headerFields: [:]))
            }
            let end = min(start + chunk, file.count)
            let body = file.subdata(in: start..<end)
            let headers = ["Content-Range": "bytes \(start)-\(end - 1)/\(total)"]
            return (body, HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: headers))
        }
    }

    private func partial() throws -> (CatalogStockFetch.DumpPartial, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gutenberg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (CatalogStockFetch.DumpPartial(surface: "gutenberg", directory: folder), folder)
    }

    @Test("I1: das Teilstueck bleibt nach dem Lesen stehen, und ein zweiter Lauf liest es von der Platte statt neu zu holen")
    func theFileStaysUntilTheStockStands() async throws {
        let file = try Self.excerpt()
        let (partial, folder) = try partial()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = DumpWire(file: file, chunk: 2000)
        let first = try await CatalogStockFetch.gutenbergStock(partial: partial) { wire.answer($0) }
        #expect(first.count == 2)
        #expect(wire.requests == 3, "three slices of 2000 bytes for 4586")
        #expect(partial.load().body == file, "the whole file stays on the disk until the stock is written")

        // The app ended before the stock was written: the next run reads the
        // disk, asks once past the end, and fetches no byte again.
        wire.requests = 0
        let again = try await CatalogStockFetch.gutenbergStock(partial: partial) { wire.answer($0) }
        #expect(again.map(\.id) == first.map(\.id))
        #expect(wire.requests == 1, "one question past the end (416), no slice fetched again")
    }

    /// The lever that empties the derived stocks, pulled while a dump runs:
    /// what lies on the disk afterwards must never be the tail of the file
    /// without its head, else a run after a restart splices it.
    @Test("der Hebel mitten im Abruf: auf der Platte liegt danach nie das Ende ohne den Anfang")
    func theLeverMidRunLeavesNoHeadlessTail() async throws {
        let file = try Self.excerpt()
        let (partial, folder) = try partial()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = DumpWire(file: file, chunk: 2000)
        let works = try await CatalogStockFetch.gutenbergStock(partial: partial) { request in
            // Before the second slice: the first lies on the disk, the lever runs.
            if wire.requests == 1 { CatalogStockStore.shared.clear(in: folder) }
            return wire.answer(request)
        }
        #expect(works.count == 2, "the run in memory finishes")
        let held = partial.load().body
        #expect(held.isEmpty || held == file, "the disk holds \(held.count) of \(file.count) bytes, not from the start")
    }

    /// The lever over a folder with an unfinished dump and its counters:
    /// nothing of a stock stays, and what went is said.
    @Test("der Hebel nimmt angefangene Abrufe samt Zaehlern mit")
    func theLeverTakesUnfinishedDumps() async throws {
        let (partial, folder) = try partial()
        defer { try? FileManager.default.removeItem(at: folder) }
        try partial.append(Data("head".utf8), after: 0, total: 4586)
        _ = try partial.noteEmptyRead()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(before.count == 3, "the precondition: the dump, its total and its count: \(before)")
        CatalogStockStore.shared.clear(in: folder)
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(after.isEmpty, "left after the lever: \(after)")
    }

    @Test("I1: eine Datei, die sich zwischen zwei Scheiben oben aendert, faengt neu an und wird fertig")
    func aFileRewrittenUpstreamStartsOverAndFinishes() async throws {
        let file = try Self.excerpt()
        let (partial, folder) = try partial()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The first slice names an older, smaller total; the second the real
        // one, so the run notices the change and starts over.
        let wire = DumpWire(file: file, chunk: 2000, totals: [3000, file.count])
        let works = try await CatalogStockFetch.gutenbergStock(partial: partial) { wire.answer($0) }
        #expect(works.map(\.id) == ["gut:3002", "gut:5884"], "the run that started over finished with the whole file")
        #expect(wire.requests == 5, "one slice, the slice that names the change, then three slices of the file as it is now")
    }

    @Test("I2: eine ganze Datei ohne ein einziges Werk scheitert laut, bleibt einmal fuer den naechsten Lauf und geht beim zweiten leeren Lesen")
    func aFileWithoutAWorkFailsAloud() async throws {
        let (partial, folder) = try partial()
        defer { try? FileManager.default.removeItem(at: folder) }
        let noAudio = Data("Text#,Type,Issued,Title,Language,Authors,Subjects,LoCC,Bookshelves\r\n1,Text,1971-12-01,A,en,,,,\r\n".utf8)
        let wire = DumpWire(file: noAudio, chunk: 4096)
        await #expect(throws: (any Error).self) {
            _ = try await CatalogStockFetch.gutenbergStock(partial: partial) { wire.answer($0) }
        }
        #expect(partial.load().body == noAudio, "the file stays; the next run reads it again without a fetch")
        #expect(partial.emptyReads() == 1)

        // The second empty read: the file itself is broken, and it goes.
        wire.requests = 0
        await #expect(throws: (any Error).self) {
            _ = try await CatalogStockFetch.gutenbergStock(partial: partial) { wire.answer($0) }
        }
        #expect(wire.requests == 1, "read from the disk, one question past the end")
        #expect(partial.load().body.isEmpty && partial.emptyReads() == 0,
                "a file that never gives a work does not hold the stock back for good")

        // The run after that fetches the file anew.
        wire.requests = 0
        await #expect(throws: (any Error).self) {
            _ = try await CatalogStockFetch.gutenbergStock(partial: partial) { wire.answer($0) }
        }
        #expect(wire.requests == 1, "fetched again from the start: \(wire.requests)")
        #expect(partial.load().body == noAudio, "the new copy is on the disk again")
    }

    @Test("Gutenberg-Regale antworten aus dem Bestand, mit gut:-Titeln, nie mit archive-Titeln")
    @MainActor
    func gutenbergShelvesAnswerFromTheStockWithGutenbergTitles() throws {
        let shelf = try #require(CatalogGenreAxis.librivoxShelves.first).key
        let term = try #require(CatalogGenreAxis.subjects(forShelf: shelf).first)
        func stock(_ surface: String, id: String) -> CatalogStock {
            var held = CatalogStock(surface: surface, takenAt: 1, watermark: nil, entries: [
                CatalogStockEntry(id: id, title: "A Work", creator: nil, subjects: [term],
                                  downloads: 10, licenseurl: nil, year: nil),
            ])
            held.popularityComplete = true
            return held
        }
        let gutenberg = stock("gutenberg", id: "gut:3002")
        // Both ways in, the shelf and the browse page, through the one
        // conversion the page uses.
        for answer in [CatalogShelfSource.localShelf(surface: "gutenberg", shelf: shelf, rows: 12, stock: gutenberg),
                       CatalogShelfSource.localBrowse(rows: 12, stock: gutenberg, source: .gutenberg)] {
            let items = try #require(CatalogShelfEntries.shelf(answer, source: .gutenberg, collectionsLast: true)).items
            #expect(items.map(\.id) == ["gut:3002"], "a Gutenberg title, never lva:gut: \(items.map(\.id))")
        }
        let librivox = stock("librivox", id: "librivox-work")
        let archive = try #require(CatalogShelfEntries.shelf(
            CatalogShelfSource.localShelf(surface: "librivox", shelf: shelf, rows: 12, stock: librivox),
            source: .librivox)).items
        #expect(archive.map(\.id) == ["lva:librivox-work"], "an archive entry keeps its prefix")
    }

    @Test("I2: jeder Ausgang von ensureStock und ein leeres Ende von finish schreiben eine Zeile; das Teilstueck geht erst nach dem Bestand", .needsTheSources)
    func everyEndSaysWhy() throws {
        let service = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/CatalogStockService.swift"), encoding: .utf8))
        let ensure = try #require(functionBody(of: "func ensureStock(surface: String, archiveQuery: String?) async {", in: service))
        // The host's rest after a refusal is no exit of `ensureStock` any
        // more: the run waits in the courtesy gate, which writes
        // `COURTESY rest` itself.
        #expect(!ensure.contains("host recently refused"))
        for line in ["is running already", "waits: failed",
                     "asks about cellular", "STOCK load surface="] {
            #expect(ensure.contains(line), "ensureStock says: \(line)")
        }
        let finish = try #require(functionBody(of: "private func finish(surface: String, entries: [CatalogStockEntry],", in: service))
        #expect(finish.contains("run ended with no entries"))
        #expect(service.contains("if try finish(surface: surface, entries: entries, previous: nil) { partial.reset() }"),
                "the unfinished file goes only after the stock stands")
        let fetch = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/CatalogStockFetch.swift"), encoding: .utf8))
        // The function reaches to the next declaration of the enum: its head
        // carries the default `wire` closure, so the first brace is not the body.
        let start = try #require(fetch.range(of: "static func gutenbergStock("))
        let end = try #require(fetch.range(of: "static func dumpChangedUpstream(", range: start.upperBound..<fetch.endIndex))
        let stock = fetch[start.upperBound..<end.lowerBound]
        let resets = stock.components(separatedBy: "partial?.reset()").count - 1
        #expect(resets == 4, "only the starts over reset the file: shrank, changed upstream, not UTF-8, empty twice")
    }
}
#endif
