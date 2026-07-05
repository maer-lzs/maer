import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Ungültige Server-Adresse."
        case .invalidResponse:
            return "Ungültige Antwort vom Server."
        case .http(let code, let body):
            if code == 401 {
                return "Server hat den Token abgelehnt (401). Bitte Token prüfen."
            }
            return "Serverfehler \(code): \(body.prefix(200))"
        case .decoding(let detail):
            return "Antwort vom Server hat ein unerwartetes Format: \(detail). Siehe README, Abschnitt Troubleshooting."
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

    // MARK: Bibliotheken

    func fetchLibraries() async throws -> [ABSLibrary] {
        let data = try await get(path: "api/libraries")
        return try decode(LibrariesResponse.self, from: data).libraries
    }

    func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] {
        let data = try await get(path: "api/libraries/\(libraryId)/items")
        return try decode(LibraryItemsResponse.self, from: data).results
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
                lastUpdate: entry.lastUpdate ?? 0
            )
        }
        return map
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
        let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
        let body: [String: Any] = [
            "currentTime": currentTime,
            "duration": duration,
            "progress": progress,
            "isFinished": isFinished
        ]
        _ = try await patch(path: "api/me/progress/\(itemId)", body: body)
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
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
