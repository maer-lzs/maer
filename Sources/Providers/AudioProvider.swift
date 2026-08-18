// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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
    /// The items ARE local files — nothing to download, and nothing that
    /// disappears without a network. Stated positively on purpose: "cannot be
    /// downloaded" is not the same as "already here". Streams (catalogue,
    /// radio) carry neither capability and are offline unavailable.
    static let alwaysLocal = ProviderCapabilities(rawValue: 1 << 5)
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
    /// Content types (tabs) this source feeds — default: audiobooks alone.
    /// A SET, because one account can be used for several things at once: a
    /// server that holds music and audiobooks is one source with two
    /// capabilities, not two sources. Empty = feeds nothing right now.
    var mediaTypes: Set<MediaType> { get }
    var capabilities: ProviderCapabilities { get }
    /// Whether the source currently has content (drives tab visibility and the
    /// search fan-out). MUST be a protocol REQUIREMENT: the callers hold
    /// `[any AudioProvider]`, and an extension-only property on the existential
    /// binds statically to the default (`true`) — the concrete implementations
    /// (Subsonic toggle, podcast subscriptions) were never consulted (Y37's
    /// always-on Music tab).
    var isAvailable: Bool { get }

    // MARK: Library
    func fetchLibraries() async throws -> [ABSLibrary]
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem]
    /// Everything this source holds FOR a type. The caller knows which tab it
    /// is filling and nothing else — which library that maps to is the
    /// source's own business, and passing a made-up id (the provider slug) was
    /// only ever right while every source had exactly one library.
    func fetchLibraryItems(for type: MediaType) async throws -> [LibraryItem]
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
    /// Playback of this item has actually BEGUN — not "someone asked for its
    /// details". A source that keeps play statistics books them here; the core
    /// stays ignorant of what any of them count. Called once per deliberate
    /// start, never on a restore, a refresh or a bounded server check.
    func notePlaybackStarted(itemId: String)

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

    /// Default: most sources deliver audiobooks, and exactly that.
    var mediaTypes: Set<MediaType> { [.audiobooks] }

    /// Default: nothing to book. Sources whose position lives on a server keep
    /// their own history there; only a source with a LOCAL play statistic
    /// (radio, which has no position to remember) needs this.
    func notePlaybackStarted(itemId: String) {}

    /// Default: one library, so the type does not narrow anything. Only a
    /// source that really has several libraries overrides this.
    func fetchLibraryItems(for type: MediaType) async throws -> [LibraryItem] {
        guard mediaTypes.contains(type) else { return [] }
        return try await fetchLibraryItems(libraryId: providerId)
    }
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
