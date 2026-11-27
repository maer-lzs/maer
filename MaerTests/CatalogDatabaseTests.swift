// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// The catalogue rows live in their own database: shown at start without a
/// network, replaced only whole, kept through a failure or a cancel, and
/// fetched in parallel.
@MainActor
struct CatalogDatabaseTests {
    static func item(_ id: String, title: String = "T") -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(metadata: LibraryItemMetadata(title: title, authorName: nil, narratorName: nil, seriesName: nil, genres: nil, publishedYear: nil, description: nil), duration: nil,
                                                    chapters: nil, tracks: nil),
                    addedAt: nil)
    }

    /// One second, then the value: a row that takes its time.
    nonisolated static func slow<T: Sendable>(_ value: T) async throws -> T {
        try await Task.sleep(for: .seconds(1))
        return value
    }

    static func memoryStore() async throws -> (CatalogRowStore, SQLiteConnection) {
        let connection = try SQLiteConnection(path: ":memory:")
        return (try await CatalogRowStore(connection: connection), connection)
    }

    @Test("the catalogue family is version one, and a second start creates nothing twice")
    func family() async throws {
        let (_, connection) = try await Self.memoryStore()
        _ = try await CatalogRowStore(connection: connection)
        #expect(try await connection.schemaVersion(of: CatalogRowStore.family) == 1)
        let tables = try await connection.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'catalog_%' ORDER BY name")
        #expect(tables.compactMap { $0["name"]?.string } == ["catalog_reihe", "catalog_row"])
    }

    @Test("a row is replaced whole, in its order")
    func replaceWhole() async throws {
        let (store, _) = try await Self.memoryStore()
        try await store.replace(.classical, items: [Self.item("lva:a"), Self.item("lva:b")], atMs: 1)
        #expect(try await store.rows()[.classical]?.map(\.id) == ["lva:a", "lva:b"])
        try await store.replace(.classical, items: [Self.item("lva:c")], atMs: 2)
        #expect(try await store.rows()[.classical]?.map(\.id) == ["lva:c"])
        #expect(try await store.rows()[.classical]?.first?.title == "T", "the tile lost its content")
    }

    @Test("a failure is noted and the row stays")
    func failureKeeps() async throws {
        let (store, _) = try await Self.memoryStore()
        try await store.replace(.gutenberg, items: [Self.item("gut:1")], atMs: 1)
        try await store.noteFailure(.gutenberg, reason: "offline", atMs: 2)
        #expect(try await store.rows()[.gutenberg]?.map(\.id) == ["gut:1"])
        #expect(try await store.failures()[.gutenberg] == "offline")
    }

    @Test("Fence: the rows are written in one place, each in one transaction", .needsTheSources)
    func onePlace() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        for file in files where !file.hasSuffix("CatalogRowStore.swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("catalog_row"), "\(file) touches the catalogue rows")
        }
        let store = try String(contentsOf: sources.appendingPathComponent("Storage/CatalogRowStore.swift"), encoding: .utf8)
        let replace = try #require(store.range(of: "func replace("))
        #expect(store[replace.upperBound...].prefix(1_200).contains("connection.transaction("))
    }

    @Test("a failed, a cancelled and a switched-off row: the first two keep the last state, the third is empty")
    func keep() {
        var previous = FreeCatalogLoader.Rows()
        previous.classical = [Self.item("lva:a")]
        previous.netlabels = [Self.item("lva:n")]
        previous.musopen = [Self.item("mso:1")]
        var loaded = FreeCatalogLoader.Rows()
        loaded.problems[.classical] = "offline"
        let merged = CatalogRowKeep.merge(previous: previous, loaded: loaded, enabled: [.classical, .netlabels])
        #expect(merged.classical.map(\.id) == ["lva:a"], "a failure emptied the row")
        #expect(merged.problems[.classical] == "offline")
        #expect(merged.netlabels.map(\.id) == ["lva:n"], "a cancel emptied the row")
        #expect(merged.musopen.isEmpty, "a switched-off row still shows")
    }

    @Test("Jamendo never goes into the database: its terms forbid keeping")
    func noJamendo() {
        var rows = FreeCatalogLoader.Rows()
        rows.freeMusic = [Self.item("jam:1")]
        rows.classical = [Self.item("lva:a")]
        let written = CatalogRowKeep.written(rows)
        #expect(written[.classical]?.map(\.id) == ["lva:a"])
        #expect(!written.values.joined().contains { $0.id.hasPrefix(FreeCatalog.jamendoPrefix) })
        #expect(!CatalogRowStore.Key.allCases.contains { $0.rawValue.contains("jamendo") || $0.rawValue.contains("free") })
    }

    @Test("cold start without a network: the rows of the database show, no fetch runs")
    func coldStartOffline() async throws {
        let (rowStore, _) = try await Self.memoryStore()
        try await rowStore.replace(.classical, items: [Self.item("lva:a")], atMs: 1)
        try await rowStore.replace(.gutenberg, items: [Self.item("gut:1")], atMs: 1)
        let store = FreeCatalogStore(rowStore: { rowStore }, online: { false },
                                     loadRows: { Issue.record("a fetch ran offline"); return FreeCatalogLoader.Rows() },
                                     loadSources: { _ in Issue.record("a fetch ran offline"); return CatalogSourceLoader.SourceRows() },
                                     enabledRows: { [.classical] })
        await store.restore()
        #expect(store.storedRows.classical.map(\.id) == ["lva:a"])
        #expect(store.storedSourceRows.gutenberg.map(\.id) == ["gut:1"])
        _ = store.rows
        _ = store.sourceRows
    }

    @Test("a fetch that fails keeps the rows of the database and notes the failure; one that succeeds writes them")
    func fetchKeepsAndWrites() async throws {
        let (rowStore, _) = try await Self.memoryStore()
        try await rowStore.replace(.classical, items: [Self.item("lva:a")], atMs: 1)
        try await rowStore.replace(.gutenberg, items: [Self.item("gut:1")], atMs: 1)
        var failing = FreeCatalogLoader.Rows()
        failing.problems[.classical] = "offline"
        failing.netlabels = [Self.item("lva:n")]
        var sources = CatalogSourceLoader.SourceRows()
        sources.failures[.gutenberg] = "offline"
        sources.oldTimeRadio = [Self.item("lva:o")]
        let answer = sources
        let store = FreeCatalogStore(rowStore: { rowStore }, online: { true },
                                     loadRows: { failing }, loadSources: { _ in answer },
                                     enabledRows: { [.classical, .netlabels] })
        await store.restore()
        await store.ensureLoaded()
        await store.ensureSourcesLoaded()
        #expect(store.storedRows.classical.map(\.id) == ["lva:a"], "the failure emptied the row")
        #expect(store.storedSourceRows.gutenberg.map(\.id) == ["gut:1"])
        let kept = try await rowStore.rows()
        #expect(kept[.classical]?.map(\.id) == ["lva:a"])
        #expect(kept[.netlabels]?.map(\.id) == ["lva:n"], "a row that came was not written")
        #expect(kept[.oldTimeRadio]?.map(\.id) == ["lva:o"])
        #expect(try await rowStore.failures()[.classical] == "offline")
        #expect(try await rowStore.failures()[.gutenberg] == "offline")
    }

    @Test("the rows of the start page are fetched in parallel: five rows of one second each take under three")
    func parallel() async throws {
        let doc = CatalogLoaderWitness.doc
        let clients = CatalogClients(
            archive: ArchiveSeam(
                popularLibriVoxByLanguage: { _, _, _, _ in try await Self.slow([doc()]) },
                audiobooksOutsideLibriVox: { _, _, _, u in ([], u) },
                popularOldTimeRadio: { _, _ in [] },
                popularMusic: { _, _, _ in try await Self.slow([doc()]) },
                popularArchiveMusic: { _, _, _ in [] },
                metadataOnly: { _ in nil },
                liveness: { _ in .alive }),
            jamendo: JamendoSeam(popularTracks: { _, _, _, _ in try await Self.slow([CatalogLoaderWitness.track()]) },
                                 clientId: { "witness" }),
            gutenberg: GutenbergSeam(audiobooks: { _, _ in [] }),
            librivox: LibriVoxSeam(newBooks: { _, _ in [] }, rssFeed: { _ in Data() }),
            musopen: MusopenSeam(row: { _, _ in try await Self.slow(MusopenCatalog.Page()) }))
        var gates = CatalogLoaderWitness.allOn
        gates.musopen = true
        let started = ContinuousClock.now
        _ = await FreeCatalogLoader.load(using: clients, gates: gates,
                                         dayStore: UserDefaults(suiteName: "catalog-parallel-\(UUID().uuidString)")!)
        let took = ContinuousClock.now - started
        #expect(took < .seconds(3), "the five rows took \(took)")
    }

    @Test("never more than four reads at archive.org at once")
    func hostLimit() async {
        let reads = HostReads(limit: 4)
        let counter = Mutex((now: 0, most: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    await reads.run {
                        counter.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
                        try? await Task.sleep(for: .milliseconds(50))
                        counter.withLock { $0.now -= 1 }
                    }
                }
            }
        }
        #expect(counter.withLock { $0.most } <= 4)
        #expect(counter.withLock { $0.most } >= 2, "the reads did not run at the same time at all")
    }

    @Test("Fence: every popularity read at archive.org goes through the limit", .needsTheSources)
    func limitAtTheOnePlace() throws {
        let clients = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/FreeCatalogClients.swift"), encoding: .utf8))
        let one = try #require(clients.range(of: "static func popularWithTotal("))
        #expect(clients[one.upperBound...].prefix(2_500).contains("HostReads.archive.run"))
    }

    @Test("the database lies in its own folder, kept out of the backup")
    func outOfTheBackup() async throws {
        _ = try await CatalogRowStore.open()
        let directory = try #require(CatalogRowStore.directory)
        #expect(BackupExclusion.isMarked(directory))
        #expect(directory != MaerDatabase.url?.deletingLastPathComponent(), "the catalogue shares the folder of the person's data")
    }
}
#endif
