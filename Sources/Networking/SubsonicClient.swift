import Foundation
import CryptoKit

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
    private let apiVersion = "1.16.1"
    private let clientName = "Maer"

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
    private func requestURL(_ endpoint: String, _ params: [String: String] = [:]) -> URL? {
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
        comps?.queryItems = items
        return comps?.url
    }

    /// Media URL (stream / cover) — same auth params, but returned for AVPlayer /
    /// image loading instead of decoded. `f=json` is harmless on binary endpoints.
    func mediaURL(_ endpoint: String, _ params: [String: String]) -> URL? {
        requestURL(endpoint, params)
    }

    private func get(_ endpoint: String, _ params: [String: String] = [:]) async throws -> SubsonicBody {
        guard let url = requestURL(endpoint, params) else { throw SubsonicError.badURL }
        let data: Data
        do {
            (data, _) = try await URLSession.maer.data(from: url)
        } catch {
            throw SubsonicError.network
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
            throw SubsonicError.api(code: err.code, message: err.message)
        }
        guard body.status == "ok" else {
            throw SubsonicError.api(code: -1, message: body.status)
        }
        return body
    }

    // MARK: - Endpoints

    /// Connectivity + credential check.
    func ping() async throws {
        _ = try await get("ping")
    }

    /// A page of albums. `type`: newest | recent | frequent | alphabeticalByName …
    func albumList2(type: String, size: Int = 100, offset: Int = 0) async throws -> [SubsonicAlbum] {
        let body = try await get("getAlbumList2", [
            "type": type, "size": String(size), "offset": String(offset),
        ])
        return body.albumList2?.album ?? []
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

    func search3(query: String, albumCount: Int = 40, songCount: Int = 40,
                 artistCount: Int = 20) async throws -> SubsonicSearchResult3 {
        let body = try await get("search3", [
            "query": query,
            "albumCount": String(albumCount),
            "songCount": String(songCount),
            "artistCount": String(artistCount),
        ])
        return body.searchResult3 ?? SubsonicSearchResult3(artist: nil, album: nil, song: nil)
    }

    func playlists() async throws -> [SubsonicPlaylist] {
        try await get("getPlaylists").playlists?.playlist ?? []
    }

    func playlist(id: String) async throws -> SubsonicPlaylist? {
        try await get("getPlaylist", ["id": id]).playlist
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
    func starredAlbums() async throws -> [SubsonicAlbum] {
        try await get("getStarred2").starred2?.album ?? []
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

    // MARK: - Helpers

    private static func randomSalt() -> String {
        // 8 random bytes hex — enough entropy for a per-request salt.
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
