// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A stock run that is interrupted loses at most a slice and says so,
/// and the runs start with the app for every collection this device holds.
struct CatalogStockRunTests {
    private static func squeezed(_ raw: String) -> String {
        SyncContractFenceTests.stripped(raw)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return squeezed(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
    }

    // MARK: - Which run a surface has

    @Test("Laeufe: jede Flaeche mit Bestand hat ihren Lauf aus dem Schluessel allein, wie die Seiten ihn geben")
    func everySurfaceHasItsRun() throws {
        #expect(CatalogStockSurfaces.fetch(for: CatalogSource.gutenberg.rawValue) == .dump)
        for source in [CatalogSource.librivox, .archiveBooks, .oldTimeRadio] {
            let query = try #require(ArchiveOrgClient.archiveBaseQuery(for: source))
            #expect(CatalogStockSurfaces.fetch(for: source.rawValue) == .archive(query), "\(source)")
        }
        for area in ArchiveMusicCatalog.all {
            #expect(CatalogStockSurfaces.fetch(for: area.key) == .archive(area.query), "\(area.key)")
        }
        // A feed-based source has no stock, and an unknown key none either:
        // never the dump by default (a nil query MEANS the dump there).
        #expect(CatalogStockSurfaces.fetch(for: CatalogSource.oerr.rawValue) == nil)
        #expect(CatalogStockSurfaces.fetch(for: "somethingElse") == nil)
    }

    @Test("Laeufe: nur eine Quelle, die an ist, wird beim Start gefragt")
    func onlyAnAllowedSourceRuns() {
        let everything: (ExternalSource) -> Bool = { _ in true }
        #expect(CatalogStockSurfaces.mayRun(surface: "gutenberg", allowed: everything))
        #expect(!CatalogStockSurfaces.mayRun(surface: "gutenberg", allowed: { $0.key != ExternalSources.gutenberg.key }))
        #expect(!CatalogStockSurfaces.mayRun(surface: "librivox", allowed: { $0.key != ExternalSources.internetArchive.key }),
                "the librivox stock comes from archive.org")
        #expect(CatalogStockSurfaces.mayRun(surface: "librivox", allowed: { $0.key != ExternalSources.gutenberg.key }))
    }

    @Test("Laeufe: der Start kennt jede Sammlung mit Bestand oder Teilstueck, und nur sie")
    func theStartKnowsWhatIsHeld() {
        let names = ["librivox.json", "gutenberg" + CatalogStockFetch.partialSuffix,
                     "gutenberg" + CatalogStockFetch.partialSuffix + ".total",
                     "netlabels.json", "archiveBooks.json.corrupt", ".DS_Store"]
        #expect(CatalogStockSurfaces.known(inDirectoryNamed: names) == ["gutenberg", "librivox", "netlabels"])
        #expect(CatalogStockSurfaces.known(inDirectoryNamed: []).isEmpty, "nothing held on this device")
    }

    @Test("Laeufe: der Start faehrt jede Sammlung mit Lauf, die gehaltenen zuerst, jede einmal")
    func theStartRunsEveryCollection() throws {
        let all = CatalogStockSurfaces.all
        #expect(all.count == 4 + ArchiveMusicCatalog.all.count && ArchiveMusicCatalog.all.count == 11,
                "oldTimeRadio, librivox, archiveBooks, gutenberg and eleven music shelves: \(all)")
        #expect(all.allSatisfy { CatalogStockSurfaces.fetch(for: $0) != nil }, "every one has a run")
        #expect(Set(all).count == all.count)
        #expect(!all.contains(CatalogSource.oerr.rawValue), "a feed-based row has no stock")
        let order = CatalogStockSurfaces.startOrder(known: ["netlabels", "gutenberg"], all: ["gutenberg", "librivox", "netlabels"])
        #expect(order == ["netlabels", "gutenberg", "librivox"], "held first, then the rest, each once")
        #expect(CatalogStockSurfaces.startOrder(known: [], all: all) == all, "a fresh device runs every collection")
        let service = try Self.source("Sources/ViewModels/CatalogStockService.swift")
        #expect(service.contains("let surfaces = CatalogStockSurfaces.startOrder(known: CatalogStockSurfaces.known(inDirectoryNamed: listed))"))
        #expect(service.contains("guard CatalogStockSurfaces.mayRun(surface: surface, allowed: allowed) else {"),
                "a source that is off is still not asked")
    }

    @Test("Gutenberg: zwischen zwei vollen Laeufen kein Lauf, Tag 30 voll; ein Archiv fragt taeglich nach Neuem")
    func gutenbergRunsOnlyWhole() throws {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_756_900_000)
        let taken = now.timeIntervalSince1970 - 60
        func stock(_ daysAgo: Double) -> CatalogStock {
            CatalogStock(surface: "gutenberg", takenAt: taken - daysAgo * day, watermark: nil, entries: [])
        }
        for daysAgo in [0.0, 1, 2, 15, 29] {
            #expect(!CatalogStockRules.needsRun(stock(daysAgo), isDump: true, now: now), "day \(daysAgo): no run")
            #expect(CatalogStockRules.loadVerdict(stock(daysAgo), isDump: true, now: now) == "ready")
        }
        #expect(CatalogStockRules.needsRun(stock(30), isDump: true, now: now), "day 30: the full run")
        #expect(CatalogStockRules.loadVerdict(stock(30), isDump: true, now: now) == "full")
        #expect(CatalogStockRules.needsRun(stock(1), isDump: false, now: now), "an archive asks for what is new after a day")
        #expect(CatalogStockRules.loadVerdict(stock(1), isDump: false, now: now) == "delta")
        #expect(!CatalogStockRules.needsRun(stock(0), isDump: false, now: now))
        // The service asks the one rule, and the dump has no path to a
        // daily fetch any more.
        let service = try Self.source("Sources/ViewModels/CatalogStockService.swift")
        #expect(service.contains("if let kept, !CatalogStockRules.needsRun(kept, isDump: archiveQuery == nil) {"))
        #expect(service.contains("guard let archiveQuery else { states[surface] = .ready(kept.entries.count) return }"))
        #expect(service.components(separatedBy: "CatalogStockFetch.gutenbergStock(").count - 1 == 1,
                "the dump is fetched in exactly one place, the whole fetch")
    }

    // MARK: - The unfinished dump on the disk

    @Test("Teilstueck: es liegt auf der Platte, waechst je Scheibe, nennt seine Groesse und verschwindet am Ende")
    func thePartialDumpLivesOnTheDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let partial = CatalogStockFetch.DumpPartial(surface: "gutenberg", directory: folder)
        #expect(partial.load().body.isEmpty && partial.load().total == nil, "a first run starts at zero")
        try partial.append(Data("id,title\n".utf8), after: 0, total: 21_196_613)
        try partial.append(Data("1,Alice\n".utf8), after: 9, total: 21_196_613)
        let held = partial.load()
        #expect(String(decoding: held.body, as: UTF8.self) == "id,title\n1,Alice\n", "slices append in order")
        #expect(held.total == 21_196_613)
        #expect(partial.data.lastPathComponent == "gutenberg" + CatalogStockFetch.partialSuffix)
        partial.reset()
        #expect(partial.load().body.isEmpty && partial.load().total == nil)
    }

    @Test("Teilstueck: ein Dump, der sich dazwischen aenderte, beginnt von vorn")
    func aChangedDumpStartsOver() {
        #expect(CatalogStockFetch.dumpChangedUpstream(held: 4_194_304, known: 21_196_613, stated: 21_200_000))
        #expect(!CatalogStockFetch.dumpChangedUpstream(held: 4_194_304, known: 21_196_613, stated: 21_196_613))
        #expect(!CatalogStockFetch.dumpChangedUpstream(held: 0, known: 21_196_613, stated: 21_200_000), "nothing held, nothing to splice")
        #expect(!CatalogStockFetch.dumpChangedUpstream(held: 4_194_304, known: nil, stated: 21_200_000))
    }

    @Test("Teilstueck: eine 416 auf ein fortgesetztes Teilstueck heisst geschrumpft, ausser es ist das ganze")
    func a416OnAResumedDumpIsAShrunkenFile() throws {
        #expect(CatalogStockFetch.dumpShrankUnderResume(resumed: true, held: 8_388_608, known: 21_223_958),
                "held the head of a longer file that is now shorter than that head")
        #expect(!CatalogStockFetch.dumpShrankUnderResume(resumed: true, held: 21_223_958, known: 21_223_958),
                "the app died after the last slice: it is whole")
        #expect(!CatalogStockFetch.dumpShrankUnderResume(resumed: false, held: 8_388_608, known: 21_223_958),
                "within one run a 416 is the end, as before")
        #expect(CatalogStockFetch.dumpShrankUnderResume(resumed: true, held: 4_194_304, known: nil),
                "held without a known total: start over rather than trust it")
        let fetch = try Self.source("Sources/Networking/CatalogStockFetch.swift")
        let ask = try #require(fetch.range(of: "if dumpShrankUnderResume(resumed: resumed, held: body.count, known: knownTotal) {"))
        let end = try #require(fetch.range(of: "break } throw APIError.http(http.statusCode, \"\")"))
        #expect(ask.lowerBound < end.lowerBound, "asked before the 416 is taken as the end")
        #expect(fetch.contains("body.append(data) resumed = false"), "a slice from the service ends the resumed state")
    }

    // MARK: - Wiring

    @Test("Verdrahtung: der Dump liest das Teilstueck, schreibt jede Scheibe, und sein einziger Weg reicht es")
    func theDumpIsWired() throws {
        let fetch = try Self.source("Sources/Networking/CatalogStockFetch.swift")
        #expect(fetch.contains("var (body, knownTotal) = partial?.load() ?? (Data(), nil)"))
        let append = try #require(fetch.range(of: "try !partial.append(data, after: held, total: knownTotal)"))
        let grow = try #require(fetch.range(of: "body.append(data)"))
        #expect(grow.lowerBound < append.lowerBound, "each slice kept on the disk as it arrives")
        let service = try Self.source("Sources/ViewModels/CatalogStockService.swift")
        // One way since the dump stopped running daily: the whole fetch,
        // which the first run and the thirty-day run both take.
        #expect(service.components(separatedBy: "CatalogStockFetch.gutenbergStock(partial: partial)").count - 1 == 1,
                "the whole fetch continues what was reached")
        #expect(service.contains("Logger.library.notice(\"STOCK \\(surface, privacy: .public) run cancelled"),
                "a cancelled run says so in the log")
    }

    @Test("Verdrahtung: die Laeufe starten mit der App, ausser im Test-Wirt")
    @MainActor
    func theRunsStartWithTheApp() throws {
        let housekeeping = try Self.source("Sources/ViewModels/AppHousekeeping.swift")
        #expect(housekeeping.contains("if !Self.catalogRunsMustStaySilent { Task { await CatalogStockService.shared.startRuns() } }"))
        #expect(AppHousekeeping.catalogRunsMustStaySilent, "this very suite is the test host")
    }
}
#endif
