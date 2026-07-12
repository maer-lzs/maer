import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid server address.")
        case .invalidResponse:
            return String(localized: "Invalid response from the server.")
        case .http(let code, let body):
            if code == 401 {
                return String(localized: "The server rejected the token (401). Please check the token.")
            }
            let detail = APIError.sanitize(body)
            if detail.isEmpty {
                return String(localized: "Server error \(code).")
            }
            return String(localized: "Server error \(code): \(detail)")
        case .decoding(let detail):
            return String(localized: "Unexpected response format from the server: \(detail)")
        }
    }

    /// Condense a raw error body (often a whole HTML or JSON page) into a short,
    /// readable line: strip tags, collapse whitespace, truncate.
    static func sanitize(_ body: String) -> String {
        var text = body.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(160))
    }
}

/// Slim API client for Audiobookshelf.
///
/// Deliberate design decision: NO username/password login is used. Instead a
/// long-lived API token is used (from the Audiobookshelf web interface:
/// Settings -> Users -> open your own account -> token, or on newer versions:
/// Settings -> API Keys). This is the same principle the existing scan script on
/// the Pi uses (.abs-token). It makes the client independent of whether the
/// server uses the old or the new JWT access/refresh token system.
@MainActor
final class APIClient {
    private(set) var baseURL: URL
    private(set) var token: String?

    /// Called as soon as a request fails with 401 (token rejected). The app uses
    /// it to switch back to the setup screen automatically, instead of just
    /// showing an error in the middle of the library.
    var onUnauthorized: (() -> Void)?

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    func updateBaseURL(_ url: URL) {
        self.baseURL = url
    }

    func updateToken(_ token: String) {
        self.token = token
    }

    // MARK: Login

    /// Exchanges username/password for a token (POST /login, at the root, not
    /// under /api). Prefers the long-lived legacy token; newer JWT servers only
    /// return `accessToken` (which expires — the existing 401 handling then
    /// leads back to setup).
    func login(username: String, password: String) async throws -> String {
        let data = try await send(
            method: "POST",
            path: "login",
            body: ["username": username, "password": password]
        )
        let response = try decode(LoginResponse.self, from: data)
        guard let token = response.user.token ?? response.user.accessToken, !token.isEmpty else {
            throw APIError.decoding("Login-Antwort enthält keinen Token")
        }
        return token
    }

    // MARK: Libraries

    func fetchLibraries() async throws -> [ABSLibrary] {
        let data = try await get(path: "api/libraries")
        return try decode(LibrariesResponse.self, from: data).libraries
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        // minified=1: much smaller payload (the list only needs the slim
        // metadata; details/tracks are fetched per book anyway). Defensive
        // fallback to the full payload in case a server version ships a
        // minified shape our decoding chokes on.
        do {
            let data = try await get(
                path: "api/libraries/\(libraryId)/items",
                query: [URLQueryItem(name: "minified", value: "1")]
            )
            return try decode(LibraryItemsResponse.self, from: data).results
        } catch APIError.decoding {
            let data = try await get(path: "api/libraries/\(libraryId)/items")
            return try decode(LibraryItemsResponse.self, from: data).results
        }
    }

    /// One page of the library list (server paging) — basis for progressive
    /// loading: page 0 appears immediately, the rest is fetched in the
    /// background. Also returns the total count so the caller knows when
    /// everything is loaded.
    func fetchLibraryItemsPage(libraryId: String, limit: Int, page: Int) async throws
        -> (items: [LibraryItem], total: Int) {
        func fetch(minified: Bool) async throws -> LibraryItemsResponse {
            var query = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "page", value: String(page)),
            ]
            if minified { query.append(URLQueryItem(name: "minified", value: "1")) }
            let data = try await get(path: "api/libraries/\(libraryId)/items", query: query)
            return try decode(LibraryItemsResponse.self, from: data)
        }
        let response: LibraryItemsResponse
        do { response = try await fetch(minified: true) }
        catch APIError.decoding { response = try await fetch(minified: false) }
        return (response.results, response.total ?? response.results.count)
    }

    /// "Continue Listening" + "Recently Added" from the ABS `personalized` view
    /// in ONE small request — so the top rows are complete immediately, even
    /// while the full list still loads progressively. Best effort: empty rows on
    /// an unexpected shape (the progressive full load fills them anyway).
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed {
        let data = try await get(
            path: "api/libraries/\(libraryId)/personalized",
            query: [URLQueryItem(name: "minified", value: "1")]
        )
        guard let shelves = try? decode([PersonalizedShelf].self, from: data) else {
            return LibrarySeed()
        }
        func entities(_ id: String) -> [LibraryItem] {
            shelves.first { $0.id == id }?.entities ?? []
        }
        return LibrarySeed(continueListening: entities("continue-listening"),
                           recentlyAdded: entities("recently-added"))
    }

    /// All of the user's progress entries at once. Lets the whole library list
    /// be annotated with bars/status without a per-book request.
    func fetchAllProgress() async throws -> [String: BookProgress] {
        let data = try await get(path: "api/me")
        let me = try decode(MeResponse.self, from: data)
        var map: [String: BookProgress] = [:]
        for entry in me.mediaProgress ?? [] {
            let fraction: Double
            if let p = entry.progress {
                fraction = p
            } else if let c = entry.currentTime, let d = entry.duration, d > 0 {
                fraction = c / d
            } else {
                fraction = 0
            }
            map[entry.libraryItemId] = BookProgress(
                fraction: min(max(fraction, 0), 1),
                isFinished: entry.isFinished ?? false,
                lastUpdate: entry.lastUpdate ?? 0,
                currentTime: entry.currentTime
            )
        }
        return map
    }

    // MARK: Lesezeichen

    /// Bookmarks live on the user object — filtered here per book.
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] {
        let data = try await get(path: "api/me")
        let me = try decode(MeResponse.self, from: data)
        return (me.bookmarks ?? [])
            .filter { $0.libraryItemId == itemId }
            .sorted { $0.time < $1.time }
    }

    /// ABS stores bookmark times as whole seconds — they double as the key
    /// for deletion.
    func createBookmark(itemId: String, time: Double, title: String) async throws {
        _ = try await send(
            method: "POST",
            path: "api/me/item/\(itemId)/bookmark",
            body: ["time": Int(time), "title": title]
        )
    }

    func deleteBookmark(itemId: String, time: Double) async throws {
        _ = try await send(method: "DELETE", path: "api/me/item/\(itemId)/bookmark/\(Int(time))")
    }

    func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
        let data = try await get(
            path: "api/items/\(itemId)",
            query: [
                URLQueryItem(name: "expanded", value: "1"),
                URLQueryItem(name: "include", value: "progress")
            ]
        )
        return try decode(LibraryItemDetail.self, from: data)
    }

    // MARK: Progress

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        var body: [String: Any] = [
            "currentTime": currentTime,
            "isFinished": isFinished
        ]
        // Only send duration/progress when we actually know the duration — an
        // explicit progress: 0 would overwrite any existing server progress
        // (multi-file books without a duration).
        if duration > 0 {
            body["duration"] = duration
            body["progress"] = min(max(currentTime / duration, 0), 1)
        }
        _ = try await patch(path: "api/me/progress/\(itemId)", body: body)
    }

    // MARK: Podcast (episode level)

    /// Podcast libraries (mediaType == "podcast").
    func fetchPodcastLibraries() async throws -> [ABSLibrary] {
        try await fetchLibraries().filter(\.isPodcast)
    }

    /// Episode progress of all podcasts, keyed on
    /// `abspod:<libraryItemId>:<episodeId>` (matches the provider namespace).
    func fetchPodcastEpisodeProgress() async throws -> [String: BookProgress] {
        let data = try await get(path: "api/me")
        let me = try decode(MeResponse.self, from: data)
        var map: [String: BookProgress] = [:]
        for entry in me.mediaProgress ?? [] {
            guard let episodeId = entry.episodeId else { continue }
            let fraction: Double
            if let p = entry.progress {
                fraction = p
            } else if let c = entry.currentTime, let d = entry.duration, d > 0 {
                fraction = c / d
            } else {
                fraction = 0
            }
            map["abspod:\(entry.libraryItemId):\(episodeId)"] = BookProgress(
                fraction: min(max(fraction, 0), 1),
                isFinished: entry.isFinished ?? false,
                lastUpdate: entry.lastUpdate ?? 0,
                currentTime: entry.currentTime
            )
        }
        return map
    }

    /// Write episode progress (PATCH to the episode endpoint).
    func updateEpisodeProgress(libraryItemId: String, episodeId: String,
                               currentTime: Double, duration: Double, isFinished: Bool) async throws {
        var body: [String: Any] = ["currentTime": currentTime, "isFinished": isFinished]
        if duration > 0 {
            body["duration"] = duration
            body["progress"] = min(max(currentTime / duration, 0), 1)
        }
        _ = try await patch(path: "api/me/progress/\(libraryItemId)/\(episodeId)", body: body)
    }

    // MARK: Podcast-Verwaltung (Abo anlegen/entfernen)

    /// Parse a feed server-side (metadata for a new subscription).
    func fetchPodcastFeed(rssFeed: String) async throws -> PodcastFeedMetadata {
        let data = try await send(method: "POST", path: "api/podcasts/feed", body: ["rssFeed": rssFeed])
        return try decode(PodcastFeedResponse.self, from: data).podcast.metadata
    }

    /// Folders of a library (target path for a new subscription). The detail
    /// endpoint returns the library object directly (folders at the top level).
    func fetchLibraryFolders(libraryId: String) async throws -> [ABSFolder] {
        let data = try await get(path: "api/libraries/\(libraryId)")
        return (try decode(LibraryWithFolders.self, from: data).folders) ?? []
    }

    /// Create a podcast server-side (POST /api/podcasts). Needs upload rights.
    func createPodcast(libraryId: String, folderId: String, path: String,
                       metadata: PodcastFeedMetadata, autoDownload: Bool) async throws {
        let meta: [String: Any] = [
            "title": metadata.title ?? "",
            "author": metadata.author ?? "",
            "description": metadata.description ?? "",
            "feedUrl": metadata.feedUrl ?? "",
            "imageUrl": metadata.imageUrl ?? ""
        ]
        let body: [String: Any] = [
            "path": path,
            "folderId": folderId,
            "libraryId": libraryId,
            "media": ["metadata": meta, "autoDownloadEpisodes": autoDownload]
        ]
        _ = try await send(method: "POST", path: "api/podcasts", body: body)
    }

    /// Set an item's cover server-side from a URL (ABS downloads the image
    /// itself). For high-resolution feed covers (itunes:image) that ABS
    /// sometimes replaces with the small RSS `<image>` on creation.
    func updateItemCover(itemId: String, coverURL: String) async throws {
        _ = try await send(method: "POST", path: "api/items/\(itemId)/cover",
                           body: ["url": coverURL])
    }

    /// Delete a library item (podcast show) server-side. Needs delete rights.
    func deleteLibraryItem(itemId: String) async throws {
        _ = try await send(method: "DELETE", path: "api/items/\(itemId)")
    }

    /// All episodes of a feed (raw, so they can be passed 1:1 to
    /// `download-episodes` — the server expects its own feed format).
    func fetchFeedEpisodes(rssFeed: String) async throws -> [[String: Any]] {
        let data = try await send(method: "POST", path: "api/podcasts/feed", body: ["rssFeed": rssFeed])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let podcast = obj["podcast"] as? [String: Any],
              let episodes = podcast["episodes"] as? [[String: Any]] else { return [] }
        return episodes
    }

    /// Have selected feed episodes downloaded server-side.
    func downloadEpisodes(libraryItemId: String, episodes: [[String: Any]]) async throws {
        _ = try await sendJSON(method: "POST",
                               path: "api/podcasts/\(libraryItemId)/download-episodes",
                               json: episodes)
    }

    // MARK: URLs for cover and streaming

    /// Cover image URL. AsyncImage cannot set custom headers, so the token goes
    /// as a query parameter here (officially supported for Audiobookshelf GET
    /// requests). Worst case only a cover image is missing, no core function.
    func coverURL(forItemId itemId: String) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/items/\(itemId)/cover"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var items = components.queryItems ?? []
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        return components.url
    }

    /// Absolute URL for an audio track. Authentication for streaming is done NOT
    /// via query parameter but via the Authorization header (see PlayerViewModel);
    /// that is the more robust, officially supported way for AVPlayer
    /// (AVURLAssetHTTPHeaderFieldsKey).
    func streamURL(forContentPath contentPath: String) -> URL? {
        // Some server configurations already return absolute URLs.
        if contentPath.hasPrefix("http://") || contentPath.hasPrefix("https://") {
            return URL(string: contentPath)
        }
        let cleanPath = contentPath.hasPrefix("/") ? String(contentPath.dropFirst()) : contentPath
        return baseURL.appendingPathComponent(cleanPath)
    }

    // MARK: - Low-Level-Helfer

    private func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidURL }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.maer.data(for: request)
        try validate(response, data: data)
        return data
    }

    private func patch(path: String, body: [String: Any]) async throws -> Data {
        try await send(method: "PATCH", path: path, body: body)
    }

    private func send(method: String, path: String, body: [String: Any]? = nil) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.maer.data(for: request)
        try validate(response, data: data)
        return data
    }

    /// Like `send`, but with an arbitrary JSON body (dict OR array) — for
    /// endpoints like `download-episodes` that expect a JSON list.
    private func sendJSON(method: String, path: String, json: Any) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.maer.data(for: request)
        try validate(response, data: data)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw APIError.decoding("Feld '\(key.stringValue)' fehlt in der Antwort")
        } catch let DecodingError.typeMismatch(_, context) {
            throw APIError.decoding(context.debugDescription)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 {
                onUnauthorized?()
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, body)
        }
    }
}
