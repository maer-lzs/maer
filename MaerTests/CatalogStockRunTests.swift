// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// GT-21: a stock run that is interrupted loses at most a slice and says so,
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
        #expect(CatalogStockSurfaces.known(inDirectoryNamed: []).isEmpty, "nothing opened, nothing starts")
    }

    // MARK: - The unfinished dump on the disk

    @Test("Teilstueck: es liegt auf der Platte, waechst je Scheibe, nennt seine Groesse und verschwindet am Ende")
    func thePartialDumpLivesOnTheDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let partial = CatalogStockFetch.DumpPartial(surface: "gutenberg", directory: folder)
        #expect(partial.load().body.isEmpty && partial.load().total == nil, "a first run starts at zero")
        try partial.append(Data("id,title\n".utf8), total: 21_196_613)
        try partial.append(Data("1,Alice\n".utf8), total: 21_196_613)
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

    // MARK: - Wiring

    @Test("Verdrahtung: der Dump liest das Teilstueck, schreibt jede Scheibe, und beide Wege reichen es")
    func theDumpIsWired() throws {
        let fetch = try Self.source("Sources/Networking/CatalogStockFetch.swift")
        #expect(fetch.contains("var (body, knownTotal) = partial?.load() ?? (Data(), nil)"))
        let append = try #require(fetch.range(of: "try partial?.append(data, total: knownTotal)"))
        let grow = try #require(fetch.range(of: "body.append(data)"))
        #expect(grow.lowerBound < append.lowerBound, "each slice kept on the disk as it arrives")
        let service = try Self.source("Sources/ViewModels/CatalogStockService.swift")
        #expect(service.components(separatedBy: "CatalogStockFetch.gutenbergStock(partial: .init(surface: surface))").count - 1 == 2,
                "the first run AND the refresh continue what was reached")
        #expect(service.contains("Logger.library.notice(\"STOCK \\(surface, privacy: .public) run cancelled"),
                "a cancelled run says so in the log")
    }

    @Test("Verdrahtung: die Laeufe starten mit der App, ausser im Test-Wirt")
    @MainActor
    func theRunsStartWithTheApp() throws {
        let housekeeping = try Self.source("Sources/ViewModels/AppHousekeeping.swift")
        #expect(housekeeping.contains("if !Self.catalogRunsMustStaySilent { Task { await CatalogStockService.shared.resumeKnownRuns() } }"))
        #expect(AppHousekeeping.catalogRunsMustStaySilent, "this very suite is the test host")
    }
}
#endif
