// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import CryptoKit
import OSLog

/// Talks to a Subsonic-compatible server (Navidrome, Gonic, Airsonic, …). Auth
/// is per-request via query params `u` (user), `t` (token = md5(password+salt)),
/// `s` (salt) — no session/cookie. Deliberately thin: fetches JSON, unwraps the
/// `subsonic-response` body, maps API errors. The provider maps the models onto
/// the shared `LibraryItem` domain.
struct SubsonicClient {
    let baseURL: URL
    let username: String
    private let password: String

    /// API version we speak and a stable client name (both required by the API).
    /// Booksonic compat (170ff18): the version NEGOTIATES — Booksonic-Air
    /// answers 1.16.1 with error 30 on EVERY call; on that error we retry
    /// once with the fallback and persist the choice per server host.
    private static let preferredVersion = "1.16.1"
    private static let fallbackVersion = "1.15.0"
    private let clientName = "Maer"

    private var apiVersion: String {
        Self.negotiatedVersion(host: baseURL.host ?? "") ?? Self.preferredVersion
    }

    nonisolated static func negotiatedVersion(host: String) -> String? {
        UserDefaults.standard.string(forKey: "subsonicApiVersion.\(host)")
    }

    nonisolated static func persistNegotiated(_ version: String, host: String) {
        UserDefaults.standard.set(version, forKey: "subsonicApiVersion.\(host)")
    }

    init?(serverURL: String, username: String, password: String) {
        let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil,
              !username.isEmpty else { return nil }
        self.baseURL = url
        self.username = username
        self.password = password
    }

    enum SubsonicError: LocalizedError {
        case badURL
        case network
        case api(code: Int, message: String?)
        case decoding

        var errorDescription: String? {
            switch self {
            case .badURL: return String(localized: "Invalid server URL.")
            case .network: return String(localized: "Cannot reach the server.")
            case .api(let code, let message):
                if code == 40 { return String(localized: "Wrong username or password.") }
                return message ?? String(localized: "Server error (\(code)).")
            case .decoding: return String(localized: "Unexpected server response.")
            }
        }
    }

    // MARK: - Requests

    /// Builds `<base>/rest/<endpoint>.view` with auth + JSON params. A fresh salt
    /// per call keeps the token from being replayable.
    private func requestURL(_ endpoint: String, _ params: [String: String] = [:],
                            extraItems: [URLQueryItem] = []) -> URL? {
        let salt = Self.randomSalt()
        let token = Self.md5Hex(password + salt)
        var comps = URLComponents(url: baseURL.appendingPathComponent("rest/\(endpoint).view"),
                                  resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value) })
        items.append(contentsOf: extraItems)
        comps?.queryItems = items
        return comps?.url
    }

    /// Media URL (stream / cover) — same auth params, but returned for AVPlayer /
    /// image loading instead of decoded. `f=json` is harmless on binary endpoints.
    func mediaURL(_ endpoint: String, _ params: [String: String]) -> URL? {
        requestURL(endpoint, params)
    }

    /// Pure: is this a cancellation (task layer or URL layer)? Cancellations
    /// propagate untranslated — never mapped to `SubsonicError.network`.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func get(_ endpoint: String, _ params: [String: String] = [:],
                     extraItems: [URLQueryItem] = []) async throws -> SubsonicBody {
        // Y39: retry parity with the ABS client — transient failures and the
        // 401 probe run INSIDE the shared policy fetch; on top the Subsonic
        // specialty: auth errors arrive as API code 40/41 in a 200 envelope,
        // so those get the SAME single probe before they count.
        var envelopeAuthAttempt = 0
        var versionRetried = false
        while true {
            // URL builds PER attempt — a version renegotiation must apply.
            guard let url = requestURL(endpoint, params, extraItems: extraItems) else { throw SubsonicError.badURL }
            let data: Data
            let http: HTTPURLResponse?
            do {
                (data, http) = try await RequestRetryPolicy.fetch(URLRequest(url: url))
            } catch {
                // Cancellation is never a domain error: a request torn down
                // because the user scrolled away must not surface as a
                // "network error" in the UI. Propagate it untranslated.
                if Self.isCancellation(error) { throw error }
                throw SubsonicError.network
            }
            if let status = http?.statusCode, !(200...299).contains(status) {
                // Survived the policy (incl. the HTTP-401 probe) — final.
                throw status == 401
                    ? SubsonicError.api(code: 40, message: nil)
                    : SubsonicError.network
            }
            // Decode off-main — album catalogs are large and this used to run on
            // the main actor (project default isolation). Same pattern as APIClient.
            guard let env = try? await Task.detached(priority: .userInitiated, operation: {
                // Regression guard: envelope decode stays off the main actor.
                #if DEBUG
                dispatchPrecondition(condition: .notOnQueue(.main))
                #endif
                return try JSONDecoder().decode(SubsonicEnvelope.self, from: data)
            }).value else {
                throw SubsonicError.decoding
            }
            let body = env.subsonicResponse
            if let err = body.error {
                // Error 30 = incompatible protocol version (Booksonic caps at
                // 1.15.0): negotiate down ONCE, persist per host, retry.
                if err.code == 30, !versionRetried, apiVersion == Self.preferredVersion {
                    versionRetried = true
                    Self.persistNegotiated(Self.fallbackVersion, host: baseURL.host ?? "")
                    Logger.music.notice("subsonic version negotiated down to \(Self.fallbackVersion) for \(self.baseURL.host ?? "?", privacy: .public)")
                    continue
                }
                if case .retry(let ms) = RequestRetryPolicy.subsonicDecision(
                    apiCode: err.code, attempt: envelopeAuthAttempt) {
                    envelopeAuthAttempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    continue
                }
                throw SubsonicError.api(code: err.code, message: err.message)
            }
            guard body.status == "ok" else {
                throw SubsonicError.api(code: -1, message: body.status)
            }
            return body
        }
    }

    // MARK: - Endpoints

    /// Connectivity + credential check.
    func ping() async throws {
        _ = try await get("ping")
    }

    /// The server's top-level music folders. Everything else about the library
    /// assignment hangs off this answer, so an empty list means exactly "this
    /// server reports no folders" — never "we did not ask".
    func musicFolders() async throws -> [SourceLibrary] {
        let body = try await get("getMusicFolders")
        return (body.musicFolders?.musicFolder ?? []).compactMap { folder in
            guard let id = folder.id?.value else { return nil }
            return SourceLibrary(id: id, name: folder.name ?? id)
        }
    }

    /// The endpoints below narrow to ONE folder at a time (`musicFolderId`,
    /// API 1.11.0/1.12.0). A type can be fed by several folders, so the union is
    /// assembled here — never by quietly using the first and dropping the rest.
    /// An empty list means "do not narrow", which is the whole-server answer.
    private func merging<T>(_ musicFolderIds: [String],
                            _ call: (String?) async throws -> [T]) async throws -> [T] {
        guard !musicFolderIds.isEmpty else { return try await call(nil) }
        var out: [T] = []
        for folderId in musicFolderIds { out += try await call(folderId) }
        return out
    }

    /// A page of albums. `type`: newest | recent | frequent | alphabeticalByName …
    func albumList2(type: String, size: Int = 100, offset: Int = 0,
                    musicFolderIds: [String] = []) async throws -> [SubsonicAlbum] {
        try await merging(musicFolderIds) { folderId in
            var params = ["type": type, "size": String(size), "offset": String(offset)]
            if let folderId { params["musicFolderId"] = folderId }
            return try await get("getAlbumList2", params).albumList2?.album ?? []
        }
    }

    /// One album with its track list.
    func album(id: String) async throws -> SubsonicAlbum? {
        try await get("getAlbum", ["id": id]).album
    }

    /// All artists (indexed A–Z).
    func artists() async throws -> [SubsonicArtist] {
        let body = try await get("getArtists")
        return (body.artists?.index ?? []).flatMap { $0.artist ?? [] }
    }

    /// One artist with its albums.
    func artist(id: String) async throws -> SubsonicArtist? {
        try await get("getArtist", ["id": id]).artist
    }

    /// Alphabetical song list page (music tab "Titles" entry). Subsonic has no
    /// dedicated all-songs endpoint; `search3` with an empty query is the
    /// de-facto standard for it (Navidrome & co. return the full library).
    func songList(offset: Int, size: Int) async throws -> [SubsonicSong] {
        let body = try await get("search3", [
            "query": "",
            "albumCount": "0",
            "artistCount": "0",
            "songCount": String(size),
            "songOffset": String(offset),
        ])
        return body.searchResult3?.song ?? []
    }

    /// M3: server genres with song/album counters (getGenres).
    func genres() async throws -> [SubsonicGenre] {
        try await get("getGenres").genres?.genre ?? []
    }

    /// M3: albums of ONE genre (getAlbumList2 type=byGenre).
    func albumsByGenre(genre: String, size: Int = 100, offset: Int = 0,
                       musicFolderIds: [String] = []) async throws -> [SubsonicAlbum] {
        try await merging(musicFolderIds) { folderId in
            var params = ["type": "byGenre", "genre": genre,
                          "size": String(size), "offset": String(offset)]
            if let folderId { params["musicFolderId"] = folderId }
            return try await get("getAlbumList2", params).albumList2?.album ?? []
        }
    }

    /// M3: songs of ONE genre, paged (getSongsByGenre).
    func songsByGenre(genre: String, count: Int, offset: Int,
                      musicFolderIds: [String] = []) async throws -> [SubsonicSong] {
        try await merging(musicFolderIds) { folderId in
            var params = ["genre": genre, "count": String(count), "offset": String(offset)]
            if let folderId { params["musicFolderId"] = folderId }
            return try await get("getSongsByGenre", params).songsByGenre?.song ?? []
        }
    }

    /// `musicFolderId` since API 1.12.0 — a search from the Music tab must not
    /// answer with audiobooks and the other way round. The composite result is
    /// merged field by field, so the union rule stays the same as everywhere.
    func search3(query: String, albumCount: Int = 40, songCount: Int = 40,
                 artistCount: Int = 20, musicFolderIds: [String] = []) async throws -> SubsonicSearchResult3 {
        var artists: [SubsonicArtist] = []
        var albums: [SubsonicAlbum] = []
        var songs: [SubsonicSong] = []
        let pages: [SubsonicSearchResult3] = try await merging(musicFolderIds) { folderId in
            var params = [
                "query": query,
                "albumCount": String(albumCount),
                "songCount": String(songCount),
                "artistCount": String(artistCount),
            ]
            if let folderId { params["musicFolderId"] = folderId }
            let body = try await self.get("search3", params)
            return [body.searchResult3 ?? SubsonicSearchResult3(artist: nil, album: nil, song: nil)]
        }
        for page in pages {
            artists += page.artist ?? []
            albums += page.album ?? []
            songs += page.song ?? []
        }
        return SubsonicSearchResult3(artist: artists, album: albums, song: songs)
    }

    func playlists() async throws -> [SubsonicPlaylist] {
        let list = try await get("getPlaylists").playlists?.playlist ?? []
        return list
    }

    func playlist(id: String) async throws -> SubsonicPlaylist? {
        try await get("getPlaylist", ["id": id]).playlist
    }

    /// F5: create a server playlist. Newer servers echo the created playlist
    /// (with its id) in the response; older ones return an empty body.
    func createPlaylist(name: String) async throws -> SubsonicPlaylist? {
        try await get("createPlaylist", ["name": name]).playlist
    }

    /// Add songs to an existing playlist (Subsonic `updatePlaylist`, repeated
    /// `songIdToAdd`). Removal is index-based in Subsonic and deferred.
    func updatePlaylist(id: String, songIdsToAdd: [String]) async throws {
        guard !songIdsToAdd.isEmpty else { return }
        _ = try await get("updatePlaylist", ["playlistId": id],
                          extraItems: Self.addSongItems(songIdsToAdd))
    }

    /// Rename a playlist (Subsonic `updatePlaylist` with `name`).
    func renamePlaylist(id: String, name: String) async throws {
        _ = try await get("updatePlaylist", ["playlistId": id, "name": name])
    }

    /// Remove songs by INDEX (Subsonic semantics: `songIndexToRemove` refers
    /// to positions in the CURRENT playlist order — resolved server-side in
    /// one call, so indices never shift mid-removal).
    func removePlaylistSongs(id: String, indices: [Int]) async throws {
        guard !indices.isEmpty else { return }
        _ = try await get("updatePlaylist", ["playlistId": id],
                          extraItems: Self.removeIndexItems(indices))
    }

    func deletePlaylist(id: String) async throws {
        _ = try await get("deletePlaylist", ["id": id])
    }

    /// Pure (tested): the repeated `songIndexToRemove` items — ONE request
    /// carries all indices, so Subsonic resolves them against the same
    /// snapshot (the duplicate-song case stays index-precise).
    nonisolated static func removeIndexItems(_ indices: [Int]) -> [URLQueryItem] {
        indices.map { URLQueryItem(name: "songIndexToRemove", value: String($0)) }
    }

    /// Pure (tested): the repeated `songIdToAdd` query items for `updatePlaylist`.
    nonisolated static func addSongItems(_ songIds: [String]) -> [URLQueryItem] {
        songIds.map { URLQueryItem(name: "songIdToAdd", value: $0) }
    }

    /// Marks a song as played (Last.fm/ListenBrainz scrobble on servers that
    /// support it). `submission=false` would be a "now playing" ping.
    func scrobble(id: String, submission: Bool = true) async throws {
        _ = try await get("scrobble", ["id": id, "submission": submission ? "true" : "false"])
    }

    func star(id: String, starred: Bool) async throws {
        _ = try await get(starred ? "star" : "unstar", ["id": id])
    }

    /// Starred albums (favorites).
    func starredAlbums(musicFolderIds: [String] = []) async throws -> [SubsonicAlbum] {
        try await merging(musicFolderIds) { folderId in
            var params: [String: String] = [:]
            if let folderId { params["musicFolderId"] = folderId }
            return try await get("getStarred2", params).starred2?.album ?? []
        }
    }

    // MARK: - OpenSubsonic metadata (M1) — all best-effort: servers without
    // configured agents legitimately return empty objects.

    /// Artist biography, image URLs and similar artists.
    func artistInfo(id: String) async throws -> SubsonicArtistInfo? {
        try await get("getArtistInfo2", ["id": id]).artistInfo2
    }

    /// Album notes/description.
    func albumInfo(id: String) async throws -> SubsonicAlbumInfo? {
        try await get("getAlbumInfo2", ["id": id]).albumInfo
    }

    /// The artist's most popular songs (agent-backed; by artist NAME).
    func topSongs(artist: String, count: Int = 10) async throws -> [SubsonicSong] {
        try await get("getTopSongs", ["artist": artist, "count": String(count)]).topSongs?.song ?? []
    }

    func similarSongs(id: String, count: Int = 20) async throws -> [SubsonicSong] {
        try await get("getSimilarSongs2", ["id": id, "count": String(count)]).similarSongs2?.song ?? []
    }

    /// OpenSubsonic structured lyrics for one song (synced when available).
    func lyrics(songId: String) async throws -> [SubsonicStructuredLyrics] {
        try await get("getLyricsBySongId", ["id": songId]).lyricsList?.structuredLyrics ?? []
    }

    /// One song by id (used for tap-to-play on top songs).
    func song(id: String) async throws -> SubsonicSong? {
        try await get("getSong", ["id": id]).song
    }

    /// A random set of songs across the library — the pool for whole-library
    /// shuffle. `size` is capped server-side (Subsonic max is 500).
    func randomSongs(size: Int = 100, musicFolderIds: [String] = []) async throws -> [SubsonicSong] {
        try await merging(musicFolderIds) { folderId in
            var params = ["size": String(size)]
            if let folderId { params["musicFolderId"] = folderId }
            return try await get("getRandomSongs", params).randomSongs?.song ?? []
        }
    }

    // MARK: - Bookmarks (play-position sync — playlist continue-listening)

    /// All of the user's play-position bookmarks (song + position + comment).
    func getBookmarks() async throws -> [SubsonicBookmark] {
        try await get("getBookmarks").bookmarks?.bookmark ?? []
    }

    /// Create/replace the bookmark for a song (Subsonic keeps one per song per
    /// user). `comment` carries the enclosing playlist item id (Mär context).
    func createBookmark(songId: String, positionMs: Int, comment: String) async throws {
        _ = try await get("createBookmark",
                          ["id": songId, "position": String(max(0, positionMs)), "comment": comment])
    }

    /// Delete a song's bookmark (used when playback moves on to the next song).
    func deleteBookmark(songId: String) async throws {
        _ = try await get("deleteBookmark", ["id": songId])
    }

    // MARK: - Helpers

    private static func randomSalt() -> String {
        // 8 random bytes hex — enough entropy for a per-request salt.
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
