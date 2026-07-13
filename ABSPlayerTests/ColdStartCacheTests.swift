#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// K1-K3 cold-start regression: cache-first render, spinner only without a
/// cache, K2 stored-library fast path with fallback when the library vanished.
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

    private func tempCacheURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maer-coldstart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library_cache.json")
    }

    private func writeCache(_ url: URL, items: [LibraryItem],
                            progress: [String: BookProgress] = [:]) throws {
        try JSONEncoder().encode(LibraryDiskCache(items: items, progress: progress)).write(to: url)
    }

    // MARK: - K1: cache-first

    @Test("Cache-first renders the FULL last state immediately, without offline banner")
    func cacheFirstRendersImmediately() async throws {
        let cacheURL = try tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try writeCache(cacheURL,
                       items: [item("b1"), item("b2")],
                       progress: ["b1": BookProgress(fraction: 0.4, isFinished: false, lastUpdate: 1)])

        let provider = MockProvider()   // never queried by the cache render
        let vm = LibraryViewModel(provider: provider, diskCacheURL: cacheURL)
        await vm.showCachedLibraryIfAvailable()

        #expect(vm.entries.map(\.id).contains("b1"))
        #expect(vm.entries.map(\.id).contains("b2"))
        #expect(vm.entries.first(where: { $0.id == "b1" })?.progress?.fraction == 0.4)
        #expect(!vm.isShowingOfflineCache, "cache at start is not an offline state")
        #expect(!vm.isLoading)
    }

    @Test("No cache → no render (spinner path of the first install)")
    func noCacheIsANoop() async throws {
        let cacheURL = try tempCacheURL()   // file never written
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let vm = LibraryViewModel(provider: MockProvider(), diskCacheURL: cacheURL)
        await vm.showCachedLibraryIfAvailable()
        #expect(vm.entries.isEmpty)
    }

    @Test("Network load after the cache render replaces the stale state silently")
    func networkReplacesCache() async throws {
        let cacheURL = try tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try writeCache(cacheURL, items: [item("stale")])

        let provider = MockProvider()
        provider.items = [item("fresh")]
        let vm = LibraryViewModel(provider: provider, diskCacheURL: cacheURL)

        await vm.showCachedLibraryIfAvailable()
        #expect(vm.entries.map(\.id).contains("stale"))

        await vm.loadLibrary()
        #expect(vm.entries.map(\.id).contains("fresh"))
        #expect(!vm.entries.map(\.id).contains("stale"))
    }

    // MARK: - K2: stored library id

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
        let cacheURL = try tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let provider = MockProvider()
        provider.items = [item("x")]
        let vm = LibraryViewModel(provider: provider, diskCacheURL: cacheURL)
        await withSelectedLibrary("mock-lib") {
            await vm.loadLibrary()
        }
        #expect(vm.entries.map(\.id).contains("x"))
        #expect(vm.errorMessage == nil)
    }

    @Test("Vanished stored id falls back to the resolved library")
    func vanishedStoredIdFallsBack() async throws {
        let cacheURL = try tempCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let provider = MockProvider()
        provider.items = [item("y")]
        // Direct load with the stale id fails; validation lists only "mock-lib".
        provider.failForLibraryIds = ["gone-lib"]
        let vm = LibraryViewModel(provider: provider, diskCacheURL: cacheURL)
        await withSelectedLibrary("gone-lib") {
            await vm.loadLibrary()
        }
        #expect(vm.entries.map(\.id).contains("y"), "must fall back to the existing library")
    }
}
#endif
