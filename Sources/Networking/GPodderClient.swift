// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// HTTP client for the gpodder sync API (mygpo protocol) as spoken by oPodSync,
/// Nextcloud GPodder and gpodder.net. Auth: HTTP Basic (login also sets a
/// session cookie, sent along by the shared cookie store). Pure transport — the
/// reconcile logic lives in `GPodderSync`.
enum GPodderError: Error, LocalizedError {
    case badURL, network, status(Int), badPayload
    var errorDescription: String? {
        switch self {
        case .badURL: return String(localized: "Invalid server URL.")
        case .network: return String(localized: "Cannot reach the gpodder server.")
        case .status(let c): return String(localized: "The server responded with HTTP \(c).")
        // Fix 01.08: a 2xx with an unreadable body (captive portal, proxy
        // login page) must surface as an ERROR — it silently became "0
        // subscriptions" before and armed the mass-delete guard.
        case .badPayload: return String(localized: "The server response could not be read.")
        }
    }
}

/// An episode action from the server response (`GET episodes`).
struct GPodderEpisodeAction: Decodable {
    let podcast: String?     // feed URL
    let episode: String?     // enclosure URL
    let action: String?      // "play" | "download" | "delete" | "new"
    let timestamp: String?   // ISO 8601, without timezone
    let position: Int?       // current position (s)
    let total: Int?          // total duration (s)
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

    /// Register THIS device (idempotent upsert in the gpodder API): required
    /// by stricter servers (PodFetch/Pinepods/Nextcloud) that 404 unknown
    /// device ids; oPodSync creates devices implicitly, so this is additive.
    func registerDevice(caption: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "caption": caption, "type": "mobile",
        ])
        var req = try request("api/2/devices/\(enc(config.username))/\(enc(config.deviceId)).json",
                              method: "POST")
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(req)
    }

    /// The registered devices (cheap probe for the sync history).
    func devices() async throws -> [[String: Any]] {
        let data = try await send(try request("api/2/devices/\(enc(config.username)).json", method: "GET"))
        return try Self.logged(data, label: "devices") { try Self.parseDevices($0) }
    }

    /// Login via Basic auth → session cookie. Throws on wrong credentials.
    func login() async throws {
        _ = try await send(request("api/2/auth/\(enc(config.username))/login.json", method: "POST"),
                           allowAuthRetry: false)
    }

    /// Full current subscription list of this device (URLs). An unreadable
    /// 2xx body THROWS (`badPayload`) — "connection went weird" must never
    /// read as "the user has no subscriptions" (Fix 01.08; the mass-delete
    /// guard stays as the second line for the REAL empty list).
    func subscriptions() async throws -> [String] {
        let data = try await send(request(subsPath, method: "GET"))
        return try Self.logged(data, label: "subscriptions") { try Self.parseSubscriptions($0) }
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
        // try?-with-reason (audit 01.08): the POST itself SUCCEEDED — throwing
        // on a broken timestamp body would falsely fail the upload. Marker 0
        // only widens the next fetch window (idempotent), it deletes nothing.
        return (try? JSONDecoder().decode(TimestampResp.self, from: data))?.timestamp ?? 0
    }

    // MARK: - Internal

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
    private func send(_ req: URLRequest, allowAuthRetry: Bool = true, attempt: Int = 0) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch {
            // Retry transient network errors (timeout, connection dropped) with a
            // short backoff before giving up — a brief server hiccup should not
            // fail the whole reconcile. A real offline error is not retried.
            if attempt < maxRetries, Self.isTransientURLError(error) {
                // Audit 01.08: propagate cancellation instead of swallowing it
                // into another retry round (isCancellation convention).
                try await Self.backoff(attempt)
                return try await send(req, allowAuthRetry: allowAuthRetry, attempt: attempt + 1)
            }
            throw GPodderError.network
        }
        guard let http = resp as? HTTPURLResponse else { throw GPodderError.network }
        // 401 with plain basic auth: some servers (e.g. gpodder.net) first want
        // a login → session cookie. Log in once and retry.
        if http.statusCode == 401, allowAuthRetry {
            try await login()
            return try await send(req, allowAuthRetry: false, attempt: attempt)
        }
        // Retry transient server errors (rate limit / 5xx).
        if attempt < maxRetries, http.statusCode == 429 || (500..<600).contains(http.statusCode) {
            try await Self.backoff(attempt)
            return try await send(req, allowAuthRetry: allowAuthRetry, attempt: attempt + 1)
        }
        guard (200..<300).contains(http.statusCode) else { throw GPodderError.status(http.statusCode) }
        return data
    }

    private let maxRetries = 2

    private static func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64((0.4 * pow(2, Double(attempt))) * 1_000_000_000))
    }

    /// Timeout / dropped connection / host unreachable are worth a retry; a clean
    /// "offline" is not (it fails fast and the app shows its offline state).
    private static func isTransientURLError(_ error: Error) -> Bool {
        [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost]
            .contains((error as NSError).code)
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - Payload parsing (pure, tested — Fix 01.08)

    /// The subscriptions body: a string array (plain form) or the change
    /// format. ANYTHING else — captive-portal HTML, a proxy login page, an
    /// empty body, foreign JSON — throws `badPayload` instead of decaying to
    /// an empty list.
    nonisolated static func parseSubscriptions(_ data: Data) throws -> [String] {
        if let arr = try? JSONDecoder().decode([String].self, from: data) { return arr }
        if let changes = try? JSONDecoder().decode(SubChanges.self, from: data) { return changes.add }
        throw GPodderError.badPayload
    }

    /// The devices body: a JSON array of objects; anything else throws.
    nonisolated static func parseDevices(_ data: Data) throws -> [[String: Any]] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GPodderError.badPayload
        }
        return arr
    }

    /// Wraps a parse with the diagnosis log (first ~120 bytes of the body) so
    /// a captive portal is identifiable from the device log.
    private nonisolated static func logged<T>(_ data: Data, label: String, _ parse: (Data) throws -> T) throws -> T {
        do { return try parse(data) }
        catch {
            let head = String(decoding: data.prefix(120), as: UTF8.self)
            Logger.gpodder.error("gpodder \(label, privacy: .public): unreadable 2xx body (\(data.count) bytes): \(head, privacy: .public)")
            throw error
        }
    }

    // MARK: - Decodables

    private nonisolated struct SubChanges: Decodable { let add: [String]; let remove: [String]; let timestamp: Int }
    private struct EpisodeActionsResp: Decodable { let actions: [GPodderEpisodeAction]; let timestamp: Int }
    private struct TimestampResp: Decodable { let timestamp: Int }
}
