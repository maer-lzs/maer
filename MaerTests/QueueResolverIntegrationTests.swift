// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// The global Up-Next queue holds ids of ALL media types, so
/// the resolver behind it (AppSession.libraryItem → LibraryViewModel/Subsonic)
/// must resolve books + music too, not just podcasts. The night's unit tests
/// stubbed the resolver (`resolves: { _ in true }`), which hid that the real
/// resolver returned nil for book/music ids. Making queued books invisible in
/// the UI AND skipped by cross-media auto-continue (fell through to the podcast
/// binge). This exercises the REAL LibraryViewModel resolver end of the chain.
@MainActor
struct QueueResolverIntegrationTests {
    private func book(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: id, authorName: nil, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 100, chapters: nil, tracks: nil), addedAt: nil)
    }

    @Test("a loaded audiobook resolves by id (was nil → invisible + skipped)")
    func audiobookResolves() {
        let vm = LibraryViewModel(provider: MockProvider())
        vm.entries = [LibraryEntry(item: book("book-1"), progress: nil)]
        #expect(vm.libraryItem(forId: "book-1")?.id == "book-1")
        #expect(vm.libraryItem(forId: "missing") == nil)
    }

    @Test("chain: a queued book resolves + continuation picks it over the podcast binge")
    func queuedBookNotSkipped() {
        let vm = LibraryViewModel(provider: MockProvider())
        vm.entries = [LibraryEntry(item: book("book-1"), progress: nil)]
        // Resolver mirroring AppSession.libraryItem's type-dispatch. The book
        // branch is exactly the fix (was nil before).
        func resolves(_ id: String) -> Bool {
            if id.hasPrefix("rss:") { return true }     // podcasts always resolvable
            return vm.libraryItem(forId: id) != nil     // book/music via the library list
        }
        let ids = ["book-1", "rss:ep-9"]                // the book was enqueued first
        let pick = QueueContinuation.nextPlayable(ids: ids, isPlayable: { _ in true }, resolves: resolves)
        #expect(pick == "book-1")                       // pre-fix: nil → skipped to rss:ep-9
    }
}
#endif
