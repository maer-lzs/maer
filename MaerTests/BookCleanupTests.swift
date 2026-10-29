// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The cleanup after a fully loaded audiobook library removes the keys of
/// audiobooks that are gone, and nothing of any other source.
@Suite(.serialized)
struct BookCleanupTests {
    @Test("TF-12: die Aufraeumung entfernt nur rohe Hoerbuch-Kennungen, Position und Geschwindigkeit gleich")
    @MainActor
    func onlyRawBookIdsGo() {
        let name = "book-cleanup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let rings = JumpRingRows.matching(defaults)
        let bookmarks = BookmarkCacheRows.matching(defaults)
        let owner = CarrierRowsSpec.entryOwner
        // One title per source, and a namespace that does not exist yet.
        let kept = "li_book_kept", gone = "li_book_gone"
        let others = ["rss:feed:ep", "abspod:ep", "local:file", "sub:song", "jf:song",
                      "jam:album", "lva:book", "zz:new"]
        for id in [kept, gone] + others {
            ListeningStore.store(id, entry: [120, 1_000, 600], in: defaults)
            defaults.set(Float(1.5), forKey: AppStorageKeys.playbackRate(id))
            rings.setEntry(owner, id, [[1.0, 2, 3, 4, 5, 6]])
            bookmarks.setEntry(owner, id, [ABSBookmark(libraryItemId: id, title: "Mark", time: 60, createdAt: 1)])
        }
        AppStorageKeys.cleanupPerBookKeys(validItemIds: [kept], in: defaults)
        CarrierRowStores.cleanupPerBookRows(validItemIds: [kept], in: defaults)

        #expect(ListeningStore.backup(gone, in: defaults) == nil, "a book the library no longer holds goes")
        #expect(defaults.object(forKey: AppStorageKeys.playbackRate(gone)) == nil, "and its speed with it")
        #expect(rings.entry(owner, gone) == nil, "and its jump ring with it")
        #expect(bookmarks.entry(owner, gone) == nil, "and the offline copy of its bookmarks with it")
        for id in [kept] + others {
            #expect(ListeningStore.backup(id, in: defaults) == [120, 1_000, 600], "\(id) keeps its position")
            #expect(defaults.float(forKey: AppStorageKeys.playbackRate(id)) == 1.5, "\(id) keeps its speed")
            #expect(rings.entry(owner, id) != nil, "\(id) keeps its jump ring")
            #expect(bookmarks.entry(owner, id) != nil, "\(id) keeps its bookmarks")
        }
    }

    @Test("TF-12: die Regel ist positiv, eine Kennung ohne Namensraum und nicht in der Bibliothek")
    func theRuleIsPositive() {
        let valid: Set<String> = ["li_kept"]
        #expect(AppStorageKeys.prunedByBookCleanup("li_gone", validItemIds: valid))
        #expect(!AppStorageKeys.prunedByBookCleanup("li_kept", validItemIds: valid))
        for id in ["sub:x", "jf:x", "jam:x", "lva:x", "gut:x", "radio:x", "rss:f:x", "abspod:x", "local:x", "zz:x"] {
            #expect(!AppStorageKeys.prunedByBookCleanup(id, validItemIds: valid), "\(id) is not the cleanup's to judge")
        }
    }

    @Test("eine zweite Buchbibliothek: die Liste einer Bibliothek richtet nicht ueber die Buecher der anderen")
    func oneLibraryDoesNotJudgeTheOther() {
        #expect(AppStorageKeys.listJudgesEveryBook(bookLibraries: 1))
        #expect(!AppStorageKeys.listJudgesEveryBook(bookLibraries: 2), "the other library's books are absent, not gone")
        #expect(!AppStorageKeys.listJudgesEveryBook(bookLibraries: nil), "an unknown number knows nothing")
        #expect(!AppStorageKeys.listJudgesEveryBook(bookLibraries: 0))
    }

    @Test("die Buchkeys gehen nur in cleanUpPerBook und nur hinter der Regel", .needsTheSources)
    func theLoadCleansOnlyBehindTheRule() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/LibraryViewModel.swift"), encoding: .utf8))
        let body = try #require(code.components(separatedBy: "private func cleanUpPerBook(").dropFirst().first)
        let guardAt = try #require(body.range(of: "AppStorageKeys.listJudgesEveryBook(bookLibraries:"))
        let rowsAt = try #require(body.range(of: "CarrierRowStores.cleanupPerBookRows("))
        #expect(guardAt.lowerBound < rowsAt.lowerBound, "the rows go before the rule asks")
        for call in ["cleanupPerBookRows(", "cleanupPerBookKeys("] {
            #expect(code.components(separatedBy: call).count - 1 == 1, "\(call) stands outside the one cleanup")
        }
        #expect(code.components(separatedBy: "cleanUpPerBook(full:").count - 1 == 2,
                "both load paths hand their full list to the one cleanup")
    }

    /// A server with the given book libraries; each holds its own books.
    @MainActor
    final class Libraries: AudioProvider {
        let libraries: [ABSLibrary]
        let books: [String: [Maer.LibraryItem]]
        init(_ books: [String: [String]]) {
            libraries = books.keys.sorted().map { ABSLibrary(id: $0, name: $0, mediaType: "book") }
            self.books = books.mapValues { ids in
                ids.map { id in
                    Maer.LibraryItem(id: id, media: LibraryItemMedia(
                        metadata: LibraryItemMetadata(title: id, authorName: nil, narratorName: nil,
                                                      seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                        duration: 100, chapters: nil, tracks: nil), addedAt: nil)
                }
            }
        }
        var providerId: String { "two-libraries" }
        var keepsMarksOnDevice: Bool { false }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        func fetchLibraries() async throws -> [ABSLibrary] { libraries }
        func fetchLibraryItems(libraryId: String) async throws -> [Maer.LibraryItem] { books[libraryId] ?? [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw NSError(domain: "two-libraries", code: 404) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { nil }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("ueber den Ladeweg: die zweite Buchbibliothek laesst Stand und Geschwindigkeit der ersten stehen, eine einzige raeumt")
    @MainActor
    func theLoadOfASecondLibraryKeepsTheFirst() async throws {
        let keys = [AppStorageKeys.selectedLibraryId, AppStorageKeys.absSignedInServer, AppStorageKeys.absLastFullLoadServer,
                    AppStorageKeys.absMoreThanOneServer]
        let saved = keys.map { ($0, AppStorageKeys.object($0)) }
        defer { for (key, value) in saved { AppStorageKeys.set(value, for: key) } }
        // One server, loaded fully before: the cleanup asks only the libraries.
        AppStorageKeys.set("https://one.example", for: AppStorageKeys.absSignedInServer)
        AppStorageKeys.set("https://one.example", for: AppStorageKeys.absLastFullLoadServer)
        AppStorageKeys.set(nil, for: AppStorageKeys.absMoreThanOneServer)
        let d = UserDefaults.standard
        let bookA = "lib2-a-\(UUID().uuidString)"
        let bookB = "lib2-b-\(UUID().uuidString)"
        defer {
            ListeningStore.forgetBackups(where: { $0 == bookA })
            d.removeObject(forKey: AppStorageKeys.playbackRate(bookA))
        }
        func plant() {
            ListeningStore.store(bookA, entry: [321, Date().timeIntervalSince1970 * 1000])
            d.set(1.5, forKey: AppStorageKeys.playbackRate(bookA))
        }
        func load(_ provider: Libraries) async throws {
            AppStorageKeys.set("lib-b", for: AppStorageKeys.selectedLibraryId)
            await LibraryViewModel(provider: provider).loadLibrary()
            // The key sweep runs detached after the load.
            try await Task.sleep(for: .milliseconds(500))
        }

        plant()
        try await load(Libraries(["lib-a": [bookA], "lib-b": [bookB]]))
        #expect(ListeningStore.backup(bookA)?.first == 321, "the second library cleaned the first one's stand")
        #expect(d.object(forKey: AppStorageKeys.playbackRate(bookA)) as? Double == 1.5, "the second library cleaned the speed")

        // The same server with one library: the book that left goes.
        try await load(Libraries(["lib-b": [bookB]]))
        #expect(ListeningStore.backup(bookA) == nil, "one library no longer cleans a book that left")
        #expect(d.object(forKey: AppStorageKeys.playbackRate(bookA)) == nil)
    }
}
#endif
