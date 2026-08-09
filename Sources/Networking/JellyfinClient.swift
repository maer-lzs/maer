// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Minimal Jellyfin API client for the music scope (Etappe 2): token auth via
/// `/Users/AuthenticateByName`, then `X-Emby-Token` requests. Media URLs
/// (stream/cover) carry `api_key` as a query parameter so AVPlayer/image
/// loading needs no header plumbing — same shape as the Subsonic client.
/// Endpoints per the official API reference (linked in the report):
/// https://api.jellyfin.org/ — Items, Artists, Playlists, UserLibrary,
/// Audio/universal, Lyrics.
@MainActor
final class JellyfinClient {
    nonisolated let serverURL: String
    private let username: String
    private let password: String
    private let deviceId: String
    /// Persisted access token + user id (keychain-backed via the caller).
    private var accessToken: String?
    private var userId: String?

    enum JellyfinError: LocalizedError {
        case badURL
        case network
        case auth
        case decoding
        nonisolated var errorDescription: String? {
            switch self {
            case .badURL: return String(localized: "Invalid server URL.")
            case .network: return String(localized: "The Jellyfin server could not be reached.")
            case .auth: return String(localized: "Jellyfin sign-in failed — check username and password.")
            case .decoding: return String(localized: "Unexpected answer from the Jellyfin server.")
            }
        }
    }

    init(serverURL: String, username: String, password: String, deviceId: String,
         accessToken: String?, userId: String?) {
        self.serverURL = serverURL
        self.username = username
        self.password = password
        self.deviceId = deviceId
        self.accessToken = accessToken
        self.userId = userId
    }

    /// Called after a fresh sign-in so the caller can persist the pair.
    var onTokenRefresh: ((_ token: String, _ userId: String) -> Void)?

    // MARK: - Auth

    /// `Authorization: MediaBrowser …` handshake header (required by
    /// AuthenticateByName even before a token exists).
    private var handshakeHeader: String {
        "MediaBrowser Client=\"Maer\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"2.6\""
    }

    private func base() throws -> URL {
        var raw = serverURL.trimmingCharacters(in: .whitespaces)
        while raw.hasSuffix("/") { raw = String(raw.dropLast()) }
        guard !raw.isEmpty, let url = URL(string: raw) else { throw JellyfinError.badURL }
        return url
    }

    /// Sign in with username/password → caches + reports token and user id.
    @discardableResult
    func authenticate() async throws -> String {
        let url = try base().appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(handshakeHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, http) = try await fetch(request)
        guard let status = http?.statusCode, (200...299).contains(status) else {
            throw (http?.statusCode == 401 || http?.statusCode == 403)
                ? JellyfinError.auth : JellyfinError.network
        }
        guard let auth = try? JSONDecoder().decode(JFAuthResponse.self, from: data),
              let token = auth.accessToken, let uid = auth.user?.id else {
            throw JellyfinError.decoding
        }
        accessToken = token
        userId = uid
        onTokenRefresh?(token, uid)
        Logger.music.notice("jellyfin sign-in ok (user id cached)")
        return token
    }

    /// Ensures a token exists (silent sign-in with the stored credentials).
    private func ensureAuth() async throws -> (token: String, userId: String) {
        if let accessToken, let userId { return (accessToken, userId) }
        guard !username.isEmpty, !password.isEmpty else { throw JellyfinError.auth }
        _ = try await authenticate()
        guard let accessToken, let userId else { throw JellyfinError.auth }
        return (accessToken, userId)
    }

    /// Reachability + credentials probe; nil on success, else user-facing text.
    func testConnection() async -> String? {
        do { _ = try await authenticate(); return nil }
        catch { return (error as? JellyfinError)?.errorDescription ?? error.localizedDescription }
    }

    // MARK: - Request core

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        do {
            return try await RequestRetryPolicy.fetch(request)
        } catch {
            // Convention (A3): cancellation propagates untranslated.
            if SubsonicClient.isCancellation(error) { throw error }
            throw JellyfinError.network
        }
    }

    /// Authorized GET returning a decoded value; one silent re-auth on 401
    /// (a revoked token must not strand the source until re-entry).
    private func get<T: Decodable & Sendable>(_ path: String, _ query: [String: String] = [:],
                                   as type: T.Type) async throws -> T {
        var (token, _) = try await ensureAuth()
        for attempt in 0..<2 {
            var comps = URLComponents(url: try base().appendingPathComponent(path),
                                      resolvingAgainstBaseURL: false)
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps?.url else { throw JellyfinError.badURL }
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            let (data, http) = try await fetch(request)
            if http?.statusCode == 401, attempt == 0 {
                accessToken = nil
                (token, _) = try await ensureAuth()
                continue
            }
            guard let status = http?.statusCode, (200...299).contains(status) else {
                throw http?.statusCode == 401 ? JellyfinError.auth : JellyfinError.network
            }
            // Decode off-main — album catalogs are large (same pattern as the
            // Subsonic client; the class is MainActor by project default).
            guard let decoded = try? await Task.detached(priority: .userInitiated, operation: {
                try JSONDecoder().decode(T.self, from: data)
            }).value else { throw JellyfinError.decoding }
            return decoded
        }
        throw JellyfinError.auth
    }

    private func post(_ path: String, _ query: [String: String] = [:],
                      jsonBody: [String: String]? = nil, method: String = "POST") async throws -> Data {
        var (token, _) = try await ensureAuth()
        for attempt in 0..<2 {
            var comps = URLComponents(url: try base().appendingPathComponent(path),
                                      resolvingAgainstBaseURL: false)
            comps?.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps?.url else { throw JellyfinError.badURL }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            if let jsonBody {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(jsonBody)
            }
            let (data, http) = try await fetch(request)
            if http?.statusCode == 401, attempt == 0 {
                accessToken = nil
                (token, _) = try await ensureAuth()
                continue
            }
            guard let status = http?.statusCode, (200...299).contains(status) else {
                throw http?.statusCode == 401 ? JellyfinError.auth : JellyfinError.network
            }
            return data
        }
        throw JellyfinError.auth
    }

    // MARK: - Music endpoints (scope: albums/artists/songs/playlists/covers/search)

    func albums(sortBy: String, sortOrder: String = "Ascending",
                startIndex: Int = 0, limit: Int = 500) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "SortBy": sortBy, "SortOrder": sortOrder,
            "StartIndex": String(startIndex), "Limit": String(limit),
            "Fields": "DateCreated,Genres",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func albumSongs(albumId: String) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "ParentId": albumId, "IncludeItemTypes": "Audio",
            "SortBy": "ParentIndexNumber,IndexNumber,SortName",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    /// Generic single-item fetch (song, album, playlist or artist).
    func item(id: String) async throws -> JFItem? {
        let (_, uid) = try await ensureAuth()
        return try await get("Users/\(uid)/Items/\(id)", [:], as: JFItem.self)
    }

    func artists() async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Artists", [
            "userId": uid, "Recursive": "true", "SortBy": "SortName",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func artistAlbums(artistId: String) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "AlbumArtistIds": artistId, "SortBy": "ProductionYear,SortName",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    /// Alphabetical song list page (music tab "Titles" entry).
    func songs(startIndex: Int, limit: Int) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "Audio", "Recursive": "true",
            "SortBy": "SortName", "SortOrder": "Ascending",
            "StartIndex": String(startIndex), "Limit": String(limit),
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func topSongs(artistId: String, limit: Int) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "Audio", "Recursive": "true",
            "ArtistIds": artistId, "SortBy": "PlayCount", "SortOrder": "Descending",
            "Limit": String(limit),
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    /// M3: the server's music genres. Jellyfin ships NO counts on this list
    /// (honest limit — the page sorts alphabetically for this provider).
    func musicGenres() async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("MusicGenres", [
            "userId": uid, "SortBy": "SortName", "SortOrder": "Ascending",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    /// M3: albums of ONE genre (Genres filter on the items query).
    func albumsByGenre(genre: String, startIndex: Int = 0, limit: Int = 100) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "Genres": genre, "SortBy": "SortName", "SortOrder": "Ascending",
            "StartIndex": String(startIndex), "Limit": String(limit),
            "Fields": "DateCreated,Genres",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    /// M3: songs of ONE genre, paged.
    func songsByGenre(genre: String, startIndex: Int, limit: Int) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "Audio", "Recursive": "true",
            "Genres": genre, "SortBy": "SortName", "SortOrder": "Ascending",
            "StartIndex": String(startIndex), "Limit": String(limit),
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func randomSongs(limit: Int) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "Audio", "Recursive": "true",
            "SortBy": "Random", "Limit": String(limit),
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func playlists() async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "Playlist", "Recursive": "true", "SortBy": "SortName",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func playlistSongs(playlistId: String) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Playlists/\(playlistId)/Items", ["userId": uid],
                                   as: JFItemsResult.self)
        return result.items ?? []
    }

    func createPlaylist(name: String) async throws -> String? {
        let (_, uid) = try await ensureAuth()
        let data = try await post("Playlists", jsonBody: [
            "Name": name, "UserId": uid, "MediaType": "Audio",
        ])
        return (try? JSONDecoder().decode(JFCreatedPlaylist.self, from: data))?.id
    }

    func addToPlaylist(playlistId: String, songIds: [String]) async throws {
        let (_, uid) = try await ensureAuth()
        _ = try await post("Playlists/\(playlistId)/Items",
                           ["Ids": songIds.joined(separator: ","), "UserId": uid])
    }

    /// Rename (Jellyfin 10.9+: POST /Playlists/{id} updates the playlist).
    func renamePlaylist(playlistId: String, name: String) async throws {
        _ = try await post("Playlists/\(playlistId)", jsonBody: ["Name": name])
    }

    /// Remove entries by their PlaylistItemIds (NOT song ids).
    func removeFromPlaylist(playlistId: String, entryIds: [String]) async throws {
        guard !entryIds.isEmpty else { return }
        _ = try await post("Playlists/\(playlistId)/Items",
                           ["EntryIds": entryIds.joined(separator: ",")], method: "DELETE")
    }

    func deletePlaylist(playlistId: String) async throws {
        _ = try await post("Items/\(playlistId)", method: "DELETE")
    }

    func search(term: String, limit: Int = 60) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "searchTerm": term, "Recursive": "true",
            "IncludeItemTypes": "MusicAlbum,Audio,MusicArtist,Playlist",
            "Limit": String(limit),
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func favoriteAlbums() async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "MusicAlbum", "Recursive": "true", "Filters": "IsFavorite",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    func setFavorite(itemId: String, on: Bool) async throws {
        let (_, uid) = try await ensureAuth()
        _ = try await post("Users/\(uid)/FavoriteItems/\(itemId)", method: on ? "POST" : "DELETE")
    }

    /// Scrobble analog: bumps the play count.
    func markPlayed(itemId: String) async throws {
        let (_, uid) = try await ensureAuth()
        _ = try await post("Users/\(uid)/PlayedItems/\(itemId)")
    }

    func lyrics(songId: String) async throws -> JFLyricsResponse {
        try await get("Audio/\(songId)/Lyrics", [:], as: JFLyricsResponse.self)
    }

    // MARK: - Media URLs (query-param auth, like the Subsonic client)

    func streamURL(songId: String) -> URL? {
        guard let accessToken, let userId, let base = try? base() else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("Audio/\(songId)/universal"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "deviceId", value: deviceId),
            // Direct-play the common containers; the server transcodes the rest.
            URLQueryItem(name: "container", value: "mp3,aac,m4a,flac,alac,ogg,opus,wav"),
            URLQueryItem(name: "transcodingContainer", value: "mp3"),
            URLQueryItem(name: "audioCodec", value: "mp3"),
        ]
        return comps?.url
    }

    func imageURL(itemId: String, maxWidth: Int) -> URL? {
        guard let accessToken, let base = try? base() else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/Primary"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "api_key", value: accessToken),
        ]
        return comps?.url
    }
}
