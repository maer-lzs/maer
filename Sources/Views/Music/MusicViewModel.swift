import SwiftUI
import Combine

/// Loads the Music tab from the Subsonic provider: two shelves (recently added,
/// most played), the full alphabetical album list, plus artists and playlists
/// for browsing. Album loading is critical (drives the error state); the rest is
/// best-effort so a server without playlists/artists still shows albums.
@MainActor
final class MusicViewModel: ObservableObject {
    @Published var newest: [LibraryItem] = []
    @Published var frequent: [LibraryItem] = []
    @Published var albums: [LibraryItem] = []
    @Published var artists: [SubsonicArtist] = []
    @Published var playlists: [SubsonicPlaylist] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private var provider: SubsonicProvider { SubsonicProvider.shared }
    private var loaded = false

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await reload()
    }

    func reload() async {
        isLoading = true
        errorText = nil
        do {
            albums = try await provider.fetchLibraryItems(libraryId: "sub")
        } catch {
            errorText = (error as? SubsonicClient.SubsonicError)?.errorDescription
                ?? error.localizedDescription
            isLoading = false
            return
        }
        newest = (try? await provider.albumShelf(type: "newest", size: 20)) ?? []
        frequent = (try? await provider.albumShelf(type: "frequent", size: 20)) ?? []
        artists = (try? await provider.allArtists()) ?? []
        playlists = (try? await provider.allPlaylists()) ?? []
        isLoading = false
    }
}
