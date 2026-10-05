// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Cold-start regression: cache-first render, spinner only without a
/// cache, stored-library fast path with fallback when the library vanished.
@MainActor
struct ColdStartCacheTests {

    private func item(_ id: String, title: String = "T") -> LibraryItem {
        LibraryItem(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: title, authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 100, chapters: nil, tracks: nil
            ),
            addedAt: 1
        )
    }

    /// A database file of the case's own, in a folder of its own.
    private func tempDatabase() throws -> (folder: URL, database: MaerDatabase) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maer-coldstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, MaerDatabase(path: dir.appendingPathComponent("maer.sqlite").path))
    }

    /// The cache as the rows hold it after an earlier run.
    private func writeCache(_ database: MaerDatabase, items: [LibraryItem],
                            progress: [String: BookProgress] = [:]) async throws {
        let rows = try await LibraryRowStore(connection: try database.connection())
        _ = try await rows.replaceAll(LibraryDiskCache(items: items, progress: progress))
    }

    // MARK: - Cache-first

    @Test("Cache-first renders the FULL last state immediately, without offline banner")
    func cacheFirstRendersImmediately() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        try await writeCache(home.database,
                             items: [item("b1"), item("b2")],
                             progress: ["b1": BookProgress(fraction: 0.4, isFinished: false, lastUpdate: 1)])

        let provider = MockProvider()   // never queried by the cache render
        let vm = LibraryViewModel(provider: provider, database: home.database)
        await vm.showCachedLibraryIfAvailable()

        #expect(vm.entries.map(\.id).contains("b1"))
        #expect(vm.entries.map(\.id).contains("b2"))
        #expect(vm.entries.first(where: { $0.id == "b1" })?.progress?.fraction == 0.4)
        #expect(!vm.isShowingOfflineCache, "cache at start is not an offline state")
        #expect(!vm.isLoading)
    }

    @Test("No cache → no render (spinner path of the first install)")
    func noCacheIsANoop() async throws {
        let home = try tempDatabase()   // rows never written
        defer { try? FileManager.default.removeItem(at: home.folder) }
        let vm = LibraryViewModel(provider: MockProvider(), database: home.database)
        await vm.showCachedLibraryIfAvailable()
        #expect(vm.entries.isEmpty)
    }

    @Test("Network load after the cache render replaces the stale state silently")
    func networkReplacesCache() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        try await writeCache(home.database, items: [item("stale")])

        let provider = MockProvider()
        provider.items = [item("fresh")]
        let vm = LibraryViewModel(provider: provider, database: home.database)

        await vm.showCachedLibraryIfAvailable()
        #expect(vm.entries.map(\.id).contains("stale"))

        await vm.loadLibrary()
        #expect(vm.entries.map(\.id).contains("fresh"))
        #expect(!vm.entries.map(\.id).contains("stale"))
    }

    /// A load runs to its end while the cached render reads the disk (CarPlay
    /// at a cold start): the disk state does not lie down over the fresh one.
    @Test("ein Laden waehrend des Cache-Lesens: der Platten-Stand legt sich nicht ueber den frischen")
    func aLoadDuringTheCachedReadWins() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        try await writeCache(home.database, items: [item("stale")])
        let provider = MockProvider()
        provider.items = [item("fresh")]
        let vm = LibraryViewModel(provider: provider, database: home.database)
        var loaded = false
        vm.testBeforeCachedApply = {
            await vm.loadLibrary()
            loaded = true
        }
        await vm.showCachedLibraryIfAvailable()
        #expect(loaded, "the precondition: the load ran inside the cached render's window")
        #expect(vm.entries.map(\.id).contains("fresh"))
        #expect(!vm.entries.map(\.id).contains("stale"), "the disk state lay down over the fresh one")
    }

    /// The same with a load that found an empty library: `entries` stays
    /// empty, so a second look at it alone would let the disk state through.
    @Test("ein Laden mit leerer Bibliothek waehrend des Cache-Lesens: auch dann bleibt der Platten-Stand liegen")
    func anEmptyLoadDuringTheCachedReadWinsToo() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        try await writeCache(home.database, items: [item("stale")])
        let provider = MockProvider()
        provider.items = []
        let vm = LibraryViewModel(provider: provider, database: home.database)
        var loaded = false
        vm.testBeforeCachedApply = {
            await vm.loadLibrary()
            loaded = true
        }
        await vm.showCachedLibraryIfAvailable()
        #expect(loaded, "the precondition: the load ran inside the cached render's window")
        #expect(vm.entries.isEmpty, "the precondition: the load found nothing")
        #expect(!vm.entries.map(\.id).contains("stale"), "the disk state lay down over an empty fresh library")
    }

    /// A load that began before the cached render and ends after it (a
    /// CarPlay cold start, then the phone): counted before the cached render
    /// looked, it finds an empty library, and the disk state does not lie
    /// down in between.
    @Test("ein Laden, das vor dem Cache-Weg begann und danach endet: der Platten-Stand legt sich nicht hin")
    func aLoadBegunBeforeTheCachedRenderWins() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        try await writeCache(home.database, items: [item("stale")])
        let provider = MockProvider()
        provider.items = []
        let vm = LibraryViewModel(provider: provider, database: home.database)
        var renderedInside = false
        var staleInside = true
        vm.testAfterLoadBegan = {
            vm.testAfterLoadBegan = nil
            await vm.showCachedLibraryIfAvailable()
            renderedInside = true
            staleInside = vm.entries.map(\.id).contains("stale")
        }
        await vm.loadLibrary()
        #expect(renderedInside, "the precondition: the cached render ran inside the load")
        #expect(!staleInside, "the disk state lay down while a load that began before was still running")
        #expect(vm.entries.isEmpty, "the precondition: the load found nothing")
    }

    /// A load ran to its end before the cached render and found an empty
    /// library: `entries` is empty and no load is in flight, and still the
    /// disk state does not lie down; the load brought its own fallback.
    @Test("ein Laden, das vor dem Cache-Weg ganz lief und leer fand: der Platten-Stand legt sich nicht hin")
    func anEmptyLoadBeforeTheCachedRenderWins() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        try await writeCache(home.database, items: [item("stale")])
        let provider = MockProvider()
        provider.items = []
        let vm = LibraryViewModel(provider: provider, database: home.database)
        await vm.loadLibrary()
        #expect(vm.entries.isEmpty, "the precondition: the load found nothing")
        await vm.showCachedLibraryIfAvailable()
        #expect(!vm.entries.map(\.id).contains("stale"), "the disk state lay down after a finished load")
    }

    /// A load without an available source (switched off, or its access not
    /// readable yet) brings no fallback to the cache: it rebuilds empty and
    /// counts as a load, so the cached render after it shows nothing.
    @Test("ein Laden ohne verfuegbare Quelle faellt auf leer, danach zeigt der Cache-Weg nichts")
    func aLoadWithoutAnAvailableSourceLeavesTheLibraryEmpty() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        try await writeCache(home.database, items: [item("stale")])
        let provider = MockProvider()
        provider.items = [item("fresh")]
        provider.available = false
        let vm = LibraryViewModel(provider: provider, database: home.database)
        await vm.loadLibrary()
        #expect(!vm.entries.map(\.id).contains("fresh"), "the precondition: the source was not asked")
        await vm.showCachedLibraryIfAvailable()
        #expect(vm.entries.isEmpty, "a load without a source fell back to the cache: \(vm.entries.map(\.id))")
    }

    // MARK: - Stored library id

    /// Snapshot/restore the global selected-library key.
    private func withSelectedLibrary(_ id: String?, _ body: () async -> Void) async {
        let key = AppStorageKeys.selectedLibraryId
        let saved = UserDefaults.standard.string(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let id { UserDefaults.standard.set(id, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        await body()
    }

    @Test("Stored id loads directly (fast path)")
    func storedIdFastPath() async throws {
        let provider = MockProvider()
        provider.items = [item("x")]
        let vm = LibraryViewModel(provider: provider, database: MaerDatabase(path: ":memory:"))
        await withSelectedLibrary("mock-lib") {
            await vm.loadLibrary()
        }
        #expect(vm.entries.map(\.id).contains("x"))
        #expect(vm.errorMessage == nil)
    }

    @Test("Vanished stored id falls back to the resolved library")
    func vanishedStoredIdFallsBack() async throws {
        let provider = MockProvider()
        provider.items = [item("y")]
        // Direct load with the stale id fails; validation lists only "mock-lib".
        provider.failForLibraryIds = ["gone-lib"]
        let vm = LibraryViewModel(provider: provider, database: MaerDatabase(path: ":memory:"))
        await withSelectedLibrary("gone-lib") {
            await vm.loadLibrary()
        }
        #expect(vm.entries.map(\.id).contains("y"), "must fall back to the existing library")
    }

    /// The rows are an image of the servers. After a start that could not
    /// read them, a write reads them first, so a title the fetch no longer
    /// has leaves the rows instead of staying under a base nobody knew.
    @Test("Bibliothek nach gescheitertem Start: ein Schrieb liest zuerst, ein Titel, den es am Server nicht mehr gibt, faellt")
    func aWriteAfterAFailedStartReadsFirst() async throws {
        let home = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: home.folder) }
        let connection = try home.database.connection()
        try await connection.execute("CREATE TABLE library_item (other TEXT)")
        try await connection.execute("INSERT INTO library_item (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        let vm = LibraryViewModel(provider: MockProvider(), database: home.database)
        await vm.showCachedLibraryIfAvailable()
        #expect(vm.entries.isEmpty, "the precondition: the start read nothing")

        try await connection.execute("DROP TABLE library_item")
        try await writeCache(home.database, items: [item("stale"), item("kept")])
        vm.entries = [LibraryEntry(item: item("kept"), progress: nil), LibraryEntry(item: item("fresh"), progress: nil)]
        vm._testPersistCache()
        await vm._testAwaitCacheWrite()

        let rows = try await LibraryRowStore(connection: connection)
        let ids = try #require(try await rows.loadAllCounted().cache).items.map(\.id).sorted()
        #expect(ids == ["fresh", "kept"], "rows: \(ids)")
    }
}
#endif
