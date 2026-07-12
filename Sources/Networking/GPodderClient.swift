import Foundation

/// HTTP client for the gpodder sync API (mygpo protocol) as spoken by oPodSync,
/// Nextcloud GPodder and gpodder.net. Auth: HTTP Basic (login also sets a
/// session cookie, sent along by the shared cookie store). Pure transport — the
/// reconcile logic lives in `GPodderSync`.
enum GPodderError: Error, LocalizedError {
    case badURL, network, status(Int)
    var errorDescription: String? {
        switch self {
        case .badURL: return "Ungültige Server-URL."
        case .network: return "Keine Verbindung zum gpodder-Server."
        case .status(let c): return "Server antwortete mit HTTP \(c)."
        }
    }
}

/// An episode action from the server response (`GET episodes`).
struct GPodderEpisodeAction: Decodable {
    let podcast: String?     // Feed-URL
    let episode: String?     // Enclosure-URL
    let action: String?      // "play" | "download" | "delete" | "new"
    let timestamp: String?   // ISO 8601, without timezone
    let position: Int?       // aktuelle Position (s)
    let total: Int?          // Gesamtdauer (s)
    let started: Int?
}

struct GPodderConfig {
    let baseURL: URL
    let username: String
    let password: String
    let deviceId: String
}

final class GPodderClient {
    let config: GPodderConfig
    private let session: URLSession

    init(config: GPodderConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    // MARK: - Public API

    /// Login via Basic auth → session cookie. Throws on wrong credentials.
    func login() async throws {
        _ = try await send(request("api/2/auth/\(enc(config.username))/login.json", method: "POST"),
                           allowAuthRetry: false)
    }

    /// Full current subscription list of this device (URLs).
    func subscriptions() async throws -> [String] {
        let data = try await send(request(subsPath, method: "GET"))
        // Without `since` the server returns the full list as a string array.
        if let arr = try? JSONDecoder().decode([String].self, from: data) { return arr }
        // Some servers always answer in the change format.
        return (try? JSONDecoder().decode(SubChanges.self, from: data))?.add ?? []
    }

    /// Upload subscription changes (add/remove of feed URLs).
    func uploadSubscriptions(add: [String], remove: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["add": add, "remove": remove])
        _ = try await send(request(subsPath, method: "POST", body: body))
    }

    /// Episode actions since `since` (0 = everything). Returns actions + new marker.
    func episodeActions(since: Int) async throws -> (actions: [GPodderEpisodeAction], timestamp: Int) {
        let data = try await send(request(
            "api/2/episodes/\(enc(config.username)).json",
            method: "GET",
            query: [URLQueryItem(name: "since", value: String(since))]
        ))
        let resp = try JSONDecoder().decode(EpisodeActionsResp.self, from: data)
        return (resp.actions, resp.timestamp)
    }

    /// Upload episode actions. Returns the new server marker.
    @discardableResult
    func uploadEpisodeActions(_ actions: [[String: Any]]) async throws -> Int {
        guard !actions.isEmpty else { return 0 }
        let body = try JSONSerialization.data(withJSONObject: actions)
        let data = try await send(request("api/2/episodes/\(enc(config.username)).json",
                                          method: "POST", body: body))
        return (try? JSONDecoder().decode(TimestampResp.self, from: data))?.timestamp ?? 0
    }

    // MARK: - Intern

    private var subsPath: String {
        "api/2/subscriptions/\(enc(config.username))/\(enc(config.deviceId)).json"
    }

    private func request(_ path: String, method: String,
                         query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard var comp = URLComponents(url: config.baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false) else { throw GPodderError.badURL }
        if !query.isEmpty { comp.queryItems = query }
        guard let url = comp.url else { throw GPodderError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        let cred = "\(config.username):\(config.password)"
        if let data = cred.data(using: .utf8) {
            req.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest, allowAuthRetry: Bool = true) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw GPodderError.network }
        guard let http = resp as? HTTPURLResponse else { throw GPodderError.network }
        // 401 with plain basic auth: some servers (e.g. gpodder.net) first want
        // a login → session cookie. Log in once and retry.
        if http.statusCode == 401, allowAuthRetry {
            try await login()
            return try await send(req, allowAuthRetry: false)
        }
        guard (200..<300).contains(http.statusCode) else { throw GPodderError.status(http.statusCode) }
        return data
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - Decodables

    private struct SubChanges: Decodable { let add: [String]; let remove: [String]; let timestamp: Int }
    private struct EpisodeActionsResp: Decodable { let actions: [GPodderEpisodeAction]; let timestamp: Int }
    private struct TimestampResp: Decodable { let timestamp: Int }
}
