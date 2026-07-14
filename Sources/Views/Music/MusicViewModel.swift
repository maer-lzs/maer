import SwiftUI
import Combine
import OSLog

/// Data source of the Music tab as injectable closures — the live wiring hits
/// the Subsonic provider; tests inject failing/stubbed ones.
struct MusicSource {
    // `@MainActor @Sendable` closures → `MusicSource` is Sendable (so it can feed
    // the parallel `async let` shelves/artists/playlists loads) while the closure
    // bodies still run on the main actor. That matches reality — the live wiring
    // only awaits the @MainActor Subsonic provider — and lets the injected test
    // closures capture their @MainActor observation state without a data race.
    /// One page of the alphabetical album catalog (offset, size).
    var albumsPage: @MainActor @Sendable (_ offset: Int, _ size: Int) async throws -> [LibraryItem]
    var shelf: @MainActor @Sendable (_ type: String, _ size: Int) async throws -> [LibraryItem]
    var artists: @MainActor @Sendable () async throws -> [SubsonicArtist]
    var playlists: @MainActor @Sendable () async throws -> [SubsonicPlaylist]

    static let live = MusicSource(
        albumsPage: { try await SubsonicProvider.shared.albumPage(offset: $0, size: $1) },
        shelf: { try await SubsonicProvider.shared.albumShelf(type: $0, size: $1) },
        artists: { try await SubsonicProvider.shared.allArtists() },
        playlists: { try await SubsonicProvider.shared.allPlaylists() }
    )
}

/// Loads the Music tab from the Subsonic provider: two shelves (recently added,
/// most played), the full alphabetical album list, plus artists and playlists
/// for browsing. Album loading is critical (drives the error state); the rest is
/// best-effort so a server without playlists/artists still shows albums.
///
/// Error policy: a REAL error never discards loaded content (stale beats empty,
/// like the book library), and a cancellation is not an error at all —
/// `.refreshable` cancels its task when the bounce settles, which must not
/// surface as a fake network failure.
@MainActor
final class MusicViewModel: ObservableObject {
    @Published var newest: [LibraryItem] = []
    @Published var frequent: [LibraryItem] = []
    @Published var albums: [LibraryItem] = []
    @Published var artists: [SubsonicArtist] = []
    @Published var playlists: [SubsonicPlaylist] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private let source: MusicSource
    private var loaded = false

    init(source: MusicSource = .live) {
        self.source = source
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await reload()
        // One quiet retry before surfacing the error state on first entry —
        // the sporadic failure resolves itself on immediate re-request.
        if errorText != nil, albums.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            Logger.music.info("first music load failed — retrying once")
            await reload()
        }
    }

    /// S5 — staged loading: the shelves (small, parallel) render first, the
    /// album grid pages in 100s (first page critical, rest appended silently),
    /// artists/playlists arrive best-effort in parallel. Error policy unchanged:
    /// full-screen error only when the FIRST album page fails on an empty
    /// library; stale always beats empty; cancellation is silent.
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        errorText = nil

        // Parallel best-effort extras — assigned as they arrive; on failure/
        // cancellation the previous state stays instead of blanking with [].
        async let newestTask = source.shelf("newest", 20)
        async let frequentTask = source.shelf("frequent", 20)
        async let artistsTask = source.artists()
        async let playlistsTask = source.playlists()

        let pageSize = 100
        do {
            let first = try await source.albumsPage(0, pageSize)
            albums = first
            isLoading = false   // grid is on screen — the rest arrives silently
            // Remaining pages: append quietly; an abort keeps the partial list.
            var offset = first.count
            var lastCount = first.count
            while lastCount == pageSize {
                guard let next = try? await source.albumsPage(offset, pageSize), !next.isEmpty else { break }
                albums += next
                offset += next.count
                lastCount = next.count
            }
        } catch is CancellationError {
            // Refreshable settled/was cancelled — not an error, keep everything.
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Real error: report it, but KEEP the already-loaded library
            // (the view shows the full-screen error page only when empty).
            errorText = (error as? SubsonicClient.SubsonicError)?.errorDescription
                ?? error.localizedDescription
            Logger.music.error("album page load failed: \(String(describing: error), privacy: .public)")
            return
        }

        if let value = try? await newestTask { newest = value }
        if let value = try? await frequentTask { frequent = value }
        if let value = try? await artistsTask { artists = value }
        if let value = try? await playlistsTask { playlists = value }
    }
}
