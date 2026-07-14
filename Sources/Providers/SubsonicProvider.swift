import Foundation

/// AudioProvider for Subsonic-compatible music servers (Navidrome & co.). A new
/// media TYPE for Mär: music, not spoken audio. Mapping to the shared domain:
/// an ALBUM becomes one multi-track `LibraryItem` — its songs are `tracks` and
/// each song also gets a `chapter`, so the existing player treats "next chapter"
/// as "next song" without any change. Auth rides in the stream/cover URLs
/// (query params), so `streamAuthHeaders` stays empty.
@MainActor
final class SubsonicProvider: AudioProvider {
    static let shared = SubsonicProvider()
    private init() { reloadConfig() }

    private var client: SubsonicClient?

    /// Songs (id + start offset) per item id, so `updateProgress` can tell which
    /// song is playing. Keyed by item id — NOT a single slot — because browsing an
    /// album's detail also calls `fetchItemDetail` and must not clobber the song
    /// map of a different item that is actually playing.
    private var songsByItemId: [String: [(id: String, start: Double)]] = [:]
    private var lastScrobbledSong: [String: String] = [:]

    /// Albums the user starred (favorites), loaded lazily from the server.
    private var starredAlbumIds: Set<String>?

    var providerId: String { "sub" }
    var mediaType: MediaType { .music }
    /// Password login + own search; content is streamed from a server and can be
    /// downloaded for offline. No server-side progress sync (music needs none;
    /// "played" is handled via scrobble at the track level).
    var capabilities: ProviderCapabilities { [.passwordLogin, .remoteSearch, .downloadable] }
    var streamAuthHeaders: [String: String] { [:] }

    /// Only surfaces the Music tab when configured AND switched on.
    var isAvailable: Bool {
        AppStorageKeys.subsonicEnabledValue && client != nil
    }

    /// Rebuild the client from the stored settings (call after a settings change).
    func reloadConfig() {
        client = SubsonicClient(
            serverURL: AppStorageKeys.subsonicServerURLValue,
            username: AppStorageKeys.subsonicUsernameValue,
            password: AppStorageKeys.subsonicPasswordValue
        )
    }

    /// Validate server + credentials; returns a user-facing error string or nil.
    func testConnection() async -> String? {
        reloadConfig()
        guard let client else { return String(localized: "Enter server, username and password.") }
        do { try await client.ping(); return nil }
        catch { return (error as? SubsonicClient.SubsonicError)?.errorDescription ?? error.localizedDescription }
    }

    // MARK: - Library

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "sub", name: String(localized: "Music"), mediaType: "music")]
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        // Alphabetical is the stable "browse all" order; the Music tab (later)
        // requests newest/frequent separately for its shelves.
        let albums = try await client.albumList2(type: "alphabeticalByName", size: 500)
        return await Self.mapAlbums(albums)
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let client else { throw SubsonicClient.SubsonicError.network }
        // Album or playlist — both become a multi-track item.
        let songs: [SubsonicSong]
        let title: String?
        let artist: String?
        let genre: String?
        var year: Int?
        if let albumId = Self.id(itemId, kind: "album"), let album = try await client.album(id: albumId) {
            songs = album.song ?? []; title = album.name; artist = album.artist; genre = album.genre
            year = album.year
        } else if let playlistId = Self.id(itemId, kind: "playlist"),
                  let pl = try await client.playlist(id: playlistId) {
            songs = pl.entry ?? []; title = pl.name; artist = nil; genre = nil
        } else if let songId = Self.id(itemId, kind: "song"),
                  let song = try await client.song(id: songId) {
            // Single song (top-songs tap-to-play): a one-track item.
            songs = [song]; title = song.title; artist = song.artist; genre = nil
        } else {
            throw SubsonicClient.SubsonicError.decoding
        }
        let (tracks, chapters, total) = Self.tracksAndChapters(from: songs)
        // Remember the songs + offsets so playback can scrobble each one.
        songsByItemId[itemId] = tracks.map { ($0.contentUrl, $0.startOffset ?? 0) }
        lastScrobbledSong[itemId] = nil
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: title, authorName: artist, narratorName: nil,
                seriesName: nil, genres: genre.map { [$0] },
                publishedYear: year.map { LenientString(String($0)) },
                description: nil
            ),
            duration: total,
            chapters: chapters,
            tracks: tracks
        )
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
    }

    /// Songs → player tracks (per-song stream URL via `contentUrl` = song id) plus
    /// one chapter per song so "next chapter" = "next song".
    private static func tracksAndChapters(from songs: [SubsonicSong])
        -> (tracks: [ABSAudioTrack], chapters: [ABSChapter], total: Double) {
        var tracks: [ABSAudioTrack] = []
        var chapters: [ABSChapter] = []
        var offset = 0.0
        for (i, song) in songs.enumerated() {
            let dur = Double(song.duration ?? 0)
            tracks.append(ABSAudioTrack(
                index: i, startOffset: offset, duration: dur,
                contentUrl: song.id, metadata: ABSFileMetadata(size: song.size)
            ))
            chapters.append(ABSChapter(
                id: i, start: offset, end: offset + dur,
                title: song.title ?? String(localized: "Track \(i + 1)")
            ))
            offset += dur
        }
        return (tracks, chapters, offset)
    }

    // MARK: - View-facing browse (Music tab)

    /// A shelf of albums as library items. `type`: newest | frequent | recent | …
    func albumShelf(type: String, size: Int = 20) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return await Self.mapAlbums(try await client.albumList2(type: type, size: size))
    }

    /// One page of the alphabetical album catalog (S5: staged loading — the
    /// grid pages in 100s instead of one 500-album request).
    func albumPage(offset: Int, size: Int = 100) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return await Self.mapAlbums(
            try await client.albumList2(type: "alphabeticalByName", size: size, offset: offset))
    }

    func allArtists() async throws -> [SubsonicArtist] {
        guard let client else { return [] }
        return try await client.artists()
    }

    /// Albums of one artist as library items.
    func artistAlbums(artistId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return await Self.mapAlbums(try await client.artist(id: artistId)?.album ?? [])
    }

    func allPlaylists() async throws -> [SubsonicPlaylist] {
        guard let client else { return [] }
        return try await client.playlists()
    }

    // MARK: - OpenSubsonic metadata (M1) — best-effort; empty is normal.

    func artistInfo(artistId: String) async -> SubsonicArtistInfo? {
        guard let client else { return nil }
        return try? await client.artistInfo(id: artistId)
    }

    func albumInfo(itemId: String) async -> SubsonicAlbumInfo? {
        guard let client, let albumId = Self.id(itemId, kind: "album") else { return nil }
        return try? await client.albumInfo(id: albumId)
    }

    /// Top songs of an artist as playable one-song items.
    func topSongs(artistName: String, count: Int = 10) async -> [(item: LibraryItem, song: SubsonicSong)] {
        guard let client, let songs = try? await client.topSongs(artist: artistName, count: count) else { return [] }
        return songs.map { song in
            (LibraryItem(
                id: "sub:song:\(song.id)",
                media: LibraryItemMedia(
                    metadata: LibraryItemMetadata(
                        title: song.title, authorName: song.artist, narratorName: nil,
                        seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                    duration: song.duration.map(Double.init), chapters: nil, tracks: nil),
                addedAt: nil
            ), song)
        }
    }

    /// OpenSubsonic lyrics for a song id (structured, possibly synced).
    func lyrics(songId: String) async -> [SubsonicStructuredLyrics] {
        guard let client else { return [] }
        return (try? await client.lyrics(songId: songId)) ?? []
    }

    // MARK: - Favorites (star)

    /// Whether an album item is starred; loads the starred set once and caches it.
    func isStarred(itemId: String) async -> Bool {
        guard let albumId = Self.id(itemId, kind: "album") else { return false }
        if starredAlbumIds == nil, let client {
            starredAlbumIds = Set((try? await client.starredAlbums())?.map(\.id) ?? [])
        }
        return starredAlbumIds?.contains(albumId) ?? false
    }

    /// Toggles the album's starred state on the server; returns the new state.
    @discardableResult
    func toggleStar(itemId: String) async -> Bool {
        guard let client, let albumId = Self.id(itemId, kind: "album") else { return false }
        let newValue = !(starredAlbumIds?.contains(albumId) ?? false)
        try? await client.star(id: albumId, starred: newValue)
        if newValue { starredAlbumIds?.insert(albumId) } else { starredAlbumIds?.remove(albumId) }
        return newValue
    }

    /// Search across albums/songs → album library items (albums directly, songs
    /// mapped to their album where present).
    func searchAlbums(query: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return await Self.mapAlbums(try await client.search3(query: query).album ?? [])
    }

    // MARK: - Media

    func coverURL(forItemId itemId: String) -> URL? {
        guard let client, let id = Self.rawId(itemId) else { return nil }
        return client.mediaURL("getCoverArt", ["id": id, "size": "600"])
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        // contentPath is a Subsonic song id.
        client?.mediaURL("stream", ["id": contentPath])
    }

    // MARK: - Progress (no server sync — like local files; scrobble is separate)

    func fetchAllProgress() async throws -> [String: BookProgress] { [:] }

    /// No position sync, but scrobble each song as it starts playing (play counts
    /// on the server, Last.fm/ListenBrainz where configured). Called ~every 30 s
    /// and on pause/seek, so a song-change is detected within one interval.
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        guard let client, let songs = songsByItemId[itemId], !songs.isEmpty else { return }
        guard let song = songs.last(where: { $0.start <= currentTime + 0.5 }) else { return }
        guard song.id != lastScrobbledSong[itemId] else { return }
        lastScrobbledSong[itemId] = song.id
        try? await client.scrobble(id: song.id, submission: true)
    }

    // MARK: - Bookmarks (unsupported)

    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Mapping helpers

    /// Map a page of albums OFF the main actor (per-album ISO8601 parsing adds
    /// up on big catalogs; the provider is MainActor by project default).
    /// `@concurrent`: runs on the cooperative pool instead of the calling
    /// MainActor (the previous inner `Task.detached` did the same job; @concurrent
    /// expresses it directly and drops the extra hop).
    @concurrent nonisolated private static func mapAlbums(_ albums: [SubsonicAlbum]) async -> [LibraryItem] {
        albums.map { libraryItem(from: $0) }
    }

    nonisolated private static func libraryItem(from album: SubsonicAlbum) -> LibraryItem {
        LibraryItem(
            id: Self.itemId(albumId: album.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: album.name, authorName: album.artist, narratorName: nil,
                    seriesName: nil, genres: album.genre.map { [$0] }, publishedYear: nil,
                    description: nil
                ),
                duration: album.duration.map(Double.init),
                chapters: nil,
                tracks: nil
            ),
            addedAt: Self.parseCreated(album.created)
        )
    }

    nonisolated static func itemId(albumId: String) -> String { "sub:album:\(albumId)" }
    nonisolated static func itemId(playlistId: String) -> String { "sub:playlist:\(playlistId)" }

    /// Extracts the raw id for a given kind ("album"/"playlist") from `sub:<kind>:<id>`.
    nonisolated static func id(_ itemId: String, kind: String) -> String? {
        let prefix = "sub:\(kind):"
        guard itemId.hasPrefix(prefix) else { return nil }
        return String(itemId.dropFirst(prefix.count))
    }

    /// The bare id after `sub:<kind>:` regardless of kind (for cover art).
    nonisolated private static func rawId(_ itemId: String) -> String? {
        guard itemId.hasPrefix("sub:") else { return nil }
        let raw = itemId.split(separator: ":", omittingEmptySubsequences: false).dropFirst(2).joined(separator: ":")
        return raw.isEmpty ? nil : raw
    }

    /// ISO-8601 `created` → epoch ms (matches ABS `addedAt`), for "Recently Added".
    /// Navidrome sends fractional seconds, which the default parser rejects — try
    /// both. `nonisolated(unsafe)`: `ISO8601DateFormatter` is not `Sendable`, but
    /// Foundation date formatters are documented thread-safe for parsing and this
    /// instance is immutable after init — safe to share across the concurrent
    /// `mapAlbums` work. (Not `@unchecked Sendable`; a per-declaration opt-out.)
    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated private static func parseCreated(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let date = iso8601Fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return date.map { $0.timeIntervalSince1970 * 1000 }
    }
}
