// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine

/// What kind of music item an item id denotes (provider-namespaced ids stay
/// opaque to the UI — it asks the provider instead of parsing prefixes).
enum MusicItemKind {
    case album, playlist, song, artist
}

/// The capability surface the MUSIC UI talks to — Jellyfin staging, stage 1:
/// exactly what the music surface uses today, as a protocol, so the views and
/// view models depend on `AppSession.shared.musicProvider` instead of a
/// concrete server type. Subsonic is the only implementation; a future
/// provider (Jellyfin) conforms here and the UI stays untouched. What a
/// provider cannot do is hidden via the established `capabilities` /
/// `isAvailable` pattern, not via `if provider is X` branches.
///
/// Stage 1½: the protocol speaks the NEUTRAL domain types (`MusicArtist`,
/// `MusicPlaylist`, `MusicArtistInfo`, `MusicAlbumInfo`, `MusicTopSong`,
/// `SongLyrics`, `LibraryItem`) — the `Subsonic*` Decodables are wire DTOs
/// internal to their provider, which maps at its boundary (anti-corruption).
/// Shelves speak the neutral `MusicShelf` enum — no provider vocabulary
/// remains in any signature.
@MainActor
protocol MusicProvider: AudioProvider {
    /// Fires after a successful library sync — the mounted Music tab re-runs
    /// its load path on this signal.
    var librarySynced: PassthroughSubject<Void, Never> { get }

    /// Y33 (c): re-check credentials/config and reconnect silently when the
    /// source SHOULD be active but currently is not (scenePhase revalidation).
    func reconnectIfNeeded()

    // MARK: Albums
    func albumShelf(shelf: MusicShelf, size: Int) async throws -> [LibraryItem]
    func albumPage(sort: MusicSortOption, offset: Int, size: Int) async throws -> [LibraryItem]
    func albumInfo(itemId: String) async -> MusicAlbumInfo?

    // MARK: Artists
    func allArtists() async throws -> [MusicArtist]
    func artistAlbums(artistId: String) async throws -> [LibraryItem]
    /// Resolve an artist surfaced earlier (search/browse cache).
    func artist(forId id: String) -> MusicArtist?
    /// Cache a browsed artist so the shared artist route resolves it.
    func cacheSearchedArtist(_ artist: MusicArtist)
    func artistInfo(artistId: String) async -> MusicArtistInfo?
    /// Top songs by ARTIST ID — the id is the stable identity, the name is
    /// display; a provider is never addressed via display text.
    func topSongs(artistId: String, count: Int) async -> [MusicTopSong]

    /// Alphabetical page of the whole song library (music tab "Titles" list).
    func songPage(offset: Int, size: Int) async throws -> [MusicTopSong]

    // MARK: Genres (M3)
    /// The server's genres (counts optional — a provider without counters
    /// ships nil and the page sorts alphabetically).
    func genres() async throws -> [MusicGenre]
    /// Albums of ONE genre (paged).
    func genreAlbums(genre: String, offset: Int, size: Int) async throws -> [LibraryItem]
    /// Songs of ONE genre (paged).
    func genreSongs(genre: String, offset: Int, size: Int) async throws -> [MusicTopSong]

    /// M6: per-track play counts of the LAST detail fetch for this item —
    /// basis for the client-side album/playlist "Top Songs" section (empty
    /// when the server ships no counts; the section then hides silently).
    func trackPlayCounts(forItemId itemId: String) -> [Int?]

    // MARK: Playlists
    func allPlaylists() async throws -> [MusicPlaylist]
    /// Create a server playlist; returns its namespaced item id when the
    /// server echoed it, else nil (the caller re-fetches).
    func createPlaylist(name: String) async throws -> String?
    func addSongs(_ songIds: [String], toPlaylistItemId playlistItemId: String) async throws
    /// Rename/remove/delete — playlist basics; server truth: callers reload
    /// after every mutation.
    func renamePlaylist(itemId: String, newName: String) async throws
    /// Index-based removal (positions in the current order — Subsonic
    /// semantics; ONE call carries all indices).
    func removeSongs(at indices: [Int], fromPlaylistItemId playlistItemId: String) async throws
    func deletePlaylist(itemId: String) async throws
    /// The provider song ids an item contributes when added to a playlist.
    func songIds(forItemId itemId: String) async -> [String]
    /// The provider song id for one track row of an album/playlist item.
    func songId(forItemId itemId: String, trackIndex: Int) async -> String?
    /// Up to 4 distinct album cover-art ids for the 2×2 playlist mosaic.
    func playlistMosaicCoverIDs(forItemId itemId: String) async -> [String]
    /// 961a14e: the playlist's per-song artist names (raw, one per track —
    /// the pure `PlaylistPresentation.topArtists` ranks them); [] when the
    /// provider has no artist data (the card line then stays away).
    func playlistArtistNames(forItemId itemId: String) async -> [String]

    // MARK: Covers
    /// Cover URL for a provider cover-art id (mosaic tiles — not item ids).
    func coverURL(coverArtId: String, size: Int) -> URL?

    // MARK: Shuffle / queue material
    /// The item's songs as individual playable items (shuffled via Up Next).
    func songItems(forItemId itemId: String) async -> [LibraryItem]
    /// Random pool across the whole library for library-wide shuffle.
    func shuffleLibrarySongItems(limit: Int) async -> [LibraryItem]

    // MARK: Lyrics
    /// The best lyrics variant for a song (synced preferred), already in the
    /// app's `SongLyrics` shape; nil when the provider/server has none.
    func lyrics(songId: String) async -> SongLyrics?

    // MARK: Favorites
    func isStarred(itemId: String) async -> Bool
    @discardableResult
    func toggleStar(itemId: String) async -> Bool

    // MARK: Item cache
    /// Best-effort id → item resolution from the session cache.
    func libraryItem(forId itemId: String) -> LibraryItem?
    /// The album items this session has cached (offline browse deck).
    var cachedAlbumItems: [LibraryItem] { get }

    // MARK: Id namespace (the UI never parses provider prefixes itself)
    nonisolated func owns(itemId: String) -> Bool
    nonisolated func kind(of itemId: String) -> MusicItemKind?
    nonisolated func itemId(playlistId: String) -> String
    nonisolated func itemId(songId: String) -> String
    nonisolated func itemId(artistId: String) -> String
    nonisolated func artistId(fromItemId itemId: String) -> String?
}

/// Call-site conveniences mirroring the previous default arguments.
extension MusicProvider {
    func albumShelf(shelf: MusicShelf) async throws -> [LibraryItem] {
        try await albumShelf(shelf: shelf, size: 20)
    }
    func topSongs(artistId: String) async -> [MusicTopSong] {
        await topSongs(artistId: artistId, count: 10)
    }
    func coverURL(coverArtId: String) -> URL? {
        coverURL(coverArtId: coverArtId, size: 300)
    }
    func shuffleLibrarySongItems() async -> [LibraryItem] {
        await shuffleLibrarySongItems(limit: 100)
    }
}
