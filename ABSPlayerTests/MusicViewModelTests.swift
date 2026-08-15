// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Pull-to-refresh bug regression: a cancelled reload must not surface as an
/// error, and a real error must never displace the loaded library.
@MainActor
struct MusicViewModelTests {

    /// Switchable failure for the album load.
    final class Controls {
        var albumsError: Error?
        var pageRequests: [Int] = []
    }

    private func album(_ id: String) -> LibraryItem {
        LibraryItem(
            id: "sub:album:\(id)",
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: id, authorName: nil, narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil,
                                              description: nil),
                duration: 100, chapters: nil, tracks: nil
            ),
            addedAt: nil
        )
    }

    private func makeVM(_ controls: Controls) -> MusicViewModel {
        let albums = [album("a1"), album("a2")]
        return MusicViewModel(source: MusicSource(
            albumsPage: { _, offset, _ in
                if let error = controls.albumsError { throw error }
                controls.pageRequests.append(offset)
                return offset == 0 ? albums : []   // one partial page → done
            },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: { [] }
        ))
    }

    /// The measured hang: a first load CANCELLED by a tab switch used to set
    /// `loaded` before the run and made the empty state final — "No music"
    /// until a hard restart. A cancelled run is no attempt: the next
    /// appearance loads fresh.
    @Test("a cancelled first load stays retryable")
    func cancelledFirstLoadStaysRetryable() async {
        let controls = Controls()
        let albums = [album("a1")]
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { _, _, _ in
                controls.pageRequests.append(0)
                if controls.pageRequests.count == 1 { throw CancellationError() }
                return controls.pageRequests.count <= 2 ? albums : []
            },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: { [] }
        ))
        // First appearance: the load is cancelled mid-run — silent, no error.
        await vm.loadIfNeeded()
        #expect(vm.albums.isEmpty)
        #expect(vm.errorText == nil)
        // Second appearance: the gate reopened, the tab loads instead of
        // showing the dead "No music" forever.
        await vm.loadIfNeeded()
        #expect(vm.albums.count == 1)
    }

    @Test("S5: pages the catalog until a partial page arrives")
    func pagesUntilPartial() async {
        let controls = Controls()
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { _, offset, size in
                controls.pageRequests.append(offset)
                // Two full pages, then a partial one ends the loop.
                if offset < 200 { return (0..<size).map { self.album("p\(offset)-\($0)") } }
                return [self.album("last")]
            },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: { [] }
        ))
        await vm.reload()
        #expect(controls.pageRequests == [0, 100, 200])
        #expect(vm.albums.count == 201)
        #expect(vm.errorText == nil)
    }

    @Test("CancellationError: no errorText, albums stay, isLoading resets")
    func cancellationIsNotAnError() async {
        let controls = Controls()
        let vm = makeVM(controls)
        await vm.reload()
        #expect(vm.albums.count == 2)

        controls.albumsError = CancellationError()
        await vm.reload()
        #expect(vm.errorText == nil, "a refreshable-cancelled reload must not report an error")
        #expect(vm.albums.count == 2, "loaded library must survive a cancellation")
        #expect(!vm.isLoading)
    }

    @Test func urlCancelledIsNotAnErrorEither() async {
        let controls = Controls()
        let vm = makeVM(controls)
        await vm.reload()
        controls.albumsError = URLError(.cancelled)
        await vm.reload()
        #expect(vm.errorText == nil)
        #expect(vm.albums.count == 2)
    }

    @Test("Real error: errorText set, but the loaded library is KEPT")
    func realErrorKeepsLibrary() async {
        let controls = Controls()
        let vm = makeVM(controls)
        await vm.reload()
        #expect(vm.albums.count == 2)

        controls.albumsError = URLError(.notConnectedToInternet)
        await vm.reload()
        #expect(vm.errorText != nil)
        #expect(vm.albums.count == 2, "stale beats empty — the view shows the full error page only when albums are empty")
        #expect(!vm.isLoading)
    }

    @Test("Real error on FIRST load: error is reported (empty library → error page)")
    func firstLoadErrorReports() async {
        let controls = Controls()
        controls.albumsError = URLError(.notConnectedToInternet)
        let vm = makeVM(controls)
        await vm.reload()
        #expect(vm.errorText != nil)
        #expect(vm.albums.isEmpty)
    }

    // MARK: - Teil 2: server-side sort

    final class SortRec { var calls: [(sort: MusicSortOption, offset: Int)] = [] }

    @Test("Teil 2: switching the album sort re-queries from offset 0 with the new sort")
    func sortResetsPaging() async {
        let rec = SortRec()
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { sort, offset, _ in
                rec.calls.append((sort, offset))
                return offset == 0 ? [self.album("x")] : []   // one partial page
            },
            shelf: { _, _ in [] }, artists: { [] }, playlists: { [] }
        ))
        vm.sort = .nameAZ
        await vm.loadIfNeeded()
        #expect(rec.calls.contains { $0.sort == .nameAZ && $0.offset == 0 })
        // Switching sort re-queries from the FIRST page with the new sort.
        await vm.setSort(.meistgespielt)
        #expect(rec.calls.contains { $0.sort == .meistgespielt && $0.offset == 0 })
        // Same sort again → no-op, no extra query.
        let before = rec.calls.count
        await vm.setSort(.meistgespielt)
        #expect(rec.calls.count == before)
    }

    @Test("Teil 2: the sort maps to the expected neutral shelf")
    func sortTypeMapping() {
        #expect(MusicSortOption.nameAZ.shelf == .alphabetical)
        #expect(MusicSortOption.kuenstler.shelf == .byArtist)
        #expect(MusicSortOption.neu.shelf == .newest)
        #expect(MusicSortOption.zuletztGespielt.shelf == .recent)
        #expect(MusicSortOption.meistgespielt.shelf == .frequent)
    }
}
#endif
