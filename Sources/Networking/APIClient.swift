// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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

    /// ABS is a SOURCE like the others. Without a signed-in server it
    /// is simply unavailable (tab hidden, search fan-out skips it) instead of
    /// a forced empty library.
    /// TF bib-toggles: also gated by the effective ABS-audiobooks activation
    /// (audiobooks tab ∧ ABS-audiobooks toggle). Off → tab hidden, library
    /// load and search fan-out skip it, so no audiobooks server calls fire.
    var isAvailable: Bool { AppStorageKeys.absAudiobooksActive && token?.isEmpty == false }

    /// Set by the sign-in state while the stored access could not be read
    /// (`AuthViewModel.accessUnknown`); the client then has no token.
    var accessUnknown = false

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

    /// Logout empties the client. `isAvailable` flips with it.
    func clearToken() {
        self.token = nil
    }

    // MARK: Login

    /// Exchanges username/password for a token (POST /login, at the root, not
    /// under /api). Prefers the long-lived legacy token; newer JWT servers only
    /// return `accessToken` (which expires. The existing 401 handling then
    /// leads back to setup).
    func login(username: String, password: String) async throws -> String {
        let data = try await send(
            method: "POST",
            path: "login",
            body: ["username": username, "password": password]
        )
        let response = try await decode(LoginResponse.self, from: data)
        guard let token = response.user.token ?? response.user.accessToken, !token.isEmpty else {
            throw APIError.decoding("Login-Antwort enthält keinen Token")
        }
        return token
    }

    // MARK: Libraries

    func fetchLibraries() async throws -> [ABSLibrary] {
        let data = try await get(path: "api/libraries")
        return try await decode(LibrariesResponse.self, from: data).libraries
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
            return try await decode(LibraryItemsResponse.self, from: data).results
        } catch APIError.decoding {
            let data = try await get(path: "api/libraries/\(libraryId)/items")
            return try await decode(LibraryItemsResponse.self, from: data).results
        }
    }

    /// One page of the library list (server paging). Basis for progressive
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
            return try await decode(LibraryItemsResponse.self, from: data)
        }
        let response: LibraryItemsResponse
        do { response = try await fetch(minified: true) }
        catch APIError.decoding { response = try await fetch(minified: false) }
        return (response.results, response.total ?? response.results.count)
    }

    /// "Continue Listening" + "Recently Added" from the ABS `personalized` view
    /// in ONE small request. So the top rows are complete immediately, even
    /// while the full list still loads progressively. Best effort: empty rows on
    /// an unexpected shape (the progressive full load fills them anyway).
    func fetchLibrarySeed(libraryId: String) async throws -> LibrarySeed {
        let data = try await get(
            path: "api/libraries/\(libraryId)/personalized",
            query: [URLQueryItem(name: "minified", value: "1")]
        )
        guard let shelves = try? await decode([PersonalizedShelf].self, from: data) else {
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
        let me = try await decode(MeResponse.self, from: data)
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

    /// Bookmarks live on the user object. Filtered here per book.
    func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] {
        let data = try await get(path: "api/me")
        let me = try await decode(MeResponse.self, from: data)
        return (me.bookmarks ?? [])
            .filter { $0.libraryItemId == itemId }
            .sorted { $0.time < $1.time }
    }

    /// ABS stores bookmark times as whole seconds. They double as the key
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
        return try await decode(LibraryItemDetail.self, from: data)
    }

    // MARK: Progress

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        var body: [String: Any] = [
            "currentTime": currentTime,
            "isFinished": isFinished
        ]
        // Only send duration/progress when we actually know the duration. An
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
        let me = try await decode(MeResponse.self, from: data)
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

    // MARK: Podcast management (create/remove subscription)

    /// Parse a feed server-side (metadata for a new subscription).
    func fetchPodcastFeed(rssFeed: String) async throws -> PodcastFeedMetadata {
        let data = try await send(method: "POST", path: "api/podcasts/feed", body: ["rssFeed": rssFeed])
        return try await decode(PodcastFeedResponse.self, from: data).podcast.metadata
    }

    /// Folders of a library (target path for a new subscription). The detail
    /// endpoint returns the library object directly (folders at the top level).
    func fetchLibraryFolders(libraryId: String) async throws -> [ABSFolder] {
        let data = try await get(path: "api/libraries/\(libraryId)")
        return (try await decode(LibraryWithFolders.self, from: data).folders) ?? []
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
    /// `download-episodes`. The server expects its own feed format).
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

    /// The query name the session token rides under in an image address. It
    /// names no picture, so no cover file name carries it
    /// (`ImageCache.signInQueryNames`).
    nonisolated static let mediaTokenName = "token"

    /// Whether a path is one of this client's image addresses: an item's
    /// cover (`api/items/<id>/cover`) or an author's image
    /// (`api/authors/<id>/image`).
    nonisolated static func buildsImage(path: String) -> Bool {
        path.range(of: #"/api/items/[^/]+/cover$"#, options: .regularExpression) != nil
            || path.range(of: #"/api/authors/[^/]+/image$"#, options: .regularExpression) != nil
    }

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
            items.append(URLQueryItem(name: Self.mediaTokenName, value: token))
        }
        components.setQuery(items)
        return components.url
    }

    /// Absolute URL for an audio track. Authentication for streaming is done NOT
    /// via query parameter but via the Authorization header (see PlayerViewModel);
    /// that is the more robust, officially supported way for AVPlayer
    /// (AVURLAssetHTTPHeaderFieldsKey).
    /// The server's author image (only some authors have one). Same
    /// token-in-query auth as the covers, cached through the shared cover
    /// infrastructure (ImageCache), no cache path of its own.
    func authorImageURL(authorId: String) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/authors/\(authorId)/image"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var items = components.queryItems ?? []
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: Self.mediaTokenName, value: token))
        }
        components.setQuery(items)
        return components.url
    }

    func streamURL(forContentPath contentPath: String) -> URL? {
        // Some server configurations already return absolute URLs.
        if contentPath.hasPrefix("http://") || contentPath.hasPrefix("https://") {
            return URL(string: contentPath)
        }
        let cleanPath = contentPath.hasPrefix("/") ? String(contentPath.dropFirst()) : contentPath
        return baseURL.appendingPathComponent(cleanPath)
    }

    /// Upload a complete audiobook (POST /api/upload, multipart).
    /// The body is assembled ON DISK (books run 100–500 MB. Never in RAM)
    /// and sent via uploadTask(fromFile:). Files are (filename, localURL)
    /// pairs; metadata rides as form fields. Throws visibly on any non-2xx.
    func uploadAudiobook(libraryId: String, folderId: String,
                         title: String, author: String?, description: String?,
                         files: [(filename: String, url: URL)]) async throws {
        let boundary = "maer-upload-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: bodyURL) }

        func writeField(_ name: String, _ value: String) throws {
            try handle.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try writeField("title", title)
        if let author { try writeField("author", author) }
        if let description { try writeField("description", description) }
        try writeField("library", libraryId)
        try writeField("folder", folderId)
        for (index, file) in files.enumerated() {
            // The cover file rides in the same upload. Content
            // type by extension (jpg/png), everything else stays MP3.
            let ext = (file.filename as NSString).pathExtension.lowercased()
            let contentType = ext == "jpg" || ext == "jpeg" ? "image/jpeg"
                : ext == "png" ? "image/png" : "audio/mpeg"
            try handle.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(index)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\r\n".utf8))
        }
        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        try handle.close()

        var request = URLRequest(url: baseURL.appendingPathComponent("api/upload"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, http) = try await HTTP.upload(for: request, fromFile: bodyURL)
        guard let http, (200...299).contains(http.statusCode) else {
            throw APIError.http(http?.statusCode ?? -1, "upload failed")
        }
    }

    // MARK: - Low-Level-Helfer

    private func get(path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw APIError.invalidURL }
        components.setQuery(query.isEmpty ? nil : query)
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(request)
    }

    /// 🔴 The probe behind the SUSPECT session state. It separates
    /// "server not there yet" (the homeserver restart window) from "server
    /// there and says no". Deliberately a plain, cheap authorized request
    /// WITHOUT the retry/`onUnauthorized` machinery: this is the question
    /// itself, not a request that may ask it again.
    enum AuthorizationProbe { case authorized, rejected, unreachable }

    func probeAuthorization() async -> AuthorizationProbe {
        guard let token, !token.isEmpty else { return .rejected }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/me"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        // bearable, because the outcome itself is the state: unreachable is an answer of this probe.
        guard let (_, http) = try? await HTTP.data(for: request, lane: .stream),
              let http else { return .unreachable }
        if (200...299).contains(http.statusCode) { return .authorized }
        if http.statusCode == 401 { return .rejected }
        // 502/503/504 are the proxy still coming up. Not an answer about us.
        return .unreachable
    }

    /// ONE request path with the self-healing policy. A 401 is probed
    /// once more before the logout fires (outage gateways answer 401
    /// spuriously), transient failures (429/5xx/timeouts/connection drops)
    /// back off briefly instead of surfacing straight away.
    private func perform(_ request: URLRequest) async throws -> Data {
        // The door runs the policy (401 probed once, 429 and 5xx backed off
        // twice, transient URL errors likewise) and hands back the LAST
        // response; the logout hook stays here, at the one place that
        // knows what a confirmed 401 means for this client.
        let (data, http) = try await HTTP.data(for: request, lane: .api)
        guard let http else { throw APIError.invalidResponse }
        if (200...299).contains(http.statusCode) { return data }
        // Only a CONFIRMED 401 (survived the probe retry) logs out.
        if http.statusCode == 401 { onUnauthorized?() }
        throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
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
        return try await perform(request)
    }

    /// Like `send`, but with an arbitrary JSON body (dict OR array). For
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
        return try await perform(request)
    }

    /// Decode OFF the main actor. APIClient is MainActor-isolated by project
    /// default, so the big payloads (all-progress, library pages, podcast
    /// details) used to be parsed on the UI thread and caused visible hitches
    /// during the silent cache refresh. Same pattern as ImageCache.
    private func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        do {
            // detached because the decode is CPU work and the client is MainActor by default
            return try await Task.detached(priority: .userInitiated) {
                // Regression guard: JSON decode stays off the main actor.
                #if DEBUG
                dispatchPrecondition(condition: .notOnQueue(.main))
                #endif
                return try JSONDecoder().decode(T.self, from: data)
            }.value
        } catch let DecodingError.keyNotFound(key, _) {
            throw APIError.decoding("Field '\(key.stringValue)' missing in the response")
        } catch let DecodingError.typeMismatch(_, context) {
            throw APIError.decoding(context.debugDescription)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

}

// MARK: - Global search (SearchableProvider)

/// Lenient decode of `GET api/libraries/{id}/search`. Only what the results
/// need.
nonisolated private struct ABSSearchResponse: Decodable {
    struct BookHit: Decodable { let libraryItem: LibraryItem? }
    struct AuthorHit: Decodable { let id: String?; let name: String? }
    struct SeriesHit: Decodable {
        struct Series: Decodable { let id: String?; let name: String? }
        let series: Series?
    }
    let book: [BookHit]?
    let authors: [AuthorHit]?
    let series: [SeriesHit]?
}

extension APIClient: SearchableProvider {
    @MainActor
    func search(query: String) async throws -> [SearchResult] {
        #if DEBUG
        if UITestSeed.isActive { return offlineSearch(query) }   // seeded stock, no server
        #endif
        guard await Reachability.isConnected() else { return offlineSearch(query) }
        guard let libraryId = resolvedLibraryId() else { return offlineSearch(query) }
        let data = try await get(
            path: "api/libraries/\(libraryId)/search",
            query: [URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: "10")]
        )
        let response = try await decode(ABSSearchResponse.self, from: data)
        var out: [SearchResult] = []
        for hit in response.book ?? [] {
            guard let item = hit.libraryItem else { continue }
            out.append(SearchResult(
                id: item.id, kind: .book, title: item.title,
                subtitle: item.author, coverURL: coverURL(forItemId: item.id)))
        }
        for hit in response.authors ?? [] {
            guard let name = hit.name, !name.isEmpty else { continue }
            out.append(SearchResult(id: "author:\(name)", kind: .author, title: name))
        }
        for hit in response.series ?? [] {
            guard let name = hit.series?.name, !name.isEmpty else { continue }
            out.append(SearchResult(id: "series:\(name)", kind: .series, title: name))
        }
        return out
    }

    /// The stored library id (settings picker), else the last id the library
    /// actually loaded. Nil only before any library ever loaded.
    private func resolvedLibraryId() -> String? {
        let stored = AppStorageKeys.string(AppStorageKeys.selectedLibraryId)
        return (stored?.isEmpty == false) ? stored : LibraryViewModel.lastKnownLibraryId
    }

    /// Offline: search the cached library stock (the entries the offline cache
    /// serves). Books plus matching author/series groups.
    private func offlineSearch(_ query: String) -> [SearchResult] {
        let entries = AppSession.shared.libraryViewModel.entries
        var out: [SearchResult] = []
        for entry in entries {
            let meta = entry.item.media?.metadata
            let fields = [entry.item.title, meta?.authorName, meta?.narratorName, meta?.seriesName]
            guard fields.contains(where: { $0.map { PodcastLocalSearch.matches($0, query) } ?? false })
            else { continue }
            out.append(SearchResult(
                id: entry.id, kind: .book, title: entry.item.title,
                subtitle: entry.item.author, coverURL: coverURL(forItemId: entry.id),
                isPlayableNow: DownloadManager.shared.isDownloaded(itemId: entry.id)))
        }
        let authors = Set(entries.compactMap(\.item.author)).filter { PodcastLocalSearch.matches($0, query) }
        out += authors.sorted().map { SearchResult(id: "author:\($0)", kind: .author, title: $0) }
        let series = Set(entries.compactMap { LibraryViewModel.baseSeriesName($0.item.media?.metadata?.seriesName) })
            .filter { PodcastLocalSearch.matches($0, query) }
        out += series.sorted().map { SearchResult(id: "series:\($0)", kind: .series, title: $0) }
        return out
    }
}
