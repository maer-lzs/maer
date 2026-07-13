import SwiftUI
import Combine

/// Data source of the Music tab as injectable closures — the live wiring hits
/// the Subsonic provider; tests inject failing/stubbed ones.
struct MusicSource {
    var albums: () async throws -> [LibraryItem]
    var shelf: (_ type: String, _ size: Int) async throws -> [LibraryItem]
    var artists: () async throws -> [SubsonicArtist]
    var playlists: () async throws -> [SubsonicPlaylist]

    static let live = MusicSource(
        albums: { try await SubsonicProvider.shared.fetchLibraryItems(libraryId: "sub") },
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
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        errorText = nil
        do {
            albums = try await source.albums()
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
            return
        }
        // Best-effort extras: on failure/cancellation keep the previous state
        // instead of blanking the shelves with [].
        if let value = try? await source.shelf("newest", 20) { newest = value }
        if let value = try? await source.shelf("frequent", 20) { frequent = value }
        if let value = try? await source.artists() { artists = value }
        if let value = try? await source.playlists() { playlists = value }
    }
}
