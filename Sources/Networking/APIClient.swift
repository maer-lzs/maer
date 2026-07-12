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
            return String(localized: "Server error \(code): \(String(body.prefix(200)))")
        case .decoding(let detail):
            return String(localized: "Unexpected response format from the server: \(detail)")
        }
    }
}

/// Schlanker API-Client für Audiobookshelf.
///
/// Bewusste Design-Entscheidung: Es wird KEIN Username/Passwort-Login verwendet.
/// Stattdessen wird ein langlebiger API-Token verwendet (aus der Audiobookshelf
/// Weboberfläche: Einstellungen -> Benutzer -> eigenen Account öffnen -> Token,
/// oder bei neueren Versionen: Einstellungen -> API-Keys). Das ist genau das
/// Prinzip, das auch das bestehende Scan-Script auf dem Pi nutzt (.abs-token).
/// Dadurch ist der Client unabhängig davon, ob der Server das alte oder das
/// neue JWT-Access/Refresh-Token-System verwendet.
@MainActor
final class APIClient {
    private(set) var baseURL: URL
    private(set) var token: String?

    /// Wird aufgerufen, sobald ein Request mit 401 (Token abgelehnt) scheitert.
    /// Die App nutzt das, um automatisch zurück zum Setup-Screen zu wechseln,
    /// statt nur eine Fehlermeldung mitten in der Bibliothek zu zeigen.
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

    /// Tauscht Benutzername/Passwort gegen einen Token (POST /login, liegt
    /// an der Wurzel, nicht unter /api). Bevorzugt den langlebigen Legacy-
    /// Token; neuere JWT-Server liefern nur `accessToken` (läuft ab — die
    /// bestehende 401-Behandlung führt dann zurück zum Setup).
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

    // MARK: Bibliotheken

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

    /// Alle Fortschritts-Einträge des Nutzers auf einmal. Damit lässt sich die
    /// komplette Bibliotheksliste mit Balken/Status versehen, ohne pro Buch
    /// einen eigenen Request zu machen.
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

    // MARK: Fortschritt

    func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {
        var body: [String: Any] = [
            "currentTime": currentTime,
            "isFinished": isFinished
        ]
        // duration/progress nur mitschicken, wenn wir die Dauer wirklich
        // kennen — ein explizites progress: 0 würde einen evtl. vorhandenen
        // Server-Fortschritt überschreiben (Multi-File-Bücher ohne Duration).
        if duration > 0 {
            body["duration"] = duration
            body["progress"] = min(max(currentTime / duration, 0), 1)
        }
        _ = try await patch(path: "api/me/progress/\(itemId)", body: body)
    }

    // MARK: Podcast (Episoden-Ebene)

    /// Podcast-Bibliotheken (mediaType == "podcast").
    func fetchPodcastLibraries() async throws -> [ABSLibrary] {
        try await fetchLibraries().filter(\.isPodcast)
    }

    /// Episoden-Fortschritt aller Podcasts, gekeyt auf
    /// `abspod:<libraryItemId>:<episodeId>` (passt zum Provider-Namespace).
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

    /// Episoden-Fortschritt schreiben (PATCH auf den Episoden-Endpoint).
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

    /// Feed server-seitig parsen (Metadaten für ein neues Abo).
    func fetchPodcastFeed(rssFeed: String) async throws -> PodcastFeedMetadata {
        let data = try await send(method: "POST", path: "api/podcasts/feed", body: ["rssFeed": rssFeed])
        return try decode(PodcastFeedResponse.self, from: data).podcast.metadata
    }

    /// Ordner einer Bibliothek (Zielpfad für ein neues Abo). Der Detail-Endpoint
    /// liefert das Library-Objekt direkt (folders auf oberster Ebene).
    func fetchLibraryFolders(libraryId: String) async throws -> [ABSFolder] {
        let data = try await get(path: "api/libraries/\(libraryId)")
        return (try decode(LibraryWithFolders.self, from: data).folders) ?? []
    }

    /// Podcast server-seitig anlegen (POST /api/podcasts). Braucht Upload-Rechte.
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

    /// Library-Item (Podcast-Show) server-seitig löschen. Braucht Delete-Rechte.
    func deleteLibraryItem(itemId: String) async throws {
        _ = try await send(method: "DELETE", path: "api/items/\(itemId)")
    }

    // MARK: URLs für Cover und Streaming

    /// Cover-Bild-URL. AsyncImage kann keine Custom-Header setzen, deshalb hier
    /// der Token als Query-Parameter (für GET-Requests von Audiobookshelf offiziell
    /// unterstützt). Schlimmstenfalls fehlt nur ein Cover-Bild, keine Kernfunktion.
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

    /// Absolute URL für einen Audio-Track. Die Authentifizierung erfolgt beim
    /// Streaming NICHT per Query-Parameter, sondern per Authorization-Header
    /// (siehe PlayerViewModel), das ist der robustere, offiziell unterstützte Weg
    /// für AVPlayer (AVURLAssetHTTPHeaderFieldsKey).
    func streamURL(forContentPath contentPath: String) -> URL? {
        // Manche Server-Konfigurationen liefern bereits absolute URLs.
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
