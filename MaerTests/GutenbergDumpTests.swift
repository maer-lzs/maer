// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// The Gutenberg dump against its REAL bytes: an excerpt of
/// `pg_catalog.csv` as the service delivers it, with CRLF at the line end
/// and a line break inside a field. A Swift literal loses exactly
/// the invisible part; the reader read the whole file as one line.
struct GutenbergDumpTests {
    static func excerpt() throws -> Data {
        try CorpusFixture.data("pg_catalog-excerpt", ext: "csv", subdirectory: "GutenbergDump")
    }

    @Test("The dump with CRLF is read line by line, a line break inside a field stays inside the field")
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

    @Test("the partial piece stays after reading, and a second run reads it from disk instead of fetching it again")
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
    @Test("the lever in the middle of a fetch: afterwards the disk never holds the end without the beginning")
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

    /// Once a slice was refused, the run goes on from memory and leaves the
    /// disk alone: a later slice neither empties the file again nor says so
    /// again. A mark put on the disk after the refusal outlives the run.
    @Test("after a refused slice the fetch leaves the disk alone, one line instead of one per slice")
    func aRefusedSliceLeavesTheDiskAloneAfterwards() async throws {
        let file = try Self.excerpt()
        let (partial, folder) = try partial()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wire = DumpWire(file: file, chunk: 2000)
        let works = try await CatalogStockFetch.gutenbergStock(partial: partial) { request in
            // Before the second slice the lever runs, so that slice is refused;
            // before the third a mark lies where the file was.
            if wire.requests == 1 { CatalogStockStore.shared.clear(in: folder) }
            if wire.requests == 2 { try partial.append(Data("mark".utf8), after: 0, total: nil) }
            return wire.answer(request)
        }
        #expect(works.count == 2, "the run in memory finishes")
        #expect(wire.requests == 3, "the precondition: three slices of 2000 bytes for 4586")
        let held = String(decoding: partial.load().body, as: UTF8.self)
        #expect(held == "mark", "a slice after the refusal touched the disk again: \(held.count) bytes")
    }

    /// The lever over a folder with an unfinished dump and its counters:
    /// nothing of a stock stays, and what went is said.
    @Test("the lever takes unfinished fetches along with their counters")
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

    @Test("a file that changes upstream between two slices starts over and finishes")
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

    @Test("a whole file without a single work fails loudly, stays once for the next run and goes at the second empty read")
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

    @Test("Gutenberg shelves answer from the stock, with gut: titles, never with archive titles")
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

    @Test("every exit of ensureStock and an empty end of finish write one line; the partial piece goes only after the stock", .needsTheSources)
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
