// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What an audio source CAN do. The UI hides feature areas instead of running
/// into walls (e.g. RSS has no server-side progress).
///
/// `nonisolated` because a set of bits has no actor: under the project's
/// MainActor default it was isolated by accident, and a pure rule asking
/// „may this be downloaded at all" could not read it.
nonisolated struct ProviderCapabilities: OptionSet {
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
    /// definition. The core shows no download controls there.
    static let downloadable = ProviderCapabilities(rawValue: 1 << 4)
    /// The items ARE local files. Nothing to download, and nothing that
    /// disappears without a network. Stated positively on purpose: "cannot be
    /// downloaded" is not the same as "already here". Streams (catalogue,
    /// radio) carry neither capability and are offline unavailable.
    static let alwaysLocal = ProviderCapabilities(rawValue: 1 << 5)
}

/// Prebuilt "Continue"/"Recently Added" rows of a source. So the top library
/// rows are complete immediately while the full list still loads progressively.
struct LibrarySeed {
    var continueListening: [LibraryItem] = []
    var recentlyAdded: [LibraryItem] = []
}

/// The single interface through which the Mär core (player, downloads, sync,
/// search, CarPlay, widgets) sees audio sources. Providers deliver ONLY data.
/// Everything else (offline, sleep, chapter logic, queue, stats) belongs to the
/// core; the player does not know where a track comes from.
///
/// ID convention: the Audiobookshelf MAIN PROVIDER uses raw item ids (existing
/// data: download folders, UserDefaults keys, cover cache hang off them). Every
/// FUTURE provider prefixes its ids with "<providerId>:". E.g. `local:…`,
/// `rss:…`. So sources never collide.
///
/// `ProgressSyncAPI` (fetchAllProgress/updateProgress) is part of the contract;
/// providers without the `.progressSync` capability return empty data or don't
/// throw. The core queries the capability first.
// `Sendable`: every conformer is a `@MainActor` reference type (thus already
// Sendable); declaring it here lets `any AudioProvider` cross into the parallel
// `async let` fetches in the view models. Calls still hop to the main actor.
@MainActor
protocol AudioProvider: AnyObject, Sendable, ProgressSyncAPI {
    /// Short, stable slug ("abs", "local", …). Also the id namespace.
    var providerId: String { get }
    /// Content types (tabs) this source feeds. Default: audiobooks alone.
    /// A SET, because one account can be used for several things at once: a
    /// server that holds music and audiobooks is one source with two
    /// capabilities, not two sources. Empty = feeds nothing right now.
    var mediaTypes: Set<MediaType> { get }
    /// WHAT this source serves a type out of, right now, as one comparable
    /// value. `mediaTypes` answers WHETHER, this answers WHICH, and the
    /// difference is a live defect without it: a server library that changes
    /// from one books library to another leaves every part of `mediaTypes`
    /// untouched, so a shelf gated on it keeps listing the old library's
    /// items and routes taps at a source that no longer knows their ids.
    ///
    /// Per TYPE, not one value for the source: a music library that moves
    /// must not make the audiobook shelf re-fetch every secondary source,
    /// which is the network cost its gate exists to avoid.
    ///
    /// MUST be a protocol REQUIREMENT, like `isAvailable` above and for the
    /// same measured reason: the callers hold `[any AudioProvider]`, and an
    /// extension-only member on the existential binds statically to the
    /// default, so a source's real answer would be discarded in silence.
    func servingSignature(for type: MediaType) -> String
    var capabilities: ProviderCapabilities { get }
    /// Whether the source currently has content (drives tab visibility and the
    /// search fan-out). MUST be a protocol REQUIREMENT: the callers hold
    /// `[any AudioProvider]`, and an extension-only property on the existential
    /// binds statically to the default (`true`). The concrete implementations
    /// (Subsonic toggle, podcast subscriptions) were never consulted (hence the
    /// always-on Music tab).
    var isAvailable: Bool { get }
    /// Whether the source's stored access could not be read yet (the device
    /// not unlocked since it started): it is not available, and it is not
    /// known to be signed out either. A requirement for the same reason as
    /// `isAvailable`; default false.
    var accessUnknown: Bool { get }

    // MARK: Library
    func fetchLibraries() async throws -> [ABSLibrary]
    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem]
    /// Everything this source holds FOR a type. The caller knows which tab it
    /// is filling and nothing else. Which library that maps to is the
    /// source's own business, and passing a made-up id (the provider slug) was
    /// only ever right while every source had exactly one library.
    func fetchLibraryItems(for type: MediaType) async throws -> [LibraryItem]
    /// One page of the library (server paging). The default implementation
    /// (see extension) returns the whole list as a single page. Only ABS
    /// paginates for real; local/RSS sources are small anyway.
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws
        -> (items: [LibraryItem], total: Int)
    /// Prebuilt "Continue"/"Recently Added" rows of the source (ABS
    /// `personalized`). Default: empty. Only ABS provides them; local/RSS sources
    /// derive these rows from their (small) full list.
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed
    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail
    /// Playback of this item has actually BEGUN. Not "someone asked for its
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

    /// Default: no real server paging. The whole (small) list as one page.
    /// ABS overrides this with real `limit`/`page`.
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws
        -> (items: [LibraryItem], total: Int) {
        let all = try await fetchLibraryItems(libraryId: libraryId)
        return (all, all.count)
    }

    /// Default: no prebuilt rows. The caller derives them from the full list.
    /// ABS overrides this with the `personalized` view.
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed { LibrarySeed() }

    /// Default: most sources deliver audiobooks, and exactly that.
    var mediaTypes: Set<MediaType> { [.audiobooks] }

    /// Default: one library per type, so there is nothing to tell apart and
    /// the answer never moves. Only a source that can be pointed at a
    /// DIFFERENT library for the same type overrides this.
    func servingSignature(for type: MediaType) -> String { "" }

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
    var accessUnknown: Bool { false }
}

/// Search is a PROVIDER CAPABILITY, not a feature island. Every provider
/// that can search conforms and returns only what it has. Implementations are
/// offline-first: without a network they search their cached/downloaded stock
/// (the same protocol, no separate path).
/// `Sendable`: the conformers are @MainActor classes (implicitly Sendable), and
/// the aggregator fans out over the existential in a TaskGroup.
nonisolated protocol SearchableProvider: Sendable {
    func search(query: String) async throws -> [SearchResult]
}
