// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Pull-to-refresh bug regression: a cancelled reload must not surface as an
/// error, and a real error must never displace the loaded library.
@MainActor
struct MusicViewModelTests {

    /// Switchable failure for the album load.
    final class Controls {
        var albumsError: Error?
        var pageRequests: [Int] = []
        var reachable = true
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
            playlists: { [] },
            reachable: { controls.reachable }
        ))
    }

    /// Music on, no server to ask on this device (measured on a device: the
    /// music switch arrived over sync, the server's access did not). The
    /// page said "your server reported an empty library" about a server it
    /// never asked.
    @Test("ohne Server auf diesem Geraet: nichts wird gefragt, die Seite sagt es, und der naechste Auftritt fragt neu")
    func noServerHereAsksNothingAndSaysSo() async {
        let controls = Controls()
        controls.reachable = false
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { _, offset, _ in controls.pageRequests.append(offset); return [] },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: { [] },
            reachable: { controls.reachable }
        ))
        await vm.loadIfNeeded()
        #expect(vm.serverMissingHere, "the page does not say that the server is missing here")
        #expect(controls.pageRequests.isEmpty, "a server that is not there was asked")
        #expect(vm.errorText == nil && !vm.isLoading)

        // The address is added: the next appearance asks.
        controls.reachable = true
        await vm.loadIfNeeded()
        #expect(!vm.serverMissingHere)
        #expect(controls.pageRequests == [0], "the next appearance did not ask again")
    }

    /// The address is added while the page stands (tabs stay mounted): a
    /// change of the sources asks again at once, without a new appearance;
    /// a page that has its albums is left as it is.
    @Test("eine Aenderung der Quellen fragt eine Seite ohne Server sofort neu, eine volle nicht")
    func aChangeOfTheSourcesAsksAgain() async {
        let controls = Controls()
        controls.reachable = false
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { _, offset, _ in controls.pageRequests.append(offset); return [] },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: { [] },
            reachable: { controls.reachable }
        ))
        await vm.loadIfNeeded()
        #expect(vm.serverMissingHere, "the precondition: no server here")
        controls.reachable = true
        await vm.sourcesChanged()
        #expect(!vm.serverMissingHere, "the page still says no server after the sources changed")
        #expect(controls.pageRequests == [0])
        await vm.sourcesChanged()
        #expect(controls.pageRequests == [0], "a page with its server must not be asked again on the next change")
    }

    /// The server goes away while a full page stands: the change asks the
    /// reachability again and the page shows the way out, without a load.
    @Test("eine volle Seite fragt bei einer Aenderung der Quellen die Erreichbarkeit neu und zeigt den Ausweg, wenn der Server weg ist")
    func aFullPageAsksTheReachabilityAgain() async {
        let controls = Controls()
        let vm = makeVM(controls)
        await vm.loadIfNeeded()
        #expect(!vm.albums.isEmpty && !vm.serverMissingHere, "the precondition: a full page with its server")
        let requests = controls.pageRequests
        controls.reachable = false
        await vm.sourcesChanged()
        #expect(vm.serverMissingHere, "the full page did not notice that the server went away")
        #expect(controls.pageRequests == requests, "asking the reachability is no load")
    }

    /// The tab mounted without a server never loads (its task waits for a
    /// configured server), and before its first run an empty tab shows the
    /// loading state. When the server is entered, the change of the sources
    /// loads it; no loading state stands without a run.
    @Test("der ohne Server montierte Reiter laedt, sobald ein Server eingetragen ist, und dreht nicht ohne Lauf")
    func aTabMountedWithoutAServerLoadsWhenOneComes() async {
        let controls = Controls()
        controls.reachable = false
        let vm = makeVM(controls)
        let before = MusicPageState.of(serverMissing: vm.serverMissingHere, asked: vm.hasAsked,
                                       isEmpty: vm.albums.isEmpty, isLoading: vm.isLoading, failure: vm.errorText)
        #expect(before == .loading && !vm.isLoading, "the precondition: the tab shows loading without a run")
        controls.reachable = true
        await vm.sourcesChanged()
        #expect(vm.hasAsked, "the tab did not load when its server came")
        #expect(controls.pageRequests == [0])
        let after = MusicPageState.of(serverMissing: vm.serverMissingHere, asked: vm.hasAsked,
                                      isEmpty: vm.albums.isEmpty, isLoading: vm.isLoading, failure: vm.errorText)
        #expect(after == .content, "the tab still shows loading without a run")
    }

    /// The measured hang: a first load CANCELLED by a tab switch used to set
    /// `loaded` before the run and made the empty state final. "No music"
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
        // First appearance: the load is cancelled mid-run. Silent, no error.
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

    /// The sort changes while a later page of the old sort is on its way:
    /// that page does not land in the new grid, and the run it belonged to
    /// leaves the loading state to the new one.
    @Test("ein Sortierwechsel, waehrend eine Seite der alten Sortierung unterwegs ist: sie landet nicht im neuen Raster")
    func aPageOfTheOldSortDoesNotLand() async {
        final class Hook { var vm: MusicViewModel?; var oldLateAsked = false }
        let hook = Hook()
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { sort, offset, size in
                guard sort == .nameAZ else { return [self.album("new")] }
                if offset == 0 { return (0..<size).map { self.album("old-\($0)") } }
                // The second page of the old sort: the sort changes while it is on its way.
                hook.oldLateAsked = true
                await hook.vm?.setSort(.meistgespielt)
                return [self.album("old-late")]
            },
            shelf: { _, _ in [] }, artists: { [] }, playlists: { [] }
        ))
        hook.vm = vm
        vm.sort = .nameAZ
        await vm.reload()
        #expect(hook.oldLateAsked, "the precondition: the old sort's second page was on its way")
        #expect(vm.albums.map(\.id) == ["sub:album:new"], "only the new sort's grid: \(vm.albums.count) albums")
        #expect(!vm.isLoading)
    }

    /// A first run is waiting when a second one finds no server: the second
    /// is the page's run now and must clear the loading state, because the
    /// first one no longer does.
    @Test("ein zweiter Lauf ohne Server, waehrend der erste wartet: die Ladeanzeige geht aus")
    func aRunWithoutAServerClearsTheLoadingState() async {
        final class Hook { var vm: MusicViewModel?; var reachable = true; var secondRan = false }
        let hook = Hook()
        let vm = MusicViewModel(source: MusicSource(
            albumsPage: { _, _, _ in
                // The server goes away while the first page is on its way,
                // and the page asks again.
                hook.reachable = false
                await hook.vm?.reload()
                hook.secondRan = true
                return [self.album("late")]
            },
            shelf: { _, _ in [] }, artists: { [] }, playlists: { [] },
            reachable: { hook.reachable }
        ))
        hook.vm = vm
        await vm.reload()
        #expect(hook.secondRan, "the precondition: the second run happened while the first waited")
        #expect(vm.serverMissingHere, "the page says no server")
        #expect(!vm.isLoading, "the loading state is cleared, not left spinning")
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
