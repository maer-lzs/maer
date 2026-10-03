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
}
#endif
