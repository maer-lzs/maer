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
            albums: {
                if let error = controls.albumsError { throw error }
                return albums
            },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: { [] }
        ))
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
}
#endif
