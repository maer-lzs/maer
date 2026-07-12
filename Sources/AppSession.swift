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

    /// All active sources.
    var allProviders: [any AudioProvider] { [provider, localProvider, rssProvider, absPodcastProvider] }

    /// Routes an item to its source by id prefix. This is the ONLY place allowed
    /// to know id namespaces (the router).
    func provider(for itemId: String) -> any AudioProvider {
        if itemId.hasPrefix("local:") { return localProvider }
        if itemId.hasPrefix("abspod:") { return absPodcastProvider }
        if itemId.hasPrefix("rss:") { return rssProvider }
        return provider
    }

    /// Cover URL of any item via ITS source — views must never assume a fixed
    /// provider (else wrong/no cover for local files and podcast episodes).
    func coverURL(forItemId itemId: String) -> URL? {
        provider(for: itemId).coverURL(forItemId: itemId)
    }

    /// Finds the `LibraryItem` for an id across sources — for resume/restore
    /// when the item is NOT in the audiobook list (podcast episodes live only in
    /// the RSS provider, for example). Audiobooks/local titles come from the
    /// caller's library list and are not looked up here.
    func libraryItem(forId itemId: String) -> LibraryItem? {
        if itemId.hasPrefix("rss:") {
            return rssProvider.libraryItem(forEpisodeId: itemId)   // O(1) via the guid index
        }
        if itemId.hasPrefix("abspod:") {
            return absPodcastProvider.libraryItem(forEpisodeId: itemId)
        }
        return nil
    }

    private(set) lazy var libraryViewModel = LibraryViewModel(provider: provider)
    private(set) lazy var playerCoordinator = PlayerCoordinator(provider: provider)

    private init() {}
}
