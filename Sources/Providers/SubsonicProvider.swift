// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import OSLog

/// AudioProvider for Subsonic-compatible music servers (Navidrome & co.). A new
/// media TYPE for Mär: music, not spoken audio. Mapping to the shared domain:
/// an ALBUM becomes one multi-track `LibraryItem` — its songs are `tracks` and
/// each song also gets a `chapter`, so the existing player treats "next chapter"
/// as "next song" without any change. Auth rides in the stream/cover URLs
/// (query params), so `streamAuthHeaders` stays empty.
@MainActor
final class SubsonicProvider: AudioProvider, MusicProvider {
    static let shared = SubsonicProvider()
    private init() { reloadConfig() }

    private var client: SubsonicClient?

    /// Songs (id + start offset) per item id, so `updateProgress` can tell which
    /// song is playing. Keyed by item id — NOT a single slot — because browsing an
    /// album's detail also calls `fetchItemDetail` and must not clobber the song
    /// map of a different item that is actually playing.
    private var songsByItemId: [String: [(id: String, start: Double)]] = [:]
    /// T3/T5: id → last-seen album/song item, so `AppSession.libraryItem(forId:)`
    /// can resolve a queued music item for the Up-Next UI + auto-continue.
    /// Populated whenever albums are mapped or an item detail is fetched.
    var itemsById: [String: LibraryItem] = [:]
    /// F6: artists surfaced by search, kept for the artist route (domain type).
    var searchedArtistsById: [String: MusicArtist] = [:]
    private var lastScrobbledSong: [String: String] = [:]
    /// Package 3: the last song we wrote a continue-bookmark for, per playlist
    /// item — so the previous song's bookmark is cleaned up on a song change.
    private var lastBookmarkedSong: [String: String] = [:]
    /// Short-lived cache of the server's bookmarks (invalidated on our own write).
    private var bookmarksCache: [SubsonicBookmark]?
    /// M6: per-track play counts of the last detail fetch, by item id.
    private var playCountsByItemId: [String: [Int?]] = [:]

    func trackPlayCounts(forItemId itemId: String) -> [Int?] {
        playCountsByItemId[itemId] ?? []
    }

    /// Albums the user starred (favorites), loaded lazily from the server.
    private var starredAlbumIds: Set<String>?

    var providerId: String { "sub" }
    /// Booksonic: user-set per source — a Booksonic library serves the
    /// AUDIOBOOKS tab through the generic AudioProvider rail (albums are
    /// books, tracks are chapters); the music UI is untouched.
    var mediaType: MediaType { AppStorageKeys.subsonicIsAudiobooksValue ? .audiobooks : .music }
    /// Password login + own search; content is streamed from a server and can be
    /// downloaded for offline. No server-side progress sync (music needs none;
    /// "played" is handled via scrobble at the track level).
    var capabilities: ProviderCapabilities { [.passwordLogin, .remoteSearch, .downloadable] }
    var streamAuthHeaders: [String: String] { [:] }

    /// Only surfaces the Music tab when configured AND effectively active
    /// (music tab ∧ subsonic on). `client != nil` already implies active.
    var isAvailable: Bool {
        AppStorageKeys.subsonicActive && client != nil
    }

    /// Rebuild the client from the stored settings (call after a settings change).
    func reloadConfig() {
        let password = AppStorageKeys.subsonicPasswordValue
        // TF bib-toggles: build the client ONLY when the source is effectively
        // active (music tab ∧ subsonic on) — otherwise nil, so the existing
        // `guard let client` in every method becomes THE one gate and ALL calls
        // (including cross-tab callers like Home's albumShelf) stop. Fixes the
        // "client is never nil when disabled" bug.
        if AppStorageKeys.subsonicActive {
            client = SubsonicClient(
                serverURL: AppStorageKeys.subsonicServerURLValue,
                username: AppStorageKeys.subsonicUsernameValue,
                password: password
            )
        } else {
            client = nil
        }
        // Y37: availability may have flipped (toggle, credentials) — the tab
        // bar reacts live in both directions.
        Logger.music.notice("subsonic config reloaded (active=\(AppStorageKeys.subsonicActive), client=\(self.client != nil))")
        AppSession.shared.notifySourcesChanged()
        // Y26 diagnosis: this is the spot that effectively deactivates the
        // source — never let it happen silently.
        if AppStorageKeys.subsonicActive, client == nil {
            Logger.music.error("subsonic source enabled but client rebuild failed (URL/user missing)")
        } else if AppStorageKeys.subsonicActive, password.isEmpty {
            Logger.music.error("subsonic client built WITHOUT a password (keychain empty or unreadable)")
        }
    }

    /// Y33 (c): scenePhase revalidation — reconnect silently when the source
    /// should be active (user toggle on) but the client is currently missing.
    func reconnectIfNeeded() {
        if !isAvailable, AppStorageKeys.subsonicEnabledValue { reloadConfig() }
    }

    /// Validate server + credentials; returns a user-facing error string or nil.
    func testConnection() async -> String? {
        reloadConfig()
        guard let client else { return String(localized: "Enter server, username and password.") }
        do { try await client.ping(); return nil }
        catch { return (error as? SubsonicClient.SubsonicError)?.errorDescription ?? error.localizedDescription }
    }

    /// Y35: fires after a SUCCESSFUL library sync — the live Music tab
    /// re-runs its existing load path on this signal (the sync itself only
    /// fills the provider cache, which a mounted view model never re-reads).
    let librarySynced = PassthroughSubject<Void, Never>()

    /// F9 seam (Y36): injectable history store so the sync core is testable.
    var historyStore: any SyncHistoryStoring = SyncHistoryStore.shared

    /// Y27: the music library refresh as a VISIBLE operation (sync parity
    /// with the other sources): fetch the album list fresh, remember it, and
    /// record a history entry — numbers, duration, errors in clear text.
    func syncLibraryNow() async -> String? {
        guard let client else {
            // Y36 diagnosis: a press that never reaches the sync core must be
            // visible in the device log.
            Logger.music.error("music sync pressed but no client (URL/user missing)")
            return String(localized: "Enter server, username and password.")
        }
        return await runLibrarySync { try await client.albumList2(type: "alphabeticalByName", size: 500) }
    }

    /// Testable core (fetch injected): success remembers the albums, records
    /// a `.music` history entry and fires `librarySynced`; failure records an
    /// error entry. Every path logs (Y36 device diagnosis).
    func runLibrarySync(fetch: () async throws -> [SubsonicAlbum]) async -> String? {
        let started = Date()
        Logger.music.notice("music sync started")
        do {
            let albums = try await fetch()
            remember(await Self.mapAlbums(albums))
            let songs = albums.reduce(0) { $0 + ($1.songCount ?? 0) }
            historyStore.append(SyncHistory.entry(
                service: .music, direction: .down,
                counters: [.init(key: .albumsUpdated, value: albums.count),
                           .init(key: .songsUpdated, value: songs)],
                duration: Date().timeIntervalSince(started),
                deviceId: SyncHistoryStore.deviceId, startedAt: started))
            Logger.music.notice("music sync ok: \(albums.count) albums, \(songs) songs — history entry appended")
            librarySynced.send()
            return nil
        } catch {
            let message = (error as? SubsonicClient.SubsonicError)?.errorDescription
                ?? error.localizedDescription
            historyStore.append(SyncHistory.entry(
                service: .music, direction: .down, counters: [],
                duration: Date().timeIntervalSince(started),
                error: message,
                deviceId: SyncHistoryStore.deviceId, startedAt: started))
            Logger.music.error("music sync failed: \(message, privacy: .public) — error entry appended")
            return message
        }
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
        // Y49: the LIVE library refresh reaches the server too — record the
        // check so a clean load is visible in the history (only the manual
        // "Sync Now" button used to leave a trace, via runLibrarySync).
        historyStore.noteChecked(.music)
        return remember(await Self.mapAlbums(albums))
    }

    /// Cache the items by id (for `AppSession.libraryItem(forId:)`) and pass them
    /// through unchanged.
    @discardableResult
    private func remember(_ items: [LibraryItem]) -> [LibraryItem] {
        for item in items { itemsById[item.id] = item }
        return items
    }

    /// T3/T5: resolve a music item by id for the Up-Next UI + cross-media
    /// auto-continue. Best-effort — an item never seen (browsed/played) yet is
    /// nil, which the callers already tolerate.
    func libraryItem(forId itemId: String) -> LibraryItem? {
        itemsById[itemId]
    }

    #if DEBUG
    /// UI-test seeding only (see UITestSeed) — makes items resolvable without a
    /// server so a queued album renders in the Up-Next UI.
    func _seedForUITest(_ items: [LibraryItem]) { for item in items { itemsById[item.id] = item } }
    #endif

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
        // M6: per-track play counts ride along the detail — the album/playlist
        // "Top Songs" section ranks them client-side, no extra request.
        playCountsByItemId[itemId] = songs.map(\.playCount)
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
        // T3/T5: remember this item too, so a song played from an artist page
        // (never in the album grid) still resolves in the Up-Next queue.
        itemsById[itemId] = LibraryItem(id: itemId, media: media, addedAt: nil)
        // Package 3: a playlist resumes from its server bookmark (cross-device).
        // Same-device resume is also covered by the player's local backup, so a
        // bookmark-API failure just leaves this nil — no hard dependency.
        let progress = await playlistResumeProgress(itemId: itemId, total: total)
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: progress)
    }

    /// The most-recent bookmark for a playlist, as a `MediaProgress` the player
    /// seeks to on open. Nil for non-playlists or when no usable bookmark exists.
    /// Which items get bookmark-based continue-listening: playlists (music
    /// package 3) and — in Booksonic mode — albums (each album IS a book).
    /// Same bookmark machinery for both (Regel 2).
    nonisolated static func continueScope(itemId: String) -> Bool {
        // M1 (01.08): albums get bookmark continue in MUSIC mode too — the
        // Booksonic-only condition is gone; playlists unchanged (package 3).
        id(itemId, kind: "playlist") != nil || id(itemId, kind: "album") != nil
    }

    private func playlistResumeProgress(itemId: String, total: Double) async -> MediaProgress? {
        guard Self.continueScope(itemId: itemId), total > 0,
              let bookmarks = try? await loadBookmarks(),
              let songs = songsByItemId[itemId] else { return nil }
        let candidates: [(time: Double, ts: Double)] = bookmarks
            .filter { $0.comment == itemId }
            .compactMap { bm in
                guard let songId = bm.entry?.id,
                      let time = BookmarkProgressMath.playlistCurrentTime(
                        songId: songId, positionMs: bm.position ?? 0, songs: songs) else { return nil }
                return (time, Self.parseCreated(bm.changed) ?? Self.parseCreated(bm.created) ?? 0)
            }
        guard let idx = BookmarkProgressMath.mostRecent(candidates.map(\.ts)) else { return nil }
        let pick = candidates[idx]
        return MediaProgress(
            currentTime: pick.time, duration: total,
            progress: min(max(pick.time / total, 0), 1),
            isFinished: pick.time >= total - 1, lastUpdate: pick.ts)
    }

    /// Songs → player material via the shared `MusicTrackAssembly` (Regel 2).
    private static func tracksAndChapters(from songs: [SubsonicSong])
        -> (tracks: [ABSAudioTrack], chapters: [ABSChapter], total: Double) {
        MusicTrackAssembly.build(songs.map {
            MusicTrackAssembly.Song(id: $0.id, title: $0.title,
                                    duration: Double($0.duration ?? 0), size: $0.size)
        })
    }

    // MARK: - View-facing browse (Music tab)

    /// The neutral shelf → getAlbumList2 `type` mapping (provider vocabulary
    /// lives HERE, not in the protocol).
    nonisolated static func albumListType(for shelf: MusicShelf) -> String {
        switch shelf {
        case .newest: return "newest"
        case .frequent: return "frequent"
        case .recent: return "recent"
        case .byArtist: return "alphabeticalByArtist"
        case .alphabetical: return "alphabeticalByName"
        }
    }

    func albumShelf(shelf: MusicShelf, size: Int = 20) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return remember(await Self.mapAlbums(
            try await client.albumList2(type: Self.albumListType(for: shelf), size: size)))
    }

    /// One page of the album catalog for a semantic sort (S5: staged loading).
    func albumPage(sort: MusicSortOption, offset: Int, size: Int) async throws -> [LibraryItem] {
        try await albumPage(type: Self.albumListType(for: sort.shelf), offset: offset, size: size)
    }

    /// One page of the alphabetical album catalog (S5: staged loading — the
    /// grid pages in 100s instead of one 500-album request).
    func albumPage(type: String = "alphabeticalByName", offset: Int, size: Int = 100) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return remember(await Self.mapAlbums(
            try await client.albumList2(type: type, size: size, offset: offset)))
    }

    // MARK: Genres (M3)

    func genres() async throws -> [MusicGenre] {
        guard let client else { return [] }
        return try await client.genres().compactMap { genre in
            guard let name = genre.value else { return nil }
            return MusicGenre(name: name, songCount: genre.songCount, albumCount: genre.albumCount)
        }
    }

    func genreAlbums(genre: String, offset: Int, size: Int) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return remember(await Self.mapAlbums(
            try await client.albumsByGenre(genre: genre, size: size, offset: offset)))
    }

    func genreSongs(genre: String, offset: Int, size: Int) async throws -> [MusicTopSong] {
        guard let client else { return [] }
        let songs = try await client.songsByGenre(genre: genre, count: size, offset: offset)
        return songs.map { MusicTopSong(item: Self.songItem(from: $0), albumName: $0.album) }
    }

    func allArtists() async throws -> [MusicArtist] {
        guard let client else { return [] }
        return try await client.artists().map(Self.domainArtist)
    }

    /// Albums of one artist as library items.
    func artistAlbums(artistId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return await Self.mapAlbums(try await client.artist(id: artistId)?.album ?? [])
    }

    func allPlaylists() async throws -> [MusicPlaylist] {
        guard let client else { return [] }
        return try await client.playlists().map(Self.domainPlaylist)
    }

    /// F5: create a server playlist; returns its namespaced item id when the
    /// server echoed the created playlist, else nil (the caller re-fetches).
    func createPlaylist(name: String) async throws -> String? {
        guard let client else { return nil }
        let created = try await client.createPlaylist(name: name)
        return created.map { Self.itemId(playlistId: $0.id) }
    }

    /// The Subsonic song ids that a music item contributes when added to a
    /// playlist: a single song → itself; an album/playlist → all its tracks
    /// (the track `contentUrl` IS the song id — same mapping used for scrobble).
    func songIds(forItemId itemId: String) async -> [String] {
        if let songId = Self.id(itemId, kind: "song") { return [songId] }
        if let cached = songsByItemId[itemId] { return cached.map(\.id) }
        _ = try? await fetchItemDetail(itemId: itemId)   // populates songsByItemId
        return songsByItemId[itemId]?.map(\.id) ?? []
    }

    /// The Subsonic song id for one track of an album/playlist item. Track lists
    /// and `songsByItemId` share the same ordering, so the row index maps directly.
    func songId(forItemId itemId: String, trackIndex: Int) async -> String? {
        if songsByItemId[itemId] == nil { _ = try? await fetchItemDetail(itemId: itemId) }
        guard let songs = songsByItemId[itemId], songs.indices.contains(trackIndex) else { return nil }
        return songs[trackIndex].id
    }

    /// Add songs to an existing server playlist. `playlistItemId` is a namespaced
    /// `sub:playlist:<id>`; the raw id is passed to Subsonic `updatePlaylist`.
    func addSongs(_ songIds: [String], toPlaylistItemId playlistItemId: String) async throws {
        guard let client, let rawId = Self.id(playlistItemId, kind: "playlist"), !songIds.isEmpty else { return }
        try await client.updatePlaylist(id: rawId, songIdsToAdd: songIds)
        // The cover mosaic is cached; drop it so it re-derives from the new
        // tracks. The detail itself always re-fetches (fetchItemDetail is not
        // cached), so the track list refreshes on the next open on its own.
        playlistMosaicCache[rawId] = nil
    }

    func renamePlaylist(itemId: String, newName: String) async throws {
        guard let client, let rawId = Self.id(itemId, kind: "playlist") else { return }
        try await client.renamePlaylist(id: rawId, name: newName)
    }

    func removeSongs(at indices: [Int], fromPlaylistItemId playlistItemId: String) async throws {
        guard let client, let rawId = Self.id(playlistItemId, kind: "playlist"), !indices.isEmpty else { return }
        try await client.removePlaylistSongs(id: rawId, indices: indices)
        playlistMosaicCache[rawId] = nil
        songsByItemId[playlistItemId] = nil   // stale order — refetch on next use
    }

    func deletePlaylist(itemId: String) async throws {
        guard let client, let rawId = Self.id(itemId, kind: "playlist") else { return }
        try await client.deletePlaylist(id: rawId)
        playlistMosaicCache[rawId] = nil
        itemsById[itemId] = nil
    }

    /// F5: the first up-to-4 DISTINCT album cover-art ids of a playlist for the
    /// 2×2 mosaic (the server's single playlist cover is deliberately ignored).
    /// Best-effort, cached per session.
    private var playlistMosaicCache: [String: [String]] = [:]

    /// MusicProvider shape: item-id-based — the UI never handles raw ids.
    func playlistMosaicCoverIDs(forItemId itemId: String) async -> [String] {
        guard let rawId = Self.id(itemId, kind: "playlist") else { return [] }
        return await playlistMosaicCoverIDs(playlistRawId: rawId)
    }

    private func playlistMosaicCoverIDs(playlistRawId: String) async -> [String] {
        if let cached = playlistMosaicCache[playlistRawId] { return cached }
        guard let client, let pl = try? await client.playlist(id: playlistRawId) else { return [] }
        // Korrektur 01.08: unique per ALBUM (pure, tested) — per-song cover
        // ids built mosaics of three identical images.
        let ids = PlaylistPresentation.mosaicCoverIDs(
            (pl.entry ?? []).map { (albumKey: $0.albumId ?? $0.album, coverArt: $0.coverArt) })
        playlistMosaicCache[playlistRawId] = ids
        return ids
    }

    /// F5: cover URL for a raw cover-art id (mosaic tiles use these, not
    /// `sub:` item ids).
    func coverURL(coverArtId: String, size: Int = 300) -> URL? {
        client?.mediaURL("getCoverArt", ["id": coverArtId, "size": String(size)])
    }

    // MARK: - OpenSubsonic metadata (M1) — best-effort; empty is normal.

    func artistInfo(artistId: String) async -> MusicArtistInfo? {
        guard let client else { return nil }
        return (try? await client.artistInfo(id: artistId)).map(Self.domainArtistInfo)
    }

    func albumInfo(itemId: String) async -> MusicAlbumInfo? {
        guard let client, let albumId = Self.id(itemId, kind: "album") else { return nil }
        return (try? await client.albumInfo(id: albumId)).map(Self.domainAlbumInfo)
    }

    /// Top songs of an artist as playable one-song items. Subsonic's
    /// getTopSongs is addressed by NAME — the id resolves via the route
    /// cache (the artist page has the artist loaded) or one artist fetch.
    func topSongs(artistId: String, count: Int = 10) async -> [MusicTopSong] {
        guard let client else { return [] }
        var name = searchedArtistsById[artistId]?.name
        if name == nil { name = (try? await client.artist(id: artistId))?.name }
        guard let name, let songs = try? await client.topSongs(artist: name, count: count) else { return [] }
        return songs.map { MusicTopSong(item: Self.songItem(from: $0), albumName: $0.album) }
    }

    func songPage(offset: Int, size: Int) async throws -> [MusicTopSong] {
        guard let client else { return [] }
        let songs = try await client.songList(offset: offset, size: size)
        return songs.map { MusicTopSong(item: Self.songItem(from: $0), albumName: $0.album) }
    }

    /// One Subsonic song → a playable single-track `sub:song:` library item.
    /// The shared mapping used by top-songs and by shuffle-play.
    nonisolated static func songItem(from song: SubsonicSong) -> LibraryItem {
        LibraryItem(
            id: itemId(songId: song.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: song.title, authorName: song.artist, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: song.duration.map(Double.init), chapters: nil, tracks: nil),
            addedAt: nil)
    }

    /// Shuffle-play: the album/playlist's songs as individual playable items (so
    /// they can be played in a shuffled ORDER through the Up-Next queue, one song
    /// = one entry). A single song resolves to itself. Items are cached in
    /// `itemsById` so the queue's auto-continue can resolve each id.
    func songItems(forItemId itemId: String) async -> [LibraryItem] {
        guard let client else { return [] }
        let songs: [SubsonicSong]
        if let albumId = Self.id(itemId, kind: "album") {
            songs = (try? await client.album(id: albumId))?.song ?? []
        } else if let playlistId = Self.id(itemId, kind: "playlist") {
            songs = (try? await client.playlist(id: playlistId))?.entry ?? []
        } else if let songId = Self.id(itemId, kind: "song"), let song = try? await client.song(id: songId) {
            songs = [song]
        } else {
            songs = []
        }
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    /// Shuffle-play the WHOLE library: a random pool of songs across the active
    /// server as playable items (cached like `songItems`). The final order is set
    /// by the shared `MediaShuffle` at the call site — this only supplies the pool.
    func shuffleLibrarySongItems(limit: Int = 100) async -> [LibraryItem] {
        guard let client, let songs = try? await client.randomSongs(size: limit) else { return [] }
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    /// OpenSubsonic lyrics for a song id — best variant as `SongLyrics`.
    func lyrics(songId: String) async -> SongLyrics? {
        guard let client else { return nil }
        return Self.songLyrics(fromStructured: (try? await client.lyrics(songId: songId)) ?? [])
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

    // MARK: - Progress (scrobble + playlist continue-listening via bookmarks)

    /// Package 3: continue-listening for PLAYLISTS. Server bookmarks are the
    /// source of truth (cross-device); on any failure/empty we fall back to the
    /// local per-second position backups. Albums are intentionally out of scope
    /// (the architecture works for them identically — same `sub:` mechanics).
    func fetchAllProgress() async throws -> [String: BookProgress] {
        guard client != nil else { return [:] }
        if let bookmarks = try? await loadBookmarks(), !bookmarks.isEmpty {
            let byPlaylist = await playlistProgress(from: bookmarks)
            if !byPlaylist.isEmpty { return byPlaylist }
        }
        return await localPlaylistProgress()
    }

    /// Scrobble each song as it starts (play counts) AND, for playlists, bookmark
    /// the current position so it can be resumed later / on another device.
    /// Called ~every 30 s and on pause/seek, so the position stays fresh.
    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        guard let client, let songs = songsByItemId[itemId], !songs.isEmpty else { return }
        guard let song = songs.last(where: { $0.start <= currentTime + 0.5 }) else { return }
        // Scrobble once per song change (play counts) — unchanged.
        if song.id != lastScrobbledSong[itemId] {
            lastScrobbledSong[itemId] = song.id
            try? await client.scrobble(id: song.id, submission: true)
        }
        // Continue-listening bookmark — PLAYLISTS only (scope). The position is
        // WITHIN the current song (same `songsByItemId` offset arithmetic as the
        // scrobble); the playlist item id rides in the comment as context.
        guard Self.continueScope(itemId: itemId) else { return }
        // Moving to a new song → drop the previous song's bookmark so at most one
        // lingers per playlist (resume is unaffected — the fetch picks the most
        // recent). Best-effort; a song shared across playlists is a rare edge.
        if let prev = lastBookmarkedSong[itemId], prev != song.id {
            try? await client.deleteBookmark(songId: prev)
        }
        lastBookmarkedSong[itemId] = song.id
        let positionMs = Int(max(0, currentTime - song.start) * 1000)
        try? await client.createBookmark(songId: song.id, positionMs: positionMs, comment: itemId)
        bookmarksCache = nil   // our own write invalidates the cache
    }

    private func loadBookmarks() async throws -> [SubsonicBookmark] {
        if let cached = bookmarksCache { return cached }
        guard let client else { return [] }
        let list = try await client.getBookmarks()
        bookmarksCache = list
        return list
    }

    /// Reconstruct per-playlist continue progress from bookmarks: group by the
    /// playlist item id in the comment, add each bookmarked song's offset back
    /// (shared `songsByItemId` mapping), keep the most-recent per playlist. A
    /// bookmark whose song is no longer in the playlist is cleanly dropped.
    private func playlistProgress(from bookmarks: [SubsonicBookmark]) async -> [String: BookProgress] {
        var byPlaylist: [String: [SubsonicBookmark]] = [:]
        for bm in bookmarks {
            guard let comment = bm.comment, Self.continueScope(itemId: comment) else { continue }
            byPlaylist[comment, default: []].append(bm)
        }
        var result: [String: BookProgress] = [:]
        for (playlistItemId, bms) in byPlaylist {
            guard let detail = try? await fetchItemDetail(itemId: playlistItemId),
                  let songs = songsByItemId[playlistItemId],
                  let duration = detail.media.duration, duration > 0 else { continue }
            let candidates: [(time: Double, ts: Double)] = bms.compactMap { bm in
                guard let songId = bm.entry?.id,
                      let time = BookmarkProgressMath.playlistCurrentTime(
                        songId: songId, positionMs: bm.position ?? 0, songs: songs) else { return nil }
                return (time, Self.parseCreated(bm.changed) ?? Self.parseCreated(bm.created) ?? 0)
            }
            guard let idx = BookmarkProgressMath.mostRecent(candidates.map(\.ts)) else { continue }
            let pick = candidates[idx]
            result[playlistItemId] = BookmarkProgressMath.progress(
                currentTime: pick.time, duration: duration, lastUpdate: pick.ts)
        }
        return result
    }

    /// Fallback for servers without a usable bookmark API: continue progress from
    /// the per-second local position backups (written by the player) for the
    /// playlists we know. Storage TECHNIQUE mirrors `LocalProvider` (that provider
    /// stays untouched — this is a self-contained copy).
    private func localPlaylistProgress() async -> [String: BookProgress] {
        let playlists = (try? await allPlaylists()) ?? []
        var result: [String: BookProgress] = [:]
        for pl in playlists {
            let itemId = Self.itemId(playlistId: pl.id)
            guard let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(itemId)) as? [Double],
                  stored.count == 2, let duration = pl.duration, duration > 0 else { continue }
            result[itemId] = BookmarkProgressMath.progress(
                currentTime: stored[0], duration: duration, lastUpdate: stored[1])
        }
        // M1: albums join the local fallback — same localPosition machinery,
        // sourced from the session's album cache.
        for album in cachedAlbumItems {
            guard let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(album.id)) as? [Double],
                  stored.count == 2, let duration = album.media?.duration, duration > 0 else { continue }
            result[album.id] = BookmarkProgressMath.progress(
                currentTime: stored[0], duration: duration, lastUpdate: stored[1])
        }
        return result
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

    // MARK: - Wire → domain (stage 1½ anti-corruption boundary; pure, tested)

    nonisolated static func domainArtist(_ wire: SubsonicArtist) -> MusicArtist {
        MusicArtist(id: wire.id, name: wire.name, albumCount: wire.albumCount)
    }

    nonisolated static func domainPlaylist(_ wire: SubsonicPlaylist) -> MusicPlaylist {
        MusicPlaylist(
            id: wire.id, name: wire.name, songCount: wire.songCount,
            duration: wire.duration.map(Double.init),
            changedAt: PlaylistPresentation.changedDate(wire.changed)
                .map { $0.timeIntervalSince1970 * 1000 })
    }

    nonisolated static func domainArtistInfo(_ wire: SubsonicArtistInfo) -> MusicArtistInfo {
        MusicArtistInfo(
            biography: wire.biography,
            // The hero renders ONE image — take the largest the server offers.
            imageURL: (wire.largeImageUrl ?? wire.mediumImageUrl ?? wire.smallImageUrl)
                .flatMap { URL(string: $0) },
            similarArtistNames: (wire.similarArtist ?? []).compactMap(\.name),
            musicBrainzId: wire.musicBrainzId)
    }

    nonisolated static func domainAlbumInfo(_ wire: SubsonicAlbumInfo) -> MusicAlbumInfo {
        MusicAlbumInfo(notes: wire.notes, musicBrainzId: wire.musicBrainzId)
    }

    /// OpenSubsonic structured lyrics → the app's `SongLyrics`; prefers a
    /// synced variant. (Moved from LyricsParser: wire knowledge belongs to
    /// the provider boundary, the UI only sees `SongLyrics`.)
    nonisolated static func songLyrics(fromStructured list: [SubsonicStructuredLyrics]) -> SongLyrics? {
        let best = list.first { $0.synced == true } ?? list.first
        guard let best, let rawLines = best.line, !rawLines.isEmpty else { return nil }
        let offset = (best.offset ?? 0) / 1000
        let synced = best.synced == true
        let lines = rawLines.map {
            LyricsLine(start: synced ? ($0.start.map { max(0, $0 / 1000 + offset) }) : nil,
                       text: $0.value)
        }
        return SongLyrics(synced: synced, lines: lines)
    }

    nonisolated static func itemId(albumId: String) -> String { "sub:album:\(albumId)" }
    nonisolated static func itemId(playlistId: String) -> String { "sub:playlist:\(playlistId)" }
    nonisolated static func itemId(songId: String) -> String { "sub:song:\(songId)" }

    /// Whether this item id belongs to the Subsonic music namespace — gates the
    /// music-only "Add to Playlist" action (albums/songs/playlists are `sub:…`).
    nonisolated static func owns(itemId: String) -> Bool { itemId.hasPrefix("sub:") }

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

// MARK: - F6 global search (SearchableProvider)

extension SubsonicProvider {
    /// Artists seen through search — the artist route needs the domain value.
    func artist(forId id: String) -> MusicArtist? {
        searchedArtistsById[id]
    }

    /// Cache a browsed artist so the shared artist route resolves it (same
    /// path as a server search hit).
    func cacheSearchedArtist(_ artist: MusicArtist) {
        searchedArtistsById[artist.id] = artist
    }

    /// The album items this session has cached (offline browse deck).
    var cachedAlbumItems: [LibraryItem] {
        itemsById.values.filter { Self.id($0.id, kind: "album") != nil }
    }

    // MARK: MusicProvider id namespace (instance shape over the statics)

    nonisolated func owns(itemId: String) -> Bool { Self.owns(itemId: itemId) }
    nonisolated func kind(of itemId: String) -> MusicItemKind? {
        if Self.id(itemId, kind: "album") != nil { return .album }
        if Self.id(itemId, kind: "playlist") != nil { return .playlist }
        if Self.id(itemId, kind: "song") != nil { return .song }
        if Self.id(itemId, kind: "artist") != nil { return .artist }
        return nil
    }
    nonisolated func itemId(playlistId: String) -> String { Self.itemId(playlistId: playlistId) }
    nonisolated func itemId(songId: String) -> String { Self.itemId(songId: songId) }
    nonisolated func itemId(artistId: String) -> String { "sub:artist:\(artistId)" }
    nonisolated func artistId(fromItemId itemId: String) -> String? { Self.id(itemId, kind: "artist") }
}

extension SubsonicProvider: SearchableProvider {
    @MainActor
    func search(query: String) async throws -> [SearchResult] {
        #if DEBUG
        if UITestSeed.isActive { return offlineSearch(query) }   // seeded stock, no server
        #endif
        guard let client, NetworkMonitor.shared.isConnected else { return offlineSearch(query) }
        let hits = try await client.search3(query: query)
        var out: [SearchResult] = []
        for artist in hits.artist ?? [] {
            guard let name = artist.name else { continue }
            searchedArtistsById[artist.id] = Self.domainArtist(artist)
            out.append(SearchResult(
                id: "sub:artist:\(artist.id)", kind: .artist, title: name,
                coverURL: coverURL(forItemId: "sub:artist:\(artist.id)")))
        }
        for album in hits.album ?? [] {
            let item = Self.libraryItem(from: album)
            itemsById[item.id] = item   // resolvable for the album route + play
            out.append(SearchResult(
                id: item.id, kind: .album, title: item.title,
                subtitle: album.artist, coverURL: coverURL(forItemId: item.id)))
        }
        for song in hits.song ?? [] {
            guard let title = song.title else { continue }
            let id = "sub:song:\(song.id)"
            // Minimal item so a tap-to-play resolves; open() fetches the detail.
            if itemsById[id] == nil {
                itemsById[id] = LibraryItem(
                    id: id,
                    media: LibraryItemMedia(
                        metadata: LibraryItemMetadata(
                            title: title, authorName: song.artist, narratorName: nil,
                            seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                        duration: nil, chapters: nil, tracks: nil),
                    addedAt: nil)
            }
            out.append(SearchResult(
                id: id, kind: .song, title: title, subtitle: song.artist,
                coverURL: coverURL(forItemId: id)))
        }
        // M5: search3 ships NO playlists — filter the (junk-cleaned) playlist
        // list LOCALLY over the same match rule the podcast search uses.
        // Honest limit: this is a client-side name filter, not a server hit.
        let lists = PlaylistPresentation.realPlaylists((try? await allPlaylists()) ?? [])
            .filter { PodcastLocalSearch.matches($0.name ?? "", query) }
        for list in lists {
            let pid = Self.itemId(playlistId: list.id)
            if itemsById[pid] == nil {
                itemsById[pid] = LibraryItem(
                    id: pid,
                    media: LibraryItemMedia(
                        metadata: LibraryItemMetadata(
                            title: list.name, authorName: nil, narratorName: nil,
                            seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                        duration: list.duration, chapters: nil, tracks: nil),
                    addedAt: nil)
            }
            out.append(SearchResult(
                id: pid, kind: .playlist, title: list.name ?? "",
                coverURL: coverURL(forItemId: pid)))
        }
        return out
    }

    /// Offline: the cached album/song stock this session has seen; playable
    /// only when downloaded.
    private func offlineSearch(_ query: String) -> [SearchResult] {
        itemsById.values.compactMap { item in
            guard PodcastLocalSearch.matches(item.title, query)
                || (item.author.map { PodcastLocalSearch.matches($0, query) } ?? false)
            else { return nil }
            let kind: SearchResult.Kind = item.id.hasPrefix("sub:song:") ? .song : .album
            return SearchResult(
                id: item.id, kind: kind, title: item.title,
                subtitle: item.author, coverURL: coverURL(forItemId: item.id),
                isPlayableNow: DownloadManager.shared.isDownloaded(itemId: item.id))
        }
    }
}
