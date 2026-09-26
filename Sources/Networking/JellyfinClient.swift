// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Minimal Jellyfin API client for the music scope (Etappe 2): token auth via
/// `/Users/AuthenticateByName`, then the token in the `Authorization:
/// MediaBrowser` header on every request. Media URLs
/// (stream/cover) carry the token as the `ApiKey` query parameter so
/// AVPlayer/image loading needs no header plumbing. Same shape as the
/// Subsonic client.
/// Endpoints per the official API reference (linked in the report):
/// https://api.jellyfin.org/. Items, Artists, Playlists, UserLibrary,
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

    enum JellyfinError: LocalizedError, Equatable {
        case badURL
        case network
        case auth
        /// The server answered, but not to this device from here. A
        /// self-hosted Jellyfin behind a proxy that serves LAN, mesh or VPN
        /// only gives 403 from outside the tunnel, and it is neither
        /// silence nor a wrong password.
        case blockedHere
        /// The server answered with a status that is none of the above. The
        /// code travels, because "could not be reached" for a 500 sends
        /// someone to their router while the server is the thing that broke.
        case http(Int)
        case decoding
        nonisolated var errorDescription: String? {
            switch self {
            case .badURL: return String(localized: "Invalid server URL.")
            case .network: return String(localized: "The Jellyfin server could not be reached.")
            case .auth: return String(localized: "Jellyfin sign-in failed. Check username and password.")
            case .blockedHere: return String(localized: "The Jellyfin server is not reachable from this network.")
            case .http(let code): return String(localized: "The Jellyfin server answered with HTTP \(code).")
            case .decoding: return String(localized: "Unexpected answer from the Jellyfin server.")
            }
        }
    }

    /// What a status that is not a success means. Pure, so the sentence is
    /// decided once and can be driven by a case instead of by a server.
    ///
    /// A 403 used to end up as `.auth` here and as `.network` at the two
    /// browsing doors: the same code, two contradicting sentences, and the
    /// first one sends someone to change a password that is correct.
    nonisolated static func failure(forStatus status: Int?) -> JellyfinError {
        switch status {
        case .none: return .network
        case 401: return .auth
        case 403: return .blockedHere
        case let code?: return .http(code)
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

    /// The `Authorization: MediaBrowser …` header for every request. Without a
    /// token it is the handshake AuthenticateByName needs before one exists;
    /// with a token it carries it as `Token="…"`. This token form is the only
    /// authorization Jellyfin 12 accepts (the legacy `X-Emby-Token` header is
    /// off by default), and older servers accept it too, so it is the one
    /// shape for both the handshake and every authorized call.
    nonisolated static func authorizationHeader(deviceId: String, token: String? = nil) -> String {
        var value = "MediaBrowser Client=\"Maer\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"2.6\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    private func authorizationHeader(token: String? = nil) -> String {
        JellyfinClient.authorizationHeader(deviceId: deviceId, token: token)
    }

    /// The query item that authorizes a media URL (stream, cover). AVPlayer
    /// and the image loader take a plain URL and set no headers, so the token
    /// rides in the query. Jellyfin 12 reads it under `ApiKey` and no longer
    /// under the Emby-legacy `api_key`; the server reads `ApiKey` since 10.7
    /// (`AuthorizationContext`), so this one name carries every server the
    /// source supports.
    nonisolated static func mediaAuthQueryItem(token: String) -> URLQueryItem {
        URLQueryItem(name: "ApiKey", value: token)
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
        request.setValue(authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let (data, http) = try await fetch(request)
        guard let status = http?.statusCode, (200...299).contains(status) else {
            throw Self.failure(forStatus: http?.statusCode)
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
        catch { return ErrorSentence.of(error) }
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
            request.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
            let (data, http) = try await fetch(request)
            if http?.statusCode == 401, attempt == 0 {
                accessToken = nil
                (token, _) = try await ensureAuth()
                continue
            }
            guard let status = http?.statusCode, (200...299).contains(status) else {
                throw Self.failure(forStatus: http?.statusCode)
            }
            // Decode off-main. Album catalogs are large (same pattern as the
            // Subsonic client; the class is MainActor by project default).
            // detached because the decode is CPU work and the client is MainActor by default
            guard let decoded = try? await Task.detached(priority: .userInitiated, operation: {
                try JSONDecoder().decode(T.self, from: data)
            }).value else { throw JellyfinError.decoding }
            return decoded
        }
        throw JellyfinError.auth
    }

    /// A body with REAL JSON types.
    ///
    /// The dictionary variant below can only send strings, and the UserData
    /// endpoint wants a NUMBER for the ticks and a BOOL for `Played`. Sending
    /// `"true"` is not the same thing, and a server that ignores a mistyped
    /// field does it silently. Measured: `Played: false` in every answer;
    /// this is the first thing to rule out before anyone concludes the server
    /// cannot mark a book finished.
    private func post(_ path: String, _ query: [String: String] = [:],
                      jsonData: Data, method: String = "POST") async throws -> Data {
        try await postRaw(path, query, body: jsonData, method: method)
    }

    private func post(_ path: String, _ query: [String: String] = [:],
                      jsonBody: [String: String]? = nil, method: String = "POST") async throws -> Data {
        try await postRaw(path, query,
                          body: jsonBody.flatMap { try? JSONEncoder().encode($0) },
                          method: method)
    }

    private func postRaw(_ path: String, _ query: [String: String] = [:],
                         body: Data? = nil, method: String = "POST") async throws -> Data {
        var (token, _) = try await ensureAuth()
        for attempt in 0..<2 {
            var comps = URLComponents(url: try base().appendingPathComponent(path),
                                      resolvingAgainstBaseURL: false)
            comps?.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps?.url else { throw JellyfinError.badURL }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (data, http) = try await fetch(request)
            if http?.statusCode == 401, attempt == 0 {
                accessToken = nil
                (token, _) = try await ensureAuth()
                continue
            }
            guard let status = http?.statusCode, (200...299).contains(status) else {
                throw Self.failure(forStatus: http?.statusCode)
            }
            return data
        }
        throw JellyfinError.auth
    }

    // MARK: - Audiobooks (scope MEASURED, not assumed)
    //
    // Measured against Jellyfin 12.0 (books are native there), and the
    // measurements draw the scope of everything below:
    //
    //   * Every file in a `books` library yields ONE `AudioBook`, with its
    //     folder as `ParentId` (listed only when `Fields` asks for it),
    //     `Album` from the tag, `IndexNumber` from the track tag (empty
    //     without one), plus a bare `Folder` element with no duration. No
    //     element represents a book as a whole, and a folder may be a book
    //     or a shelf of single-file books, so the provider folds the files
    //     of one folder that share the album tag into one book
    //     (`JellyfinBookFold`). On 10.11 with the Bookshelf plugin a folder
    //     produced no entry at all; a single file is one `AudioBook` on both.
    //   * `Chapters` is 0 and Jellyfin generates none for `AudioBook`.
    //   * The listening position travels over `UserData` per element, NOT
    //     over the session route: `/Sessions/Playing…` with PositionTicks
    //     read back as 0, the UserData write read back identical.

    /// The user's libraries, with their kind. The audiobook path needs to know
    /// which one is `books`.
    func views() async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Views", [:], as: JFItemsResult.self)
        return result.items ?? []
    }

    /// The fields the book path asks for. `ParentId` is in the list because
    /// Jellyfin 12 leaves it out of a listing otherwise (measured: none of
    /// the elements carried it without, all of them with), and the fold
    /// groups by it; without it the fold would see nothing and say nothing.
    nonisolated static let bookFields = "DateCreated,Genres,Overview,Path,ParentId"

    /// The query of the audiobook listing, pure so a witness can hold that
    /// it asks for `ParentId`.
    nonisolated static func audioBookListQuery(parentId: String, startIndex: Int, limit: Int) -> [String: String] {
        ["ParentId": parentId, "IncludeItemTypes": "AudioBook", "Recursive": "true",
         "SortBy": "SortName", "SortOrder": "Ascending",
         "StartIndex": String(startIndex), "Limit": String(limit),
         "Fields": bookFields]
    }

    nonisolated static func audioBookFolderQuery(parentId: String) -> [String: String] {
        ["ParentId": parentId, "IncludeItemTypes": "Folder", "Recursive": "true",
         "Fields": "ParentId"]
    }

    /// The audiobooks of one library. `AudioBook` is the type Jellyfin assigns
    /// to every audio file in a `books` library; the provider folds the files
    /// of one book into one.
    func audioBooks(parentId: String, startIndex: Int = 0, limit: Int = 500) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items",
                                   Self.audioBookListQuery(parentId: parentId, startIndex: startIndex, limit: limit),
                                   as: JFItemsResult.self)
        return result.items ?? []
    }

    /// The folders under one library, so a folded book can carry its folder's
    /// name behind the album tag. One call per listing, not one per book.
    func audioBookFolders(parentId: String) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", Self.audioBookFolderQuery(parentId: parentId),
                                   as: JFItemsResult.self)
        return result.items ?? []
    }

    /// Write the listening position. The measured road. And the only one:
    /// the session route did not persist anything.
    /// The body of a UserData write. Typed, so the ticks travel as a NUMBER
    /// and `Played` as a BOOL. A quoted "true" is a string, and a server that
    /// ignores a mistyped field does it without a word.
    nonisolated struct UserDataWrite: Encodable {
        let PlaybackPositionTicks: Int64
        let Played: Bool
    }

    nonisolated static func userDataBody(seconds: Double, isFinished: Bool) throws -> Data {
        try JSONEncoder().encode(UserDataWrite(
            PlaybackPositionTicks: Int64(max(0, seconds) * 10_000_000),
            Played: isFinished))
    }

    func setPlaybackPosition(itemId: String, seconds: Double, isFinished: Bool) async throws {
        let (_, uid) = try await ensureAuth()
        _ = try await post("UserItems/\(itemId)/UserData", ["userId": uid],
                           jsonData: try Self.userDataBody(seconds: seconds,
                                                           isFinished: isFinished))
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

    /// The query of a single-item fetch. `ParentId` is asked for the same
    /// way as in the listing, so a book's detail carries its folder too.
    nonisolated static let itemQuery: [String: String] = ["Fields": "ParentId"]

    /// Generic single-item fetch (song, album, playlist, artist, folder).
    func item(id: String) async throws -> JFItem? {
        let (_, uid) = try await ensureAuth()
        return try await get("Users/\(uid)/Items/\(id)", Self.itemQuery, as: JFItem.self)
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

    /// A song list page (music tab "Titles" entry), sorted by the server.
    /// `DateCreated` is asked for because the list merged with another
    /// server sorts by it; play count and last play come in `UserData`.
    func songs(startIndex: Int, limit: Int, sortBy: String, sortOrder: String) async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("Users/\(uid)/Items", [
            "IncludeItemTypes": "Audio", "Recursive": "true",
            "SortBy": sortBy, "SortOrder": sortOrder,
            "Fields": "DateCreated",
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

    /// The server's music genres. Jellyfin ships NO counts on this list
    /// (honest limit. The page sorts alphabetically for this provider).
    func musicGenres() async throws -> [JFItem] {
        let (_, uid) = try await ensureAuth()
        let result = try await get("MusicGenres", [
            "userId": uid, "SortBy": "SortName", "SortOrder": "Ascending",
        ], as: JFItemsResult.self)
        return result.items ?? []
    }

    /// Albums of ONE genre (Genres filter on the items query).
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

    /// Songs of ONE genre, paged.
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
            Self.mediaAuthQueryItem(token: accessToken),
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
            Self.mediaAuthQueryItem(token: accessToken),
        ]
        return comps?.url
    }
}
