// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

/// AudioProvider for Subsonic-compatible music servers (Navidrome & co.). A new
/// media TYPE for Mär: music, not spoken audio. Mapping to the shared domain:
/// an ALBUM becomes one multi-track `LibraryItem`. Its songs are `tracks` and
/// each song also gets a `chapter`, so the existing player treats "next chapter"
/// as "next song" without any change. Auth rides in the stream/cover URLs
/// (query params), so `streamAuthHeaders` stays empty.
@MainActor
final class SubsonicProvider: AudioProvider, MusicProvider {
    static let shared = SubsonicProvider()
    private init() { reloadConfig() }

    private var client: SubsonicClient?

    /// Songs (id + start offset) per item id, so `updateProgress` can tell which
    /// song is playing. Keyed by item id (not a single slot) because browsing an
    /// album's detail also calls `fetchItemDetail` and must not clobber the song
    /// map of a different item that is actually playing.
    private var songsByItemId: [String: [(id: String, start: Double)]] = [:]
    /// Id → last-seen album/song item, so `AppSession.libraryItem(forId:)`
    /// can resolve a queued music item for the Up-Next UI + auto-continue.
    /// Populated whenever albums are mapped or an item detail is fetched.
    var itemsById: [String: LibraryItem] = [:]
    /// Artists surfaced by search, kept for the artist route (domain type).
    var searchedArtistsById: [String: MusicArtist] = [:]
    /// The song each item counted last (`ScrobbleBook`).
    private let scrobbles = ScrobbleBook()
    /// Package 3: the last song we wrote a continue-bookmark for, per playlist
    /// item. So the previous song's bookmark is cleaned up on a song change.
    private var lastBookmarkedSong: [String: String] = [:]
    /// Short-lived cache of the server's bookmarks (invalidated on our own write).
    private var bookmarksCache: [SubsonicBookmark]?
    /// Per-track play counts of the last detail fetch, by item id.
    private var playCountsByItemId: [String: [Int?]] = [:]

    func trackPlayCounts(forItemId itemId: String) -> [Int?] {
        playCountsByItemId[itemId] ?? []
    }

    /// Albums the user starred (favorites), loaded lazily from the server.
    private var starredAlbumIds: Set<String>?

    var providerId: String { "sub" }
    /// Named by the type the server reports ("Navidrome"), else "Subsonic".
    var sourceNames: [String: String] {
        [providerId: MusicSourceName.name(providerId: providerId, reportedType: client?.reportedType)]
    }
    /// What this server is used for, as the user set it. One account can be
    /// both a music library and a Booksonic audiobook shelf at once. The
    /// audiobook side runs through the generic AudioProvider rail (albums are
    /// books, tracks are chapters); the music UI is untouched.
    ///
    /// A type only appears here once it can actually be delivered: with
    /// two modes that means an assigned music folder, so a half-finished setup
    /// shows a gap on the source page instead of an empty tab.
    var mediaTypes: Set<MediaType> {
        Set(MediaType.allCases.filter { AppStorageKeys.subsonicActive(for: $0) })
    }
    /// The same gap as the Jellyfin source, from the other side: here the
    /// person assigns folders to types, so moving books from one folder to
    /// another changes WHICH library serves them while `mediaTypes` stays
    /// exactly as it was. Sorted, because a dictionary has no order and an
    /// unordered value would move without anything having changed.
    func servingSignature(for type: MediaType) -> String {
        AppStorageKeys.subsonicAssignment.byLibrary
            .filter { $0.value == type }
            .keys.sorted().joined(separator: "+")
    }
    /// Password login + own search; content is streamed from a server and can be
    /// downloaded for offline. No server-side progress sync (music needs none;
    /// "played" is handled via scrobble at the track level).
    var keepsMarksOnDevice: Bool { false }
    var capabilities: ProviderCapabilities { [.passwordLogin, .remoteSearch, .downloadable] }
    var streamAuthHeaders: [String: String] { [:] }

    /// Only surfaces the Music tab when configured AND effectively active
    /// (music tab ∧ subsonic on). `client != nil` already implies active.
    var isAvailable: Bool {
        AppStorageKeys.subsonicActive && client != nil
    }

    /// Before a new address is stored: on a switch (`ServerAddressSwitch`)
    /// the stored server leaves the device (`ServerLeaving`: its player, its
    /// rows), as with Jellyfin; its password goes in `passwordAfterAddress`.
    /// Answers whether anything was forgotten.
    @discardableResult
    static func forgetAccessOnSwitch(to newURL: String, player: PlayerCoordinator? = nil) -> Bool {
        guard ServerAddressSwitch.isSwitch(from: AppStorageKeys.subsonicServerURLValue, to: newURL) else { return false }
        Task { await ServerLeaving.forget(ItemNamespace.isSubsonic, player: player) }
        Logger.music.notice("SUBSONIC address switch: the titles of the stored server are forgotten")
        return true
    }

    /// Before a new address is stored: on a switch (`ServerAddressSwitch`)
    /// the stored password, or the key the stored server handed out, goes
    /// with that server and is forgotten. The form fills the field with it,
    /// so the field's text is kept only when the person typed another one
    /// for the new server.
    static func passwordAfterAddress(_ newURL: String, typed: String) -> String {
        let after = ServerAddressSwitch.password(typed: typed, stored: AppStorageKeys.subsonicPasswordValue,
                                                 from: AppStorageKeys.subsonicServerURLValue, to: newURL)
        if after.forgetsStored {
            AppStorageKeys.setSubsonicPassword("")
            Logger.music.notice("SUBSONIC address switch: the password of the stored server is forgotten")
        }
        return after.field
    }

    /// The client the stored settings describe; nil without an address or
    /// a user.
    static func storedClient() -> SubsonicClient? {
        SubsonicClient(serverURL: AppStorageKeys.subsonicServerURLValue,
                       username: AppStorageKeys.subsonicUsernameValue,
                       password: AppStorageKeys.subsonicPasswordValue)
    }

    /// Rebuild the client from the stored settings (call after a settings change).
    func reloadConfig() {
        let password = AppStorageKeys.subsonicPasswordValue
        // TF bib-toggles: build the client ONLY when the source is effectively
        // active (music tab ∧ subsonic on). Otherwise nil, so the existing
        // `guard let client` in every method becomes THE one gate and ALL calls
        // (including cross-tab callers like Home's albumShelf) stop. Fixes the
        // "client is never nil when disabled" bug.
        if AppStorageKeys.subsonicActive {
            client = Self.storedClient()
        } else {
            client = nil
        }
        // The song covers belong to the server they were learned from, and
        // so do the songs it did not answer for.
        songCoverStore = nil
        songCoversUnanswered = UnansweredSongs(server: "")
        // Availability may have flipped (toggle, credentials). The tab
        // bar reacts live in both directions.
        Logger.music.notice("subsonic config reloaded (active=\(AppStorageKeys.subsonicActive), client=\(self.client != nil))")
        AppSession.shared.notifySourcesChanged()
        // This is the spot that effectively deactivates the
        // source. Never let it happen silently.
        if AppStorageKeys.subsonicActive, client == nil {
            Logger.music.error("subsonic source enabled but client rebuild failed (URL/user missing)")
        } else if AppStorageKeys.subsonicActive, password.isEmpty {
            Logger.music.error("subsonic client built WITHOUT a password (keychain empty or unreadable)")
        }
    }

    /// ScenePhase revalidation. Reconnect silently when the source
    /// should be active (user toggle on) but the client is currently missing.
    func reconnectIfNeeded() {
        if !isAvailable, AppStorageKeys.subsonicEnabledValue { reloadConfig() }
    }

    /// Validate server + credentials; returns a user-facing error string or nil.
    func testConnection() async -> String? {
        reloadConfig()
        // Same rule as the Jellyfin page and as this page's own button: the
        // cause that really holds, never a list of three.
        if let missing = SourceReadiness.missing(active: AppStorageKeys.subsonicActive,
                                            sourceEnabled: AppStorageKeys.subsonicEnabledValue,
                                                 servesAnything: !AppStorageKeys.subsonicModes.isEmpty,
                                                 address: AppStorageKeys.subsonicServerURLValue,
                                                 username: AppStorageKeys.subsonicUsernameValue) {
            return missing.sentence
        }
        guard let client else { return SourceReadiness.address.sentence }
        do { try await client.ping(); return nil }
        catch { return ErrorSentence.of(error) }
    }

    /// Fires after a SUCCESSFUL library sync. The live Music tab
    /// re-runs its existing load path on this signal (the sync itself only
    /// fills the provider cache, which a mounted view model never re-reads).
    let librarySynced = PassthroughSubject<Void, Never>()

    /// Seam: injectable history store so the sync core is testable.
    var historyStore: any SyncHistoryStoring = SyncHistoryStore.shared

    /// The music library refresh as a VISIBLE operation (sync parity
    /// with the other sources): fetch the album list fresh, remember it, and
    /// record a history entry. Numbers, duration, errors in clear text.
    func syncLibraryNow() async -> String? {
        guard let client else {
            // A press that never reaches the sync core must be
            // visible in the device log.
            Logger.music.error("music sync pressed but no client (URL/user missing)")
            return (SourceReadiness.missing(active: AppStorageKeys.subsonicActive,
                                            sourceEnabled: AppStorageKeys.subsonicEnabledValue,
                                            servesAnything: !AppStorageKeys.subsonicModes.isEmpty,
                                            address: AppStorageKeys.subsonicServerURLValue,
                                            username: AppStorageKeys.subsonicUsernameValue)
                    ?? .address).sentence
        }
        let scope = folderScope(for: .music)
        return await runLibrarySync {
            try await client.albumList2(type: "alphabeticalByName", size: 500, musicFolderIds: scope)
        }
    }

    /// Testable core (fetch injected): success remembers the albums, records
    /// a `.music` history entry and fires `librarySynced`; failure records an
    /// error entry. Every path logs, so a device report can be read.
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
                deviceId: SyncHistoryStore.entryDeviceId, startedAt: started))
            Logger.music.notice("music sync ok: \(albums.count) albums, \(songs) songs — history entry appended")
            librarySynced.send()
            return nil
        } catch {
            let message = ErrorSentence.of(error)
            historyStore.append(SyncHistory.entry(
                service: .music, direction: .down, counters: [],
                duration: Date().timeIntervalSince(started),
                error: message,
                deviceId: SyncHistoryStore.entryDeviceId, startedAt: started))
            Logger.music.error("music sync failed: \(message, privacy: .public) — error entry appended")
            return message
        }
    }

    // MARK: - Library

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "sub", name: String(localized: "Music"), mediaType: "music")]
    }

    /// The server's own top-level folders, and the ONE place that refreshes the
    /// cached list the activation gate reads. Assignments for folders that
    /// vanished are dropped in the same breath. Otherwise a mode keeps looking
    /// complete because of a folder that no longer exists.
    @discardableResult
    func refreshLibraries() async throws -> [SourceLibrary] {
        guard let client else { return AppStorageKeys.subsonicKnownLibraries }
        let folders = try await client.musicFolders()
        AppStorageKeys.subsonicKnownLibraries = folders
        AppStorageKeys.subsonicAssignment = AppStorageKeys.subsonicAssignment.pruned(toKnown: folders)
        Logger.music.notice("subsonic music folders: \(folders.count)")
        AppSession.shared.notifySourcesChanged()
        return folders
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        try await albums(musicFolderIds: [libraryId == providerId ? nil : libraryId].compactMap { $0 })
    }

    /// The type-scoped fetch. With one mode the folder list is not consulted at
    /// all, so the call is byte-for-byte the one this source always made.
    func fetchLibraryItems(for type: MediaType) async throws -> [LibraryItem] {
        guard AppStorageKeys.subsonicActive(for: type) else { return [] }
        let modes = AppStorageKeys.subsonicModes
        guard modes.count > 1 else { return try await albums(musicFolderIds: []) }
        return try await albums(musicFolderIds: SourceLibraries.libraries(
            for: type, modes: modes,
            known: AppStorageKeys.subsonicKnownLibraries,
            assignment: AppStorageKeys.subsonicAssignment))
    }

    /// The folders that feed a type, in the form the client wants them. Empty
    /// means "do not narrow". The whole-server answer, and the ONLY answer a
    /// single-mode source ever gets, so its requests stay byte-for-byte what
    /// they always were.
    func folderScope(for type: MediaType) -> [String] {
        let modes = AppStorageKeys.subsonicModes
        guard modes.count > 1 else { return [] }
        return SourceLibraries.libraries(
            for: type, modes: modes,
            known: AppStorageKeys.subsonicKnownLibraries,
            assignment: AppStorageKeys.subsonicAssignment)
    }

    /// Alphabetical is the stable "browse all" order; the Music tab requests
    /// newest/frequent separately for its shelves. An empty folder list means
    /// "no narrowing", which is the whole-server answer.
    private func albums(musicFolderIds: [String]) async throws -> [LibraryItem] {
        guard let client else { return [] }
        var albums: [SubsonicAlbum] = []
        if musicFolderIds.isEmpty {
            albums = try await client.albumList2(type: "alphabeticalByName", size: 500)
        } else {
            albums = try await client.albumList2(type: "alphabeticalByName", size: 500,
                                                 musicFolderIds: musicFolderIds)
        }
        // The LIVE library refresh reaches the server too. Record the
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

    /// Resolve a music item by id for the Up-Next UI + cross-media
    /// auto-continue. Best-effort. An item never seen (browsed/played) yet is
    /// nil, which the callers already tolerate.
    func libraryItem(forId itemId: String) -> LibraryItem? {
        itemsById[itemId]
    }

    #if DEBUG
    /// UI-test seeding only (see UITestSeed). Makes items resolvable without a
    /// server so a queued album renders in the Up-Next UI.
    func _seedForUITest(_ items: [LibraryItem]) { for item in items { itemsById[item.id] = item } }
    #endif

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        #if DEBUG
        // Playback journeys (shuffle badge) need a resolvable detail.
        // One dummy track; the mini bar binds to the item, not the stream.
        if UITestSeed.isActive, let item = itemsById[itemId] {
            return LibraryItemDetail(
                id: itemId,
                media: LibraryItemMedia(
                    metadata: LibraryItemMetadata(
                        title: item.title, authorName: item.author, narratorName: nil,
                        seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                    duration: 60,
                    chapters: nil,
                    tracks: [ABSAudioTrack(index: 0, startOffset: 0, duration: 60,
                                           contentUrl: "https://seed.invalid/seed.mp3",
                                           metadata: nil)]),
                userMediaProgress: nil)
        }
        #endif
        guard let client else { throw SubsonicClient.SubsonicError.network }
        // Album or playlist. Both become a multi-track item.
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
        learnCovers(songs)
        let (tracks, chapters, total) = Self.tracksAndChapters(from: songs)
        // Remember the songs + offsets so playback can scrobble each one.
        songsByItemId[itemId] = tracks.map { ($0.contentUrl, $0.startOffset ?? 0) }
        scrobbles.forget(itemId)
        // Per-track play counts ride along the detail. The album/playlist
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
        // Remember this item too, so a song played from an artist page
        // (never in the album grid) still resolves in the Up-Next queue.
        itemsById[itemId] = LibraryItem(id: itemId, media: media, addedAt: nil)
        // Package 3: a playlist resumes from its server bookmark (cross-device).
        // Same-device resume is also covered by the player's local backup, so a
        // bookmark-API failure just leaves this nil. No hard dependency.
        let progress = await playlistResumeProgress(itemId: itemId, total: total)
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: progress)
    }

    /// The most-recent bookmark for a playlist, as a `MediaProgress` the player
    /// seeks to on open. Nil for non-playlists or when no usable bookmark exists.
    /// Which items get bookmark-based continue-listening: playlists (music
    /// package 3) and, in Booksonic mode, albums (each album IS a book).
    /// Same bookmark machinery for both.
    nonisolated static func continueScope(itemId: String) -> Bool {
        // Albums get bookmark continue in MUSIC mode too. The
        // Booksonic-only condition is gone; playlists unchanged (package 3).
        id(itemId, kind: "playlist") != nil || id(itemId, kind: "album") != nil
    }

    private func playlistResumeProgress(itemId: String, total: Double) async -> MediaProgress? {
        guard Self.continueScope(itemId: itemId), total > 0,
              let bookmarks = try? await loadBookmarks(),
              let songs = songsByItemId[itemId],
              let pick = BookmarkProgressMath.resume(bookmarks: bookmarks, itemId: itemId,
                                                    songs: songs, stamp: Self.bookmarkStamp,
                                                    key: { Self.canonicalItemId($0) }) else { return nil }
        Logger.music.notice("BOOKMARK read item=\(itemId, privacy: .private(mask: .hash)) bookmarks=\(bookmarks.count) time=\(Int(pick.time))s by=open")
        return MediaProgress(
            currentTime: pick.time, duration: total,
            progress: min(max(pick.time / total, 0), 1),
            isFinished: ProgressMark.reachedEnd(position: pick.time, duration: total),
            lastUpdate: pick.stamp)
    }

    /// The moment a bookmark speaks for: changed, else created, else zero.
    nonisolated private static func bookmarkStamp(_ bookmark: SubsonicBookmark) -> Double {
        parseCreated(bookmark.changed) ?? parseCreated(bookmark.created) ?? 0
    }

    /// Songs → player material via the shared `MusicTrackAssembly`.
    private static func tracksAndChapters(from songs: [SubsonicSong])
        -> (tracks: [ABSAudioTrack], chapters: [ABSChapter], total: Double) {
        MusicTrackAssembly.build(songs.map {
            MusicTrackAssembly.Song(id: $0.id, title: $0.title,
                                    duration: Double($0.duration ?? 0), size: $0.size,
                                    contentType: $0.contentType, artist: $0.artist,
                                    coverArt: $0.coverArt)
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
            try await client.albumList2(type: Self.albumListType(for: shelf), size: size,
                                        musicFolderIds: folderScope(for: .music))))
    }

    /// One page of the album catalog for a semantic sort (staged loading).
    func albumPage(sort: MusicSortOption, offset: Int, size: Int) async throws -> [LibraryItem] {
        try await albumPage(type: Self.albumListType(for: sort.shelf), offset: offset, size: size)
    }

    /// One page of the alphabetical album catalog (staged loading. The
    /// grid pages in 100s instead of one 500-album request).
    func albumPage(type: String = "alphabeticalByName", offset: Int, size: Int = 100) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return remember(await Self.mapAlbums(
            try await client.albumList2(type: type, size: size, offset: offset,
                                        musicFolderIds: folderScope(for: .music))))
    }

    // MARK: Genres

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
            try await client.albumsByGenre(genre: genre, size: size, offset: offset,
                                           musicFolderIds: folderScope(for: .music))))
    }

    func genreSongs(genre: String, offset: Int, size: Int) async throws -> [MusicTopSong] {
        guard let client else { return [] }
        let songs = try await client.songsByGenre(genre: genre, count: size, offset: offset,
                                                  musicFolderIds: folderScope(for: .music))
        learnCovers(songs)
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

    /// Create a server playlist; returns its namespaced item id when the
    /// server echoed the created playlist, else nil (the caller re-fetches).
    func createPlaylist(name: String) async throws -> String? {
        guard let client else { return nil }
        let created = try await client.createPlaylist(name: name)
        return created.map { Self.itemId(playlistId: $0.id) }
    }

    /// The Subsonic song ids that a music item contributes when added to a
    /// playlist: a single song → itself; an album/playlist → all its tracks
    /// (the track `contentUrl` IS the song id. Same mapping used for scrobble).
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

    /// The first up-to-4 DISTINCT album cover-art ids of a playlist for the
    /// 2×2 mosaic (the server's single playlist cover is deliberately ignored).
    /// Best-effort, cached per session.
    private var playlistMosaicCache: [String: [String]] = [:]
    private var playlistArtistCache: [String: [String]] = [:]

    /// MusicProvider shape: item-id-based. The UI never handles raw ids.
    func playlistMosaicCoverIDs(forItemId itemId: String) async -> [String] {
        guard let rawId = Self.id(itemId, kind: "playlist") else { return [] }
        return await playlistMosaicCoverIDs(playlistRawId: rawId)
    }

    private func playlistMosaicCoverIDs(playlistRawId: String) async -> [String] {
        if let cached = playlistMosaicCache[playlistRawId] { return cached }
        guard let client, let pl = await IndexRunLine.measured("mosaic", id: playlistRawId, {
            try await client.playlist(id: playlistRawId)
        }) ?? nil else { return [] }
        // Korrektur 01.08: unique per ALBUM (pure, tested). Per-song cover
        // ids built mosaics of three identical images.
        let ids = PlaylistPresentation.mosaicCoverIDs(
            (pl.entry ?? []).map { (albumKey: $0.albumId ?? $0.album, coverArt: $0.coverArt) })
        playlistMosaicCache[playlistRawId] = ids
        return ids
    }

    /// Per-song artist names of the playlist. SAME getPlaylist
    /// fetch the mosaic uses, cached alongside it.
    func playlistArtistNames(forItemId itemId: String) async -> [String] {
        guard let rawId = Self.id(itemId, kind: "playlist") else { return [] }
        if let cached = playlistArtistCache[rawId] { return cached }
        guard let client, let pl = try? await client.playlist(id: rawId) else { return [] }
        let names = (pl.entry ?? []).compactMap(\.artist)
        playlistArtistCache[rawId] = names
        return names
    }

    /// Cover URL for a raw cover-art id (mosaic tiles use these, not
    /// `sub:` item ids).
    func coverURL(coverArtId: String, size: Int = 300) -> URL? {
        client?.mediaURL("getCoverArt", ["id": coverArtId, "size": String(size)])
    }

    // MARK: - OpenSubsonic metadata. Best-effort; empty is normal.

    func artistInfo(artistId: String) async -> MusicArtistInfo? {
        guard let client else { return nil }
        let info = await IndexRunLine.measured("artistInfo", id: artistId) {
            try await client.artistInfo(id: artistId)
        }
        return (info ?? nil).map(Self.domainArtistInfo)
    }

    func albumInfo(itemId: String) async -> MusicAlbumInfo? {
        guard let client, let albumId = Self.id(itemId, kind: "album") else { return nil }
        return (try? await client.albumInfo(id: albumId)).map(Self.domainAlbumInfo)
    }

    func album(ofSong songItemId: String) async throws -> LibraryItem? {
        guard let songId = Self.id(songItemId, kind: "song") else { return nil }
        guard let client else { throw SubsonicClient.SubsonicError.network }
        guard let song = try await client.song(id: songId), let albumId = song.albumId else { return nil }
        return LibraryItem(
            id: Self.itemId(albumId: albumId),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: song.album, authorName: song.artist, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: nil, chapters: nil, tracks: nil),
            addedAt: nil)
    }

    /// Top songs of an artist as playable one-song items. Subsonic's
    /// getTopSongs is addressed by NAME. The id resolves via the route
    /// cache (the artist page has the artist loaded) or one artist fetch.
    func topSongs(artistId: String, count: Int = 10) async -> [MusicTopSong] {
        guard let client else { return [] }
        var name = searchedArtistsById[artistId]?.name
        if name == nil { name = (try? await client.artist(id: artistId))?.name }
        guard let name, let songs = try? await client.topSongs(artist: name, count: count) else { return [] }
        learnCovers(songs)
        return songs.map { MusicTopSong(item: Self.songItem(from: $0), albumName: $0.album) }
    }

    /// The whole song list, sorted on the device: the Subsonic
    /// interface cannot sort all songs, so they are loaded once, kept
    /// through the `Ablage`, and afterwards only what is new is added
    /// (`SongCatalogRule`). The server is asked whether anything changed
    /// only when a list is opened from the top, not for every page.
    func songPage(offset: Int, size: Int, sort: MusicSortOption) async throws -> [MusicTopSong] {
        guard let client else { return [] }
        let catalog = try await songCatalog(client: client, opening: offset == 0)
        let sorted: [MusicTopSong]
        if let known = sortedSongs[sort] {
            sorted = known
        } else {
            sorted = SongOrder.sorted(catalog.entries.map(Self.topSong(from:)), by: sort)
            sortedSongs[sort] = sorted
        }
        let page = Array(sorted.dropFirst(offset).prefix(size))
        // Only the page shown learns its covers: the memory stays capped
        // however many songs the list holds.
        learnCoverArt(Self.pageCoverArt(page))
        return page
    }

    /// Each song of a page with the cover id the kept list names for it.
    nonisolated static func pageCoverArt(_ page: [MusicTopSong]) -> [(songId: String, coverArt: String?)] {
        page.compactMap { song in subParts(song.id).map { ($0.raw, song.coverArt) } }
    }

    /// When the kept song list was last loaded whole; the page says it.
    var songListWholeAt: Date? { songCatalogKept.map { Date(timeIntervalSince1970: $0.wholeAt) } }

    private var songCatalogKept: SongCatalog?
    private var songCatalogName: String?
    private var songCatalogCheckedAt: Date?
    private var sortedSongs: [MusicSortOption: [MusicTopSong]] = [:]

    nonisolated static func songCatalogName(for client: SubsonicClient) -> String {
        songCatalogName(forAddress: client.baseURL)
    }

    /// The kept list's name from a server address: the client's own, or the
    /// stored one read the way the client reads it, so the list can be
    /// found while music is off on this device.
    nonisolated static func songCatalogName(forAddress url: URL) -> String {
        "song-catalog-\(PodcastIdentity.stableHash(url.absoluteString)).json"
    }

    /// The stored server address as the client would take it, or nil.
    nonisolated static var storedServerAddress: URL? {
        serverAddress(AppStorageKeys.subsonicServerURLValue)
    }

    /// A typed server address, by the client's one reading.
    nonisolated static func serverAddress(_ setting: String) -> URL? {
        SubsonicClient.address(setting)
    }

    /// The kept song list holds raw song ids. After the server gave its songs
    /// new ids it would hand out old ones for up to a week, so it goes, and
    /// the next opening loads it whole. The list is found by the stored
    /// address, so this works while music is off here.
    enum SongListDrop: Equatable {
        /// The list is gone; whether one was held.
        case dropped(held: Bool)
        /// No address to find a list by: nothing this device can drop.
        case noAddress
        /// The list stayed on the disk.
        case stayed
    }

    @discardableResult
    func forgetSongCatalog() async -> SongListDrop {
        await forgetSongCatalog(at: client?.baseURL ?? Self.storedServerAddress)
    }

    /// The same for a given address; a witness hands in its own removal
    /// (nil: the documents store).
    func forgetSongCatalog(at address: URL?,
                           removing: ((String) async throws -> Void)? = nil) async -> SongListDrop {
        guard let address else { return .noAddress }
        let name = Self.songCatalogName(forAddress: address)
        let held = songCatalogKept != nil || FileManager.default.fileExists(atPath: Ablage.documents.url(for: name).path)
        songCatalogKept = nil
        songCatalogName = nil
        songCatalogCheckedAt = nil
        sortedSongs = [:]
        do {
            if let removing {
                try await removing(name)
            } else {
                try await Ablage.documents.remove(name: name)
            }
        } catch {
            Logger.music.error("SONGS kept list not removed reason=\(FailureReason.of(error), privacy: .public)")
            return .stayed
        }
        return .dropped(held: held)
    }

    /// The kept song list's step in the Navidrome rekey pass: the list is this
    /// provider's own cache, so the provider names it. A list that stayed
    /// keeps the pass open; without an address there is no list to drop.
    static var songListRekeyStep: NavidromeRekeyRun.Step {
        NavidromeRekeyRun.Step(name: "songlist", outcome: { _ in
            Self.songListOutcome(await Self.shared.forgetSongCatalog())
        })
    }

    /// What the song list's answer means for the pass.
    nonisolated static func songListOutcome(_ drop: SongListDrop) -> NavidromeRekeyRun.Outcome {
        switch drop {
        case .dropped(let held): .done(changed: held ? 1 : 0, total: 1)
        case .noAddress: .notHere(reason: "no server address")
        case .stayed: .notNow
        }
    }

    private func songCatalog(client: SubsonicClient, opening: Bool) async throws -> SongCatalog {
        let name = Self.songCatalogName(for: client)
        if name != songCatalogName {
            songCatalogName = name
            songCatalogKept = await Ablage.documents.load(SongCatalog.self, name: name).value
            songCatalogCheckedAt = nil
            sortedSongs = [:]
        }
        if let kept = songCatalogKept, !opening { return kept }
        if let kept = songCatalogKept, let checked = songCatalogCheckedAt,
           Date().timeIntervalSince(checked) < 60 { return kept }
        let status: SubsonicScanStatus?
        do {
            status = try await client.scanStatus()
        } catch {
            // Not a failure of the list: the rule then keeps the list for a
            // day and loads it whole after that.
            Logger.music.notice("SONGS scan status not read reason=\(FailureReason.of(error), privacy: .public)")
            status = nil
        }
        let now = Date().timeIntervalSince1970
        let step = SongCatalogRule.step(kept: songCatalogKept, count: status?.count,
                                        lastScan: status?.lastScan, now: now)
        let next: SongCatalog
        do {
            switch step {
            case .keep:
                next = songCatalogKept!
            case .whole:
                next = try await wholeSongCatalog(client: client, status: status, now: now)
            case .addNew(let since):
                next = try await songCatalogAddingNew(client: client, since: since, status: status)
            }
        } catch {
            Logger.music.error("SONGS \(String(describing: step), privacy: .public) failed reason=\(FailureReason.of(error), privacy: .public) kept=\(self.songCatalogKept?.entries.count ?? 0)")
            // A kept list stays, and the page says how old it is; without
            // one the failure goes to the page as a sentence.
            if let kept = songCatalogKept { return kept }
            throw error
        }
        songCatalogCheckedAt = Date()
        if next != songCatalogKept {
            songCatalogKept = next
            sortedSongs = [:]
            do {
                try await Ablage.documents.save(next, name: name)
            } catch {
                Logger.music.error("SONGS save failed reason=\(FailureReason.of(error), privacy: .public)")
            }
        }
        Logger.music.notice("SONGS step=\(String(describing: step), privacy: .public) entries=\(next.entries.count) serverCount=\(status?.count ?? -1)")
        return next
    }

    /// Every song, page by page of `search3`. A page that fails fails the
    /// whole load: half a list is never kept as if it were the list.
    private func wholeSongCatalog(client: SubsonicClient, status: SubsonicScanStatus?,
                                  now: Double) async throws -> SongCatalog {
        let pageSize = 500
        var entries: [SongCatalog.Entry] = []
        var offset = 0
        while true {
            let page = try await client.songList(offset: offset, size: pageSize)
            entries += page.map(Self.catalogEntry(from:))
            if page.count < pageSize { break }
            offset += pageSize
        }
        return SongCatalog(entries: entries, wholeAt: now,
                           serverCount: status?.count, serverLastScan: status?.lastScan)
    }

    /// The albums added since the newest song the list holds, newest first,
    /// with their songs. More than twenty pages of new albums is a new
    /// library rather than an addition, and loads whole.
    private func songCatalogAddingNew(client: SubsonicClient, since: Double,
                                      status: SubsonicScanStatus?) async throws -> SongCatalog {
        guard let kept = songCatalogKept else {
            return try await wholeSongCatalog(client: client, status: status, now: Date().timeIntervalSince1970)
        }
        let pageSize = 50
        var fresh: [SongCatalog.Entry] = []
        for page in 0..<20 {
            let albums = try await client.albumList2(type: "newest", size: pageSize, offset: page * pageSize)
            let newer = albums.filter { (SongOrder.seconds($0.created) ?? 0) > since }
            for album in newer {
                let songs = try await client.album(id: album.id)?.song ?? []
                fresh += songs.map(Self.catalogEntry(from:))
            }
            if newer.count < albums.count || albums.count < pageSize {
                return SongCatalogRule.adding(fresh, to: kept, count: status?.count, lastScan: status?.lastScan)
            }
        }
        return try await wholeSongCatalog(client: client, status: status, now: Date().timeIntervalSince1970)
    }

    nonisolated static func catalogEntry(from song: SubsonicSong) -> SongCatalog.Entry {
        SongCatalog.Entry(id: song.id, title: song.title, artist: song.artist, album: song.album,
                          albumId: song.albumId, duration: song.duration, created: song.created,
                          played: song.played, playCount: song.playCount, coverArt: song.coverArt)
    }

    nonisolated static func topSong(from entry: SongCatalog.Entry) -> MusicTopSong {
        let item = LibraryItem(
            id: itemId(songId: entry.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: entry.title, authorName: entry.artist, narratorName: nil,
                    seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: entry.duration.map(Double.init), chapters: nil, tracks: nil),
            addedAt: nil)
        return MusicTopSong(item: item, albumName: entry.album,
                            addedAt: SongOrder.seconds(entry.created),
                            lastPlayedAt: SongOrder.seconds(entry.played),
                            playCount: entry.playCount, coverArt: entry.coverArt)
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
        #if DEBUG
        // The shuffle-badge journey needs a playable pool. The
        // seeded song stands in for any album/playlist id.
        if UITestSeed.isActive { return [UITestSeed.seedSong] }
        #endif
        guard let client else { return [] }
        var songs: [SubsonicSong] = []
        do {
            if let albumId = Self.id(itemId, kind: "album") {
                songs = try await client.album(id: albumId)?.song ?? []
            } else if let playlistId = Self.id(itemId, kind: "playlist") {
                songs = try await client.playlist(id: playlistId)?.entry ?? []
            } else if let songId = Self.id(itemId, kind: "song") {
                songs = try await client.song(id: songId).map { [$0] } ?? []
            }
        } catch {
            // The caller gets no songs and says so (`ShufflePlayButton`).
            MusicSongsFailure.log(itemId: itemId, error)
        }
        learnCovers(songs)
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    /// Shuffle-play the WHOLE library: a random pool of songs across the active
    /// server as playable items (cached like `songItems`). The final order is set
    /// by the shared `MediaShuffle` at the call site. This only supplies the pool.
    func shuffleLibrarySongItems(limit: Int = 100) async -> [LibraryItem] {
        guard let client,
              let songs = try? await client.randomSongs(size: limit,
                                                        musicFolderIds: folderScope(for: .music))
        else { return [] }
        learnCovers(songs)
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    /// OpenSubsonic lyrics for a stored song id, through the door like
    /// every stored id. Best variant as `SongLyrics`.
    func lyrics(songId: String) async -> SongLyrics? {
        guard let client else { return nil }
        return Self.songLyrics(fromStructured: (try? await client.lyrics(songId: Self.serverId(songId))) ?? [])
    }

    // MARK: - Favorites (star)

    /// Whether an album item is starred; loads the starred set once and caches it.
    func isStarred(itemId: String) async -> Bool {
        guard let albumId = Self.id(itemId, kind: "album") else { return false }
        if starredAlbumIds == nil, let client {
            starredAlbumIds = Set((try? await client.starredAlbums(
                musicFolderIds: folderScope(for: .music)))?.map(\.id) ?? [])
        }
        return starredAlbumIds?.contains(albumId) ?? false
    }

    /// Sets the album's starred state on the server; the cached set follows
    /// only what the server took.
    func setStar(itemId: String, starred: Bool) async throws {
        guard let client, let albumId = Self.id(itemId, kind: "album") else { throw SubsonicClient.SubsonicError.network }
        try await client.star(id: albumId, starred: starred)
        if starred { starredAlbumIds?.insert(albumId) } else { starredAlbumIds?.remove(albumId) }
    }


    // MARK: - Media

    func coverURL(forItemId itemId: String) -> URL? {
        coverURL(forItemId: itemId, canonical: Self.idsAreCanonical)
    }

    /// The cover address in either id form. A download's cover was kept
    /// under the address of the old form; when the download moves to the
    /// new id, its cover is renamed from the one to the other.
    func coverURL(forItemId itemId: String, canonical: Bool) -> URL? {
        guard let client, let id = Self.rawId(itemId, canonical: canonical) else { return nil }
        // A song asks the cover its server named for it; its own id only
        // while none is known.
        let cover = Self.subParts(itemId)?.kind == "song" ? (songCoverMemo.coverArt(of: id) ?? id) : id
        return client.mediaURL("getCoverArt", ["id": cover, "size": "600"])
    }

    /// What the server named as each song's cover, read once per server.
    private var songCoverStore: SongCoverArtMemo?
    private var songCoverMemo: SongCoverArtMemo {
        if let memo = songCoverStore { return memo }
        let memo = SongCoverArtMemo.load(server: Self.coverMemoServer)
        songCoverStore = memo
        return memo
    }
    nonisolated private static var coverMemoServer: String {
        "\(AppStorageKeys.subsonicServerURLValue)|\(AppStorageKeys.subsonicUsernameValue)"
    }

    /// Learns the cover each song names (`SongCoverArtMemo`), written once
    /// per answer. A song a download holds as its own entry takes its kept
    /// cover to the new address (`moveKeptCover`).
    private func learnCovers(_ songs: [SubsonicSong]) {
        learnCoverArt(songs.map { ($0.id, $0.coverArt) })
    }

    /// The same for song ids and the cover ids named for them.
    private func learnCoverArt(_ songs: [(songId: String, coverArt: String?)]) {
        guard client != nil, !songs.isEmpty else { return }
        var memo = songCoverMemo
        var changed: [(itemId: String, old: URL?, new: URL?)] = []
        let downloads = DownloadManager.shared
        for song in songs {
            let itemId = Self.itemId(songId: song.songId)
            let old = coverURL(forItemId: itemId)
            // Before the scan of the downloads every song is kept: the trim
            // cannot tell yet which cover a download holds.
            guard case .learned = memo.learn(songId: song.songId, coverArt: song.coverArt,
                                             keeps: { !downloads.hasScanned
                                                 || downloads.downloadedItemIds.contains(Self.itemId(songId: $0)) })
            else { continue }
            songCoverStore = memo
            changed.append((itemId, old, coverURL(forItemId: itemId)))
        }
        guard !changed.isEmpty else { return }
        memo.save()
        Task {
            // The downloads are known only after their scan.
            await downloads.ensureScanned()
            let moving = changed.filter { downloads.downloadedItemIds.contains($0.itemId) }
            guard !moving.isEmpty else { return }
            Logger.music.notice("COVER song downloads take their cover id: \(moving.count)")
            for move in moving { await Self.moveKeptCover(from: move.old, to: move.new) }
        }
    }

    /// Songs a pass of `learnSongCovers` is asking right now, so a card and
    /// a page showing the same list do not ask a song twice.
    private var songCoversAsking: Set<String> = []
    /// Songs the server gave no answer for in this session, skipped by the
    /// next passes. On the main actor with the provider; at most
    /// `UnansweredSongs.cap` ids, emptied on another server and on sign out.
    private var songCoversUnanswered = UnansweredSongs(server: "")
    /// How many songs one pass asks at most. Chosen: a long list learns its
    /// covers over several appearances instead of in one burst.
    static let songCoverPassLimit = 60

    /// Asks the server each song of `itemIds` whose cover it has not named
    /// yet, one `getSong` per song, and learns the answers. For entries met
    /// nowhere else, a device playlist's: their own id names no cover on
    /// every server. True when the memory learned something.
    func learnSongCovers(itemIds: [String]) async -> Bool {
        guard let client else { return false }
        let memo = songCoverMemo
        let server = Self.coverMemoServer
        songCoversUnanswered = songCoversUnanswered.belonging(to: server)
        let missing = UnansweredSongs.toAsk(itemIds.compactMap { Self.id($0, kind: "song") },
                                            known: { memo.coverArt(of: $0) != nil }, asking: songCoversAsking,
                                            unanswered: songCoversUnanswered, limit: Self.songCoverPassLimit)
        guard !missing.isEmpty else { return false }
        songCoversAsking.formUnion(missing)
        defer { songCoversAsking.subtract(missing) }
        var songs: [SubsonicSong] = []
        var silent: [String] = []
        for songId in missing where !Task.isCancelled {
            do {
                if let song = try await client.song(id: songId) {
                    songs.append(song)
                } else {
                    silent.append(songId)
                }
            } catch {
                // Only the server's own reply notes a song. A cancelled pass
                // or a question the network does not carry ends the pass and
                // notes nothing, so the rest is asked on the next appearance;
                // the log says why, a cancelled pass needs no line.
                guard SubsonicClient.isServersAnswer(error) else {
                    if !SubsonicClient.isCancellation(error) {
                        Logger.music.notice("COVER song cover pass ends reason=\(SubsonicClient.logName(error), privacy: .public)")
                    }
                    break
                }
                silent.append(songId)
            }
        }
        // A sign out or another server during the pass leaves the answers
        // to the server that was asked.
        if songCoversUnanswered.server == server { songCoversUnanswered.note(silent) }
        let before = songCoverMemo
        learnCovers(songs)
        let learned = songCoverMemo != before
        Logger.music.notice("COVER song covers asked \(missing.count), answered \(songs.count), learned \(learned)")
        return learned
    }

    /// A downloaded song's cover address changed: the kept cover takes the
    /// new address and stays the last candidate until the server's picture
    /// under it arrives (`Artwork.invalidate`), so the song never stands
    /// without its cover.
    private static func moveKeptCover(from old: URL?, to new: URL?) async {
        guard let new else { return }
        Artwork.rename(from: old, to: new)
        Artwork.invalidate(new)
        await Artwork.persist(new)
    }

    /// A download moved from the old id to the new one: its persistent cover
    /// takes the address of the new form at once, without the network (it
    /// was kept under the old form's address, which the next sweep would
    /// demote). Handed to `DownloadManager.rekey` by the rekey pass, which
    /// asks `canRenameCovers` first.
    static func renameCover(ofMovedDownload oldId: String, to newId: String) {
        let provider = shared
        guard let old = provider.coverURL(forItemId: oldId, canonical: false),
              let new = provider.coverURL(forItemId: newId, canonical: true) else {
            Logger.library.notice("REKEY cover not renamed: no cover address without the music client")
            return
        }
        Artwork.rename(from: old, to: new)
    }

    /// Whether both addresses of a moved download's cover can be built now.
    /// `coverURL(forItemId:canonical:)` builds them through the client's
    /// `mediaURL` and gives nil without a client, so no rename can happen
    /// before the music client exists.
    static var canRenameCovers: Bool { shared.client != nil }

    func streamURL(forContentPath contentPath: String) -> URL? {
        // contentPath is a Subsonic song id, possibly stored before the
        // server gave its songs new ids.
        client?.mediaURL("stream", ["id": Self.serverId(contentPath)])
    }

    // MARK: - Progress (scrobble + playlist continue-listening via bookmarks)

    /// Package 3: continue-listening for PLAYLISTS. Server bookmarks are the
    /// source of truth (cross-device); on any failure/empty we fall back to the
    /// local per-second position backups. Albums are intentionally out of scope
    /// (the architecture works for them identically. Same `sub:` mechanics).
    func fetchAllProgress() async throws -> [String: BookProgress] {
        #if DEBUG
        // The mixed-continue journey needs a seeded music entry.
        if UITestSeed.isActive { return UITestSeed.seedMusicContinue }
        #endif
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
        guard let song = ScrobbleTurn.song(at: currentTime, in: songs) else { return }
        // Scrobble once per song change (play counts), by the one rule.
        // A scrobble the server did not take is logged and asked again at the
        // next call, not booked as done.
        if let refused = await scrobbles.count(song, in: itemId, send: { try await client.scrobble(id: $0, submission: true) }) {
            Logger.music.error("SCROBBLE failed song=\(refused.song, privacy: .private(mask: .hash)) reason=\(FailureReason.of(refused.error), privacy: .public)")
        }
        // Continue-listening bookmark for playlists and albums; a Booksonic
        // book IS an album, so its stand travels between devices the same
        // way. The position is WITHIN the current
        // song (same `songsByItemId` offset arithmetic as the scrobble);
        // the item id rides in the comment as context.
        guard Self.continueScope(itemId: itemId) else { return }
        // Moving to a new song → drop the previous song's bookmark so at most one
        // lingers per item (resume is unaffected. The fetch picks the most
        // recent). Best-effort; a song shared across playlists is a rare edge.
        if let prev = lastBookmarkedSong[itemId], prev != song.id {
            try? await client.deleteBookmark(songId: prev)
        }
        lastBookmarkedSong[itemId] = song.id
        let positionMs = Int(max(0, currentTime - song.start) * 1000)
        // The line says what happened: a refused write is no write. It is not
        // thrown on: the caller's queue replays through the book server's
        // door, which is not this server's. The next call (about 30 s) writes
        // the bookmark again.
        do {
            try await client.createBookmark(songId: song.id, positionMs: positionMs, comment: Self.canonicalItemId(itemId))
            Logger.music.notice("BOOKMARK write item=\(itemId, privacy: .private(mask: .hash)) song=\(song.id, privacy: .private(mask: .hash)) pos=\(positionMs)ms")
        } catch {
            Logger.music.error("BOOKMARK write failed item=\(itemId, privacy: .private(mask: .hash)) reason=\(FailureReason.of(error), privacy: .public)")
        }
        bookmarksCache = nil   // our own write invalidates the cache
    }

    private func loadBookmarks() async throws -> [SubsonicBookmark] {
        if let cached = bookmarksCache { return cached }
        guard let client else { return [] }
        let list = try await client.getBookmarks()
        bookmarksCache = list
        return list
    }

    /// Reconstruct per-item continue progress from bookmarks: group by the
    /// item id in the comment (a playlist, an album, a Booksonic book),
    /// fetch the item's songs once so a device that never opened it can
    /// put the bookmark back on its time line, keep the most recent per
    /// item through the ONE rule `BookmarkProgressMath.resume`. A bookmark
    /// whose song is no longer in the item is cleanly dropped.
    private func playlistProgress(from bookmarks: [SubsonicBookmark]) async -> [String: BookProgress] {
        // Read once for the whole pass: a server report landing between two
        // awaits below must not give one item two forms.
        let canonical = Self.idsAreCanonical
        var byItem: [String: [SubsonicBookmark]] = [:]
        for bm in bookmarks {
            guard let comment = bm.comment, Self.continueScope(itemId: comment) else { continue }
            // An old and a new comment for one item are one item.
            byItem[Self.canonicalItemId(comment, canonical: canonical), default: []].append(bm)
        }
        var result: [String: BookProgress] = [:]
        for (itemId, bms) in byItem {
            guard let detail = try? await fetchItemDetail(itemId: itemId),
                  let songs = songsByItemId[itemId],
                  let duration = detail.media.duration, duration > 0,
                  let pick = BookmarkProgressMath.resume(bookmarks: bms, itemId: itemId,
                                                        songs: songs, stamp: Self.bookmarkStamp,
                                                        key: { Self.canonicalItemId($0, canonical: canonical) }) else { continue }
            Logger.music.notice("BOOKMARK read item=\(itemId, privacy: .private(mask: .hash)) bookmarks=\(bms.count) time=\(Int(pick.time))s by=library")
            result[itemId] = BookmarkProgressMath.progress(
                currentTime: pick.time, duration: duration, lastUpdate: pick.stamp)
        }
        return result
    }

    /// Fallback for servers without a usable bookmark API: continue progress from
    /// the per-second local position backups (written by the player) for the
    /// playlists we know. Storage TECHNIQUE mirrors `LocalProvider` (that provider
    /// stays untouched. This is a self-contained copy).
    private func localPlaylistProgress() async -> [String: BookProgress] {
        let playlists = (try? await allPlaylists()) ?? []
        var result: [String: BookProgress] = [:]
        for pl in playlists {
            let itemId = Self.itemId(playlistId: pl.id)
            result[itemId] = BookmarkProgressMath.progress(fromStand: ListeningStore.backup(itemId), duration: pl.duration)
        }
        // Albums join the local fallback. Same localPosition machinery,
        // sourced from the session's album cache.
        for album in cachedAlbumItems {
            result[album.id] = BookmarkProgressMath.progress(fromStand: ListeningStore.backup(album.id),
                                                             duration: album.media?.duration)
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
        MusicArtist(id: wire.id, itemId: itemId(artistId: wire.id), name: wire.name, albumCount: wire.albumCount)
    }

    nonisolated static func domainPlaylist(_ wire: SubsonicPlaylist) -> MusicPlaylist {
        MusicPlaylist(
            id: wire.id, itemId: itemId(playlistId: wire.id), name: wire.name, songCount: wire.songCount,
            duration: wire.duration.map(Double.init),
            changedAt: PlaylistPresentation.changedDate(wire.changed)
                .map { $0.timeIntervalSince1970 * 1000 })
    }

    nonisolated static func domainArtistInfo(_ wire: SubsonicArtistInfo) -> MusicArtistInfo {
        MusicArtistInfo(
            biography: wire.biography,
            // The hero renders ONE image. Take the largest the server offers.
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
    nonisolated static func itemId(artistId: String) -> String { "sub:artist:\(artistId)" }

    /// Whether this item id belongs to the Subsonic music namespace. Gates the
    /// music-only "Add to Playlist" action (albums/songs/playlists are `sub:…`).
    nonisolated static func owns(itemId: String) -> Bool { itemId.hasPrefix("sub:") }

    /// Extracts the raw id for a given kind ("album"/"playlist") from `sub:<kind>:<id>`,
    /// in the form the server answers to (`serverId`).
    nonisolated static func id(_ itemId: String, kind: String, canonical: Bool = idsAreCanonical) -> String? {
        guard let parts = subParts(itemId), parts.kind == kind else { return nil }
        return serverId(parts.raw, canonical: canonical)
    }

    /// The one reading of a `sub:` item id: its kind and its raw part, the
    /// raw part whole even when it holds a colon. Nil for any other id and
    /// for an empty raw part: `sub:playlist:` names nothing, on every way.
    nonisolated static func subParts(_ itemId: String) -> (kind: String, raw: String)? {
        guard itemId.hasPrefix("sub:") else { return nil }
        let parts = itemId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[2].isEmpty else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    /// The bare id after `sub:<kind>:` regardless of kind (for cover art),
    /// in the form the server answers to.
    nonisolated private static func rawId(_ itemId: String, canonical: Bool = idsAreCanonical) -> String? {
        subParts(itemId).map { serverId($0.raw, canonical: canonical) }
    }

    /// The door every stored id passes on its way to the server. Navidrome
    /// 0.64 recomputes every id it hands out (songs, albums, artists,
    /// playlists and the rest) from the old one, and answers an old one with
    /// error 70; a store written before the
    /// update keeps the old ones. On a new id the rule is the identity, so
    /// passing through it twice changes nothing.
    nonisolated static func serverId(_ raw: String, canonical: Bool = idsAreCanonical) -> String {
        canonical ? NavidromeID.canonical(raw) : raw
    }

    /// A `sub:` item id with its raw part in the form the server answers to;
    /// any other id unchanged. Where an id is compared rather than sent (a
    /// bookmark's comment), both sides take this form.
    nonisolated static func canonicalItemId(_ itemId: String, canonical: Bool = idsAreCanonical) -> String {
        guard let parts = subParts(itemId) else { return itemId }
        return "sub:\(parts.kind):\(serverId(parts.raw, canonical: canonical))"
    }

    /// Whether the server set up here is a Navidrome with the new ids, by
    /// the type and version it last reported about itself.
    nonisolated static var idsAreCanonical: Bool {
        guard let server = configuredServerKey else { return false }
        return NavidromeIDRule.applies(type: SubsonicClient.reportedType(server: server),
                                       version: SubsonicClient.reportedVersion(server: server))
    }

    /// Whether rounds that carry the music server's ids may run: no server
    /// set up here (nothing to answer to), or the rule of `idsAreCanonical`
    /// is decided (type, and for Navidrome the version), or the wait is
    /// over (`NavidromeIDRule.formSettled`: a request ended without
    /// teaching the form, or `idFormWaitLimit` seconds passed). Right after
    /// a new address and before its first answer the rule reads "old ids"
    /// whatever the server is; once the wait is over the form stands as it is.
    nonisolated static func idFormSettled(now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let server = configuredServerKey else { return true }
        let decided = NavidromeIDRule.isDecided(type: SubsonicClient.reportedType(server: server),
                                                version: SubsonicClient.reportedVersion(server: server))
        if decided { return true }
        let wait = SubsonicClient.formWait(server: server, now: now)
        return NavidromeIDRule.formSettled(decided: false, attemptEnded: wait.attemptEnded,
                                           waited: wait.waited, limit: idFormWaitLimit)
    }

    /// How long rounds wait at most for a new address to name its form.
    /// Chosen, not measured: long enough for the first answer of a slow
    /// server, short enough that a family never waits for long.
    nonisolated static let idFormWaitLimit: Double = 120

    /// The key of the server set up here (host and path), or nil without one
    /// the client could take.
    nonisolated static var configuredServerKey: String? {
        storedServerAddress.map(SubsonicClient.serverKey(for:))
    }

    /// ISO-8601 `created` → epoch ms (matches ABS `addedAt`), for "Recently Added".
    /// Navidrome sends fractional seconds; `ServerTimestamp` reads both forms.
    nonisolated private static func parseCreated(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return ServerTimestamp.milliseconds(raw)
    }
}

// MARK: - Global search (SearchableProvider)

extension SubsonicProvider {
    /// Artists seen through search. The artist route needs the domain value.
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
    nonisolated func itemId(artistId: String) -> String { Self.itemId(artistId: artistId) }
    nonisolated func artistId(fromItemId itemId: String) -> String? { Self.id(itemId, kind: "artist") }
}

extension SubsonicProvider: SearchableProvider {
    @MainActor
    func search(query: String) async throws -> [SearchResult] {
        #if DEBUG
        if UITestSeed.isActive {
            // Seeded stock, no server. Albums/songs from the item cache plus
            // the seeded playlists through the SAME local name filter, so the
            // journey can assert all four music sections.
            return offlineSearch(query) + UITestSeed.seedPlaylists
                .filter { PodcastLocalSearch.matches($0.name ?? "", query) }
                .map { list in
                    SearchResult(id: Self.itemId(playlistId: list.id), kind: .playlist,
                                 title: list.name ?? "")
                }
        }
        #endif
        guard let client, await Reachability.isConnected() else { return offlineSearch(query) }
        let hits = try await client.search3(query: query,
                                           musicFolderIds: folderScope(for: .music))
        var out: [SearchResult] = []
        learnCovers(hits.song ?? [])
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
        // Search3 ships NO playlists. Filter the (junk-cleaned) playlist
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
