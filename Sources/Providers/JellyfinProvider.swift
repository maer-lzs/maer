// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import OSLog

/// Second `MusicProvider` implementation (Etappe 2): Jellyfin, music scope
/// only (albums/artists/songs/playlists/covers/search/lyrics/favorites).
/// ID namespace `jf:album:` / `jf:song:` / `jf:playlist:` / `jf:artist:` —
/// same scheme as Subsonic's `sub:…`. Audiobooks are deliberately NOT in this
/// stage (different progress semantics, own step per the roadmap).
///
/// Positions-sync: Jellyfin has no bookmark API for per-song positions, so
/// playlist continue-listening uses the LOCAL position backups only (the same
/// fallback path Subsonic uses when its bookmark API is unusable) — noted in
/// the report, no capability change needed.
@MainActor
final class JellyfinProvider: AudioProvider, MusicProvider {
    static let shared = JellyfinProvider()
    private init() { reloadConfig() }

    private var client: JellyfinClient?

    /// Same session caches as the Subsonic provider (Up-Next resolution,
    /// scrobble bookkeeping, artist route).
    var itemsById: [String: LibraryItem] = [:]
    var searchedArtistsById: [String: MusicArtist] = [:]
    private var songsByItemId: [String: [(id: String, start: Double)]] = [:]
    private var lastScrobbledSong: [String: String] = [:]
    private var favoriteAlbumIds: Set<String>?
    private var playlistMosaicCache: [String: [String]] = [:]

    var providerId: String { "jf" }
    var mediaType: MediaType { .music }
    var capabilities: ProviderCapabilities { [.passwordLogin, .remoteSearch, .downloadable] }
    var streamAuthHeaders: [String: String] { [:] }

    var isAvailable: Bool {
        AppStorageKeys.jellyfinActive && client != nil
    }

    /// Rebuild the client from the stored settings (TF bib-toggles: nil when
    /// the source is not effectively active, so ALL calls stop).
    func reloadConfig() {
        if AppStorageKeys.jellyfinActive, !AppStorageKeys.jellyfinServerURLValue.isEmpty {
            let client = JellyfinClient(
                serverURL: AppStorageKeys.jellyfinServerURLValue,
                username: AppStorageKeys.jellyfinUsernameValue,
                password: AppStorageKeys.jellyfinPasswordValue,
                deviceId: AppStorageKeys.jellyfinDeviceIdValue,
                accessToken: AppStorageKeys.jellyfinTokenValue.isEmpty ? nil : AppStorageKeys.jellyfinTokenValue,
                userId: AppStorageKeys.jellyfinUserIdValue.isEmpty ? nil : AppStorageKeys.jellyfinUserIdValue)
            client.onTokenRefresh = { token, userId in
                AppStorageKeys.setJellyfinToken(token)
                AppStorageKeys.jellyfinUserIdValue = userId
            }
            self.client = client
        } else {
            client = nil
        }
        Logger.music.notice("jellyfin config reloaded (active=\(AppStorageKeys.jellyfinActive), client=\(self.client != nil))")
        AppSession.shared.notifySourcesChanged()
    }

    func reconnectIfNeeded() {
        if !isAvailable, AppStorageKeys.jellyfinEnabledValue { reloadConfig() }
    }

    func testConnection() async -> String? {
        reloadConfig()
        guard let client else { return String(localized: "Enter server, username and password.") }
        return await client.testConnection()
    }

    let librarySynced = PassthroughSubject<Void, Never>()
    var historyStore: any SyncHistoryStoring = SyncHistoryStore.shared

    /// Visible library refresh (sync parity with the other sources).
    func syncLibraryNow() async -> String? {
        guard let client else {
            Logger.music.error("jellyfin sync pressed but no client (URL/user missing)")
            return String(localized: "Enter server, username and password.")
        }
        let started = Date()
        do {
            let albums = try await client.albums(sortBy: "SortName")
            remember(albums.map(Self.libraryItem(fromAlbum:)))
            historyStore.append(SyncHistory.entry(
                service: .music, direction: .down,
                counters: [.init(key: .albumsUpdated, value: albums.count)],
                duration: Date().timeIntervalSince(started),
                deviceId: SyncHistoryStore.deviceId, startedAt: started))
            Logger.music.notice("jellyfin sync ok: \(albums.count) albums")
            librarySynced.send()
            return nil
        } catch {
            let message = error.localizedDescription
            historyStore.append(SyncHistory.entry(
                service: .music, direction: .down, counters: [],
                duration: Date().timeIntervalSince(started), error: message,
                deviceId: SyncHistoryStore.deviceId, startedAt: started))
            Logger.music.error("jellyfin sync failed: \(message, privacy: .public)")
            return message
        }
    }

    // MARK: - Library (AudioProvider)

    func fetchLibraries() async throws -> [ABSLibrary] {
        [ABSLibrary(id: "jf", name: String(localized: "Music"), mediaType: "music")]
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        let albums = try await client.albums(sortBy: "SortName")
        historyStore.noteChecked(.music)
        return remember(albums.map(Self.libraryItem(fromAlbum:)))
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        guard let client else { throw JellyfinClient.JellyfinError.network }
        let songs: [JFItem]
        let title: String?
        let artist: String?
        let genre: String?
        var year: Int?
        if let albumId = Self.id(itemId, kind: "album") {
            songs = try await client.albumSongs(albumId: albumId)
            let album = try? await client.item(id: albumId)
            title = album?.name; artist = album?.albumArtist ?? songs.first?.albumArtist
            genre = album?.genres?.first; year = album?.productionYear
        } else if let playlistId = Self.id(itemId, kind: "playlist") {
            songs = try await client.playlistSongs(playlistId: playlistId)
            let pl = try? await client.item(id: playlistId)
            title = pl?.name; artist = nil; genre = nil
        } else if let songId = Self.id(itemId, kind: "song"), let song = try await client.item(id: songId) {
            songs = [song]; title = song.name; artist = song.artists?.first; genre = nil
        } else {
            throw JellyfinClient.JellyfinError.decoding
        }
        let (tracks, chapters, total) = Self.tracksAndChapters(from: songs)
        songsByItemId[itemId] = tracks.map { ($0.contentUrl, $0.startOffset ?? 0) }
        lastScrobbledSong[itemId] = nil
        let media = LibraryItemMedia(
            metadata: LibraryItemMetadata(
                title: title, authorName: artist, narratorName: nil,
                seriesName: nil, genres: genre.map { [$0] },
                publishedYear: year.map { LenientString(String($0)) },
                description: nil
            ),
            duration: total, chapters: chapters, tracks: tracks
        )
        itemsById[itemId] = LibraryItem(id: itemId, media: media, addedAt: nil)
        return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
    }

    @discardableResult
    private func remember(_ items: [LibraryItem]) -> [LibraryItem] {
        for item in items { itemsById[item.id] = item }
        return items
    }

    func libraryItem(forId itemId: String) -> LibraryItem? { itemsById[itemId] }

    var cachedAlbumItems: [LibraryItem] {
        itemsById.values.filter { Self.id($0.id, kind: "album") != nil }
    }

    // MARK: - Media URLs

    func coverURL(forItemId itemId: String) -> URL? {
        guard let client, let raw = Self.rawId(itemId) else { return nil }
        return client.imageURL(itemId: raw, maxWidth: 600)
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        client?.streamURL(songId: contentPath)
    }

    func coverURL(coverArtId: String, size: Int) -> URL? {
        client?.imageURL(itemId: coverArtId, maxWidth: size)
    }

    // MARK: - Albums

    /// The neutral shelf → Jellyfin SortBy/SortOrder mapping.
    nonisolated static func shelfSort(for shelf: MusicShelf) -> (by: String, order: String) {
        switch shelf {
        case .newest: return ("DateCreated", "Descending")
        case .frequent: return ("PlayCount", "Descending")
        case .recent: return ("DatePlayed", "Descending")
        case .byArtist: return ("AlbumArtist,SortName", "Ascending")
        case .alphabetical: return ("SortName", "Ascending")
        }
    }

    func albumShelf(shelf: MusicShelf, size: Int) async throws -> [LibraryItem] {
        guard let client else { return [] }
        let sort = Self.shelfSort(for: shelf)
        let albums = try await client.albums(sortBy: sort.by, sortOrder: sort.order, limit: size)
        return remember(albums.map(Self.libraryItem(fromAlbum:)))
    }

    func albumPage(sort: MusicSortOption, offset: Int, size: Int) async throws -> [LibraryItem] {
        guard let client else { return [] }
        let mapped = Self.shelfSort(for: sort.shelf)
        let albums = try await client.albums(sortBy: mapped.by, sortOrder: mapped.order,
                                             startIndex: offset, limit: size)
        return remember(albums.map(Self.libraryItem(fromAlbum:)))
    }

    func albumInfo(itemId: String) async -> MusicAlbumInfo? {
        guard let client, let albumId = Self.id(itemId, kind: "album"),
              let album = try? await client.item(id: albumId) else { return nil }
        // Jellyfin exposes no MusicBrainz id on the item by default — notes only.
        guard let overview = album.overview, !overview.isEmpty else { return nil }
        return MusicAlbumInfo(notes: overview, musicBrainzId: nil)
    }

    // MARK: - Artists

    func allArtists() async throws -> [MusicArtist] {
        guard let client else { return [] }
        return try await client.artists().map(Self.domainArtist)
    }

    func artistAlbums(artistId: String) async throws -> [LibraryItem] {
        guard let client else { return [] }
        return remember(try await client.artistAlbums(artistId: artistId).map(Self.libraryItem(fromAlbum:)))
    }

    func artist(forId id: String) -> MusicArtist? { searchedArtistsById[id] }

    func cacheSearchedArtist(_ artist: MusicArtist) { searchedArtistsById[artist.id] = artist }

    func artistInfo(artistId: String) async -> MusicArtistInfo? {
        guard let client, let item = try? await client.item(id: artistId) else { return nil }
        let bio = (item.overview?.isEmpty == false) ? item.overview : nil
        let image = client.imageURL(itemId: artistId, maxWidth: 600)
        guard bio != nil || image != nil else { return nil }
        // Similar artists: no cheap Jellyfin equivalent in scope — empty is
        // normal, the section simply doesn't appear.
        return MusicArtistInfo(biography: bio, imageURL: image, similarArtistNames: [])
    }

    func topSongs(artistId: String, count: Int) async -> [MusicTopSong] {
        guard let client, let songs = try? await client.topSongs(artistId: artistId, limit: count)
        else { return [] }
        let result = songs.map { MusicTopSong(item: Self.songItem(from: $0), albumName: $0.album) }
        for entry in result { itemsById[entry.item.id] = entry.item }
        return result
    }

    // MARK: - Playlists

    func allPlaylists() async throws -> [MusicPlaylist] {
        guard let client else { return [] }
        return try await client.playlists().map(Self.domainPlaylist)
    }

    func createPlaylist(name: String) async throws -> String? {
        guard let client else { return nil }
        return (try await client.createPlaylist(name: name)).map { Self.itemId(playlistId: $0) }
    }

    func addSongs(_ songIds: [String], toPlaylistItemId playlistItemId: String) async throws {
        guard let client, let rawId = Self.id(playlistItemId, kind: "playlist"), !songIds.isEmpty else { return }
        try await client.addToPlaylist(playlistId: rawId, songIds: songIds)
        playlistMosaicCache[rawId] = nil
    }

    func songIds(forItemId itemId: String) async -> [String] {
        if let songId = Self.id(itemId, kind: "song") { return [songId] }
        if let cached = songsByItemId[itemId] { return cached.map(\.id) }
        _ = try? await fetchItemDetail(itemId: itemId)
        return songsByItemId[itemId]?.map(\.id) ?? []
    }

    func songId(forItemId itemId: String, trackIndex: Int) async -> String? {
        if songsByItemId[itemId] == nil { _ = try? await fetchItemDetail(itemId: itemId) }
        guard let songs = songsByItemId[itemId], songs.indices.contains(trackIndex) else { return nil }
        return songs[trackIndex].id
    }

    func playlistMosaicCoverIDs(forItemId itemId: String) async -> [String] {
        guard let client, let rawId = Self.id(itemId, kind: "playlist") else { return [] }
        if let cached = playlistMosaicCache[rawId] { return cached }
        guard let songs = try? await client.playlistSongs(playlistId: rawId) else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for song in songs {
            guard let albumId = song.albumId, seen.insert(albumId).inserted else { continue }
            ids.append(albumId)
            if ids.count == 4 { break }
        }
        playlistMosaicCache[rawId] = ids
        return ids
    }

    // MARK: - Shuffle / queue material

    func songItems(forItemId itemId: String) async -> [LibraryItem] {
        guard let client else { return [] }
        let songs: [JFItem]
        if let albumId = Self.id(itemId, kind: "album") {
            songs = (try? await client.albumSongs(albumId: albumId)) ?? []
        } else if let playlistId = Self.id(itemId, kind: "playlist") {
            songs = (try? await client.playlistSongs(playlistId: playlistId)) ?? []
        } else if let songId = Self.id(itemId, kind: "song"), let song = try? await client.item(id: songId) {
            songs = [song]
        } else {
            songs = []
        }
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    func shuffleLibrarySongItems(limit: Int) async -> [LibraryItem] {
        guard let client, let songs = try? await client.randomSongs(limit: limit) else { return [] }
        let items = songs.map(Self.songItem(from:))
        for item in items { itemsById[item.id] = item }
        return items
    }

    // MARK: - Lyrics

    func lyrics(songId: String) async -> SongLyrics? {
        guard let client, let response = try? await client.lyrics(songId: songId) else { return nil }
        return Self.songLyrics(from: response)
    }

    // MARK: - Favorites

    func isStarred(itemId: String) async -> Bool {
        guard let albumId = Self.id(itemId, kind: "album") else { return false }
        if favoriteAlbumIds == nil, let client {
            favoriteAlbumIds = Set((try? await client.favoriteAlbums())?.map(\.id) ?? [])
        }
        return favoriteAlbumIds?.contains(albumId) ?? false
    }

    @discardableResult
    func toggleStar(itemId: String) async -> Bool {
        guard let client, let albumId = Self.id(itemId, kind: "album") else { return false }
        let newValue = !(favoriteAlbumIds?.contains(albumId) ?? false)
        try? await client.setFavorite(itemId: albumId, on: newValue)
        if newValue { favoriteAlbumIds?.insert(albumId) } else { favoriteAlbumIds?.remove(albumId) }
        return newValue
    }

    // MARK: - Progress (scrobble; playlist continue = local backups only)

    func fetchAllProgress() async throws -> [String: BookProgress] {
        guard client != nil else { return [:] }
        let playlists = (try? await allPlaylists()) ?? []
        var result: [String: BookProgress] = [:]
        for pl in playlists {
            let itemId = Self.itemId(playlistId: pl.id)
            guard let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(itemId)) as? [Double],
                  stored.count == 2, let duration = pl.duration, duration > 0 else { continue }
            result[itemId] = BookmarkProgressMath.progress(
                currentTime: stored[0], duration: duration, lastUpdate: stored[1])
        }
        return result
    }

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        guard let client, let songs = songsByItemId[itemId], !songs.isEmpty else { return }
        guard let song = songs.last(where: { $0.start <= currentTime + 0.5 }) else { return }
        if song.id != lastScrobbledSong[itemId] {
            lastScrobbledSong[itemId] = song.id
            // Best-effort play-count bump; failures may not surface in the UI.
            try? await client.markPlayed(itemId: song.id)
        }
    }

    // MARK: - Bookmarks (unsupported — no capability)

    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
    func createBookmark(itemId: String, time: Double, title: String) async throws {}
    func deleteBookmark(itemId: String, time: Double) async throws {}

    // MARK: - Wire → domain mapping (pure, tested)

    nonisolated static func seconds(fromTicks ticks: Double?) -> Double? {
        ticks.map { $0 / 10_000_000 }
    }

    /// Jellyfin `DateCreated` → epoch ms. The 7-digit fraction Jellyfin sends
    /// is trimmed to 3 digits (ISO8601DateFormatter's supported shape).
    nonisolated static func epochMs(fromJFDate raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        var normalized = raw
        if let dot = raw.firstIndex(of: ".") {
            let fraction = raw[raw.index(after: dot)...].prefix(while: \.isNumber)
            let suffix = raw[raw.index(dot, offsetBy: fraction.count + 1)...]
            normalized = String(raw[..<dot]) + "." + fraction.prefix(3) + String(suffix)
        }
        return PlaylistPresentation.changedDate(normalized).map { $0.timeIntervalSince1970 * 1000 }
    }

    nonisolated static func libraryItem(fromAlbum album: JFItem) -> LibraryItem {
        LibraryItem(
            id: itemId(albumId: album.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: album.name, authorName: album.albumArtist ?? album.artists?.first,
                    narratorName: nil, seriesName: nil,
                    genres: album.genres?.isEmpty == false ? album.genres : nil,
                    publishedYear: album.productionYear.map { LenientString(String($0)) },
                    description: nil
                ),
                duration: seconds(fromTicks: album.runTimeTicks),
                chapters: nil, tracks: nil
            ),
            addedAt: epochMs(fromJFDate: album.dateCreated)
        )
    }

    nonisolated static func songItem(from song: JFItem) -> LibraryItem {
        LibraryItem(
            id: itemId(songId: song.id),
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(
                    title: song.name, authorName: song.artists?.first ?? song.albumArtist,
                    narratorName: nil, seriesName: nil, genres: nil,
                    publishedYear: nil, description: nil),
                duration: seconds(fromTicks: song.runTimeTicks), chapters: nil, tracks: nil),
            addedAt: nil)
    }

    nonisolated static func domainArtist(_ item: JFItem) -> MusicArtist {
        MusicArtist(id: item.id, name: item.name, albumCount: item.childCount)
    }

    nonisolated static func domainPlaylist(_ item: JFItem) -> MusicPlaylist {
        MusicPlaylist(
            id: item.id, name: item.name, songCount: item.childCount,
            duration: seconds(fromTicks: item.runTimeTicks),
            changedAt: epochMs(fromJFDate: item.dateCreated))
    }

    nonisolated static func songLyrics(from response: JFLyricsResponse) -> SongLyrics? {
        guard let rawLines = response.lyrics, !rawLines.isEmpty else { return nil }
        let synced = response.metadata?.isSynced == true
        let lines = rawLines.compactMap { line -> LyricsLine? in
            guard let text = line.text else { return nil }
            return LyricsLine(start: synced ? seconds(fromTicks: line.start) : nil, text: text)
        }
        guard !lines.isEmpty else { return nil }
        return SongLyrics(synced: synced, lines: lines)
    }

    private static func tracksAndChapters(from songs: [JFItem])
        -> (tracks: [ABSAudioTrack], chapters: [ABSChapter], total: Double) {
        MusicTrackAssembly.build(songs.map {
            MusicTrackAssembly.Song(id: $0.id, title: $0.name,
                                    duration: seconds(fromTicks: $0.runTimeTicks) ?? 0, size: nil)
        })
    }

    // MARK: - Id namespace

    nonisolated static func itemId(albumId: String) -> String { "jf:album:\(albumId)" }
    nonisolated static func itemId(playlistId: String) -> String { "jf:playlist:\(playlistId)" }
    nonisolated static func itemId(songId: String) -> String { "jf:song:\(songId)" }

    nonisolated static func owns(itemId: String) -> Bool { itemId.hasPrefix("jf:") }

    nonisolated static func id(_ itemId: String, kind: String) -> String? {
        let prefix = "jf:\(kind):"
        guard itemId.hasPrefix(prefix) else { return nil }
        return String(itemId.dropFirst(prefix.count))
    }

    nonisolated private static func rawId(_ itemId: String) -> String? {
        guard itemId.hasPrefix("jf:") else { return nil }
        let raw = itemId.split(separator: ":", omittingEmptySubsequences: false).dropFirst(2).joined(separator: ":")
        return raw.isEmpty ? nil : raw
    }

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
    nonisolated func itemId(artistId: String) -> String { "jf:artist:\(artistId)" }
    nonisolated func artistId(fromItemId itemId: String) -> String? { Self.id(itemId, kind: "artist") }
}

// MARK: - F6 global search

extension JellyfinProvider: SearchableProvider {
    @MainActor
    func search(query: String) async throws -> [SearchResult] {
        guard let client, NetworkMonitor.shared.isConnected else { return offlineSearch(query) }
        let hits = try await client.search(term: query)
        var out: [SearchResult] = []
        for hit in hits {
            guard let name = hit.name else { continue }
            switch hit.type {
            case "MusicArtist":
                searchedArtistsById[hit.id] = Self.domainArtist(hit)
                out.append(SearchResult(
                    id: itemId(artistId: hit.id), kind: .artist, title: name,
                    coverURL: coverURL(forItemId: itemId(artistId: hit.id))))
            case "MusicAlbum":
                let item = Self.libraryItem(fromAlbum: hit)
                itemsById[item.id] = item
                out.append(SearchResult(
                    id: item.id, kind: .album, title: item.title,
                    subtitle: hit.albumArtist, coverURL: coverURL(forItemId: item.id)))
            case "Audio":
                let item = Self.songItem(from: hit)
                if itemsById[item.id] == nil { itemsById[item.id] = item }
                out.append(SearchResult(
                    id: item.id, kind: .song, title: name,
                    subtitle: hit.artists?.first, coverURL: coverURL(forItemId: item.id)))
            default:
                continue
            }
        }
        return out
    }

    private func offlineSearch(_ query: String) -> [SearchResult] {
        itemsById.values.compactMap { item in
            guard PodcastLocalSearch.matches(item.title, query)
                || (item.author.map { PodcastLocalSearch.matches($0, query) } ?? false)
            else { return nil }
            let kind: SearchResult.Kind = item.id.hasPrefix("jf:song:") ? .song : .album
            return SearchResult(
                id: item.id, kind: kind, title: item.title,
                subtitle: item.author, coverURL: coverURL(forItemId: item.id),
                isPlayableNow: DownloadManager.shared.isDownloaded(itemId: item.id))
        }
    }
}
