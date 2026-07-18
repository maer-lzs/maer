import Foundation

/// What an audio source CAN do — the UI hides feature areas instead of running
/// into walls (e.g. RSS has no server-side progress).
struct ProviderCapabilities: OptionSet {
    let rawValue: Int

    /// Listening position lives server-side and is reconciled (SyncQueue,
    /// conflict detection, device switch).
    static let progressSync = ProviderCapabilities(rawValue: 1 << 0)
    /// Server-side bookmarks (position + title).
    static let bookmarks = ProviderCapabilities(rawValue: 1 << 1)
    /// Source can search itself (otherwise only local filtering).
    static let remoteSearch = ProviderCapabilities(rawValue: 1 << 2)
    /// Username/password login possible.
    static let passwordLogin = ProviderCapabilities(rawValue: 1 << 3)
    /// Content must be DOWNLOADED first for offline use (server). Sources
    /// without this flag (local files) are always offline available by
    /// definition — the core shows no download controls there.
    static let downloadable = ProviderCapabilities(rawValue: 1 << 4)
}

/// Prebuilt "Continue"/"Recently Added" rows of a source — so the top library
/// rows are complete immediately while the full list still loads progressively.
struct LibrarySeed {
    var continueListening: [LibraryItem] = []
    var recentlyAdded: [LibraryItem] = []
}

/// The single interface through which the Mär core (player, downloads, sync,
/// search, CarPlay, widgets) sees audio sources. Providers deliver ONLY data —
/// everything else (offline, sleep, chapter logic, queue, stats) belongs to the
/// core; the player does not know where a track comes from.
///
/// ID convention: the Audiobookshelf MAIN PROVIDER uses raw item ids (existing
/// data: download folders, UserDefaults keys, cover cache hang off them). Every
/// FUTURE provider prefixes its ids with "<providerId>:" — e.g. `local:…`,
/// `rss:…` — so sources never collide.
///
/// `ProgressSyncAPI` (fetchAllProgress/updateProgress) is part of the contract;
/// providers without the `.progressSync` capability return empty data or don't
/// throw — the core queries the capability first.
// `Sendable`: every conformer is a `@MainActor` reference type (thus already
// Sendable); declaring it here lets `any AudioProvider` cross into the parallel
// `async let` fetches in the view models. Calls still hop to the main actor.
@MainActor
protocol AudioProvider: AnyObject, Sendable, ProgressSyncAPI {
    /// Short, stable slug ("abs", "local", …) — also the id namespace.
    var providerId: String { get }
    /// Content type (tab) of this source — default: audiobooks.
    var mediaType: MediaType { get }
    var capabilities: ProviderCapabilities { get }

    // MARK: Library
    func fetchLibraries() async throws -> [ABSLibrary]
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem]
    /// One page of the library (server paging). The default implementation
    /// (see extension) returns the whole list as a single page — only ABS
    /// paginates for real; local/RSS sources are small anyway.
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws
        -> (items: [LibraryItem], total: Int)
    /// Prebuilt "Continue"/"Recently Added" rows of the source (ABS
    /// `personalized`). Default: empty — only ABS provides them; local/RSS sources
    /// derive these rows from their (small) full list.
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed
    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail

    // MARK: Medien
    func coverURL(forItemId itemId: String) -> URL?
    func streamURL(forContentPath contentPath: String) -> URL?
    /// HTTP headers for streaming/downloads (today: bearer token); empty when
    /// the source needs no auth (local files).
    var streamAuthHeaders: [String: String] { get }

    /// Item-specific streaming/download headers. Default = `streamAuthHeaders`;
    /// RSS overrides for private/premium feeds (per-feed Basic auth).
    func streamAuthHeaders(forItemId itemId: String) -> [String: String]

    // MARK: Bookmarks (only call with the `.bookmarks` capability)
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark]
    func createBookmark(itemId: String, time: Double, title: String) async throws
    func deleteBookmark(itemId: String, time: Double) async throws
}

extension AudioProvider {
    /// Default: item-independent source headers.
    func streamAuthHeaders(forItemId itemId: String) -> [String: String] { streamAuthHeaders }

    /// Default: no real server paging — the whole (small) list as one page.
    /// ABS overrides this with real `limit`/`page`.
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws
        -> (items: [LibraryItem], total: Int) {
        let all = try await fetchLibraryItems(libraryId: libraryId)
        return (all, all.count)
    }

    /// Default: no prebuilt rows — the caller derives them from the full list.
    /// ABS overrides this with the `personalized` view.
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed { LibrarySeed() }

    /// Default: most sources deliver audiobooks.
    var mediaType: MediaType { .audiobooks }
    /// Whether the source currently has content (drives tab visibility).
    /// Default: always available; podcasts e.g. only with a subscription.
    var isAvailable: Bool { true }
}

/// F6: search is a PROVIDER CAPABILITY, not a feature island — every provider
/// that can search conforms and returns only what it has. Implementations are
/// offline-first: without a network they search their cached/downloaded stock
/// (the same protocol, no separate path).
/// `Sendable`: the conformers are @MainActor classes (implicitly Sendable), and
/// the aggregator fans out over the existential in a TaskGroup.
nonisolated protocol SearchableProvider: Sendable {
    func search(query: String) async throws -> [SearchResult]
}
