import Foundation

/// Process-wide playback/library session. Coordinator and LibraryViewModel used
/// to live as @StateObject in LibraryView — on a CarPlay COLD START (the app is
/// woken only for the car scene, no UI) they did not exist at all. Here they
/// belong to the process; UI and CarPlay scene share the same instances (one
/// player, one queue).
@MainActor
final class AppSession {
    static let shared = AppSession()

    /// Owns the APIClient (built from the keychain) — base URL and token are
    /// updated IN PLACE on login, so the objects below stay valid.
    let authViewModel = AuthViewModel()

    /// The server provider (Audiobookshelf) — basis for login, library choice,
    /// settings. `apiClient` remains for the ABS-specific sign-in.
    var provider: any AudioProvider { authViewModel.apiClient }
    var apiClient: APIClient { authViewModel.apiClient }

    /// Local files as a second source (always present, no login).
    var localProvider: LocalProvider { LocalProvider.shared }

    /// Podcasts (RSS feeds) as a source of type `.podcasts`.
    var rssProvider: RSSProvider { RSSProvider.shared }

    /// Audiobookshelf podcasts (server-synced) as a second podcast source.
    var absPodcastProvider: ABSPodcastProvider { ABSPodcastProvider.shared }

    /// Subsonic/Navidrome music as a source of type `.music`.
    var subsonicProvider: SubsonicProvider { SubsonicProvider.shared }

    /// All active sources.
    var allProviders: [any AudioProvider] {
        [provider, localProvider, rssProvider, absPodcastProvider, subsonicProvider]
    }

    /// Routes an item to its source by id prefix. This is the ONLY place allowed
    /// to know id namespaces (the router).
    func provider(for itemId: String) -> any AudioProvider {
        if itemId.hasPrefix("local:") { return localProvider }
        if itemId.hasPrefix("abspod:") { return absPodcastProvider }
        if itemId.hasPrefix("rss:") { return rssProvider }
        if itemId.hasPrefix("sub:") { return subsonicProvider }
        return provider
    }

    /// Cover URL of any item via ITS source — views must never assume a fixed
    /// provider (else wrong/no cover for local files and podcast episodes).
    func coverURL(forItemId itemId: String) -> URL? {
        provider(for: itemId).coverURL(forItemId: itemId)
    }

    /// Finds the `LibraryItem` for an id across ALL sources — for the global
    /// Up-Next queue (render + cross-media auto-continue), resume/restore, the
    /// widget and CarPlay. Type-complete (T3/T5): podcast episodes from their
    /// provider, music from the Subsonic item cache, audiobooks/local titles
    /// from the loaded library list. Best-effort — an id never seen yet is nil,
    /// which every caller already tolerates.
    func libraryItem(forId itemId: String) -> LibraryItem? {
        if itemId.hasPrefix("rss:") {
            return rssProvider.libraryItem(forEpisodeId: itemId)   // O(1) via the guid index
        }
        if itemId.hasPrefix("abspod:") {
            return absPodcastProvider.libraryItem(forEpisodeId: itemId)
        }
        if itemId.hasPrefix("sub:") {
            return subsonicProvider.libraryItem(forId: itemId)
        }
        // Audiobooks / local titles from the loaded library list.
        return libraryViewModel.libraryItem(forId: itemId)
    }

    private(set) lazy var libraryViewModel = LibraryViewModel(provider: provider)
    private(set) lazy var playerCoordinator = PlayerCoordinator(provider: provider)

    private init() {}
}
