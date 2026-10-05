// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// HTTP client for the gpodder sync API (mygpo protocol) as spoken by oPodSync,
/// Nextcloud GPodder and gpodder.net. Auth: HTTP Basic (login also sets a
/// session cookie, sent along by the shared cookie store). Pure transport. The
/// reconcile logic lives in `GPodderSync`.
enum GPodderError: Error, LocalizedError {
    case badURL, network, status(Int), badPayload
    /// A 401 or 403 that survived the login retry: the credentials, or a
    /// block on this network. The number rides along.
    case signIn(Int)
    /// Basic auth cannot carry a colon in the user name (RFC 7617): the
    /// server would split the name there. Nothing is sent.
    case colonInUserName
    var errorDescription: String? {
        switch self {
        case .colonInUserName: return String(localized: "A gpodder user name cannot contain a colon.")
        case .badURL: return String(localized: "Invalid server URL.")
        case .network: return String(localized: "Cannot reach the gpodder server.")
        case .status(let c): return String(localized: "The server responded with HTTP \(c).")
        case .signIn(let c): return String(localized: "The gpodder server rejected the login (HTTP \(c)).")
        // Fix 01.08: a 2xx with an unreadable body (captive portal, proxy
        // login page) must surface as an ERROR. It silently became "0
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

    init(config: GPodderConfig) {
        self.config = config
    }

    // MARK: - Public API

    /// Register THIS device (idempotent upsert in the gpodder API): required
    /// by stricter servers (PodFetch/Pinepods/Nextcloud) that 404 unknown
    /// device ids; oPodSync creates devices implicitly, so this is additive.
    func registerDevice(caption: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "caption": caption, "type": "mobile",
        ])
        var req = try request("api/2/devices/\(Self.segment(config.username))/\(Self.segment(config.deviceId)).json",
                              method: "POST")
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(req)
    }

    /// The registered devices (cheap probe for the sync history).
    func devices() async throws -> [[String: Any]] {
        let data = try await send(try request("api/2/devices/\(Self.segment(config.username)).json", method: "GET"))
        return try Self.logged(data, label: "devices") { try Self.parseDevices($0) }
    }

    /// Login via Basic auth → session cookie. Throws on wrong credentials.
    func login() async throws {
        _ = try await send(request("api/2/auth/\(Self.segment(config.username))/login.json", method: "POST"),
                           allowAuthRetry: false)
    }

    /// Full current subscription list of this device (URLs). An unreadable
    /// 2xx body THROWS (`badPayload`). "connection went weird" must never
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
            "api/2/episodes/\(Self.segment(config.username)).json",
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
        let data = try await send(request("api/2/episodes/\(Self.segment(config.username)).json",
                                          method: "POST", body: body))
        // try?-with-reason (audit 01.08): the POST itself SUCCEEDED. Throwing
        // on a broken timestamp body would falsely fail the upload. Marker 0
        // only widens the next fetch window (idempotent), it deletes nothing.
        return (try? JSONDecoder().decode(TimestampResp.self, from: data))?.timestamp ?? 0
    }

    // MARK: - Internal

    private var subsPath: String {
        "api/2/subscriptions/\(Self.segment(config.username))/\(Self.segment(config.deviceId)).json"
    }

    private func request(_ path: String, method: String,
                         query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard let url = Self.address(base: config.baseURL, path: path, query: query) else { throw GPodderError.badURL }
        guard let authorization = Self.basicAuthorization(user: config.username, password: config.password) else {
            throw GPodderError.colonInUserName
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    @discardableResult
    private func send(_ req: URLRequest, allowAuthRetry: Bool = true, attempt: Int = 0) async throws -> Data {
        let (data, resp): (Data, HTTPURLResponse?)
        // The cookie lane: session-based servers keep their login this way.
        // No door-side retry: this client runs its own loop, which knows
        // that a 401 may mean "log in first" and retries after the login.
        do { (data, resp) = try await HTTP.data(for: req, lane: .cookies, retry: false) }
        catch {
            // Retry transient network errors (timeout, connection dropped) with a
            // short backoff before giving up. A brief server hiccup should not
            // fail the whole reconcile. A real offline error is not retried.
            if attempt < maxRetries, Self.isTransientURLError(error) {
                // Audit 01.08: propagate cancellation instead of swallowing it
                // into another retry round (isCancellation convention).
                try await Self.backoff(attempt)
                return try await send(req, allowAuthRetry: allowAuthRetry, attempt: attempt + 1)
            }
            throw GPodderError.network
        }
        guard let http = resp else { throw GPodderError.network }
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
        guard (200..<300).contains(http.statusCode) else {
            // What survived the ladder above is final: a 401 has had its
            // login retry, a 429 its two waits. Only the refusal has a
            // sentence of its own; every other answer keeps its number.
            switch StatusMeaning.from(status: http.statusCode) {
            case .signIn: throw GPodderError.signIn(http.statusCode)
            case .notFound, .throttled, .server: throw GPodderError.status(http.statusCode)
            }
        }
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

    /// A user name or device id as ONE path segment, percent-encoded once:
    /// a slash inside it is encoded too, so it never splits the path.
    nonisolated static func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? s
    }

    /// Whether `path` is a valid encoded path: only characters a path may
    /// carry, and every `%` the start of a valid escape.
    nonisolated static func isEncodedPath(_ path: String) -> Bool {
        let allowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "%"))
        guard path.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return path.removingPercentEncoding != nil
    }

    /// The Basic auth header, or nil when the user name holds a colon
    /// (RFC 7617: the server reads the name up to the first colon).
    nonisolated static func basicAuthorization(user: String, password: String) -> String? {
        guard !user.contains(":") else { return nil }
        return "Basic \(Data("\(user):\(password)".utf8).base64EncodedString())"
    }

    nonisolated private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()

    /// The request address: the base's path, then `path` as it stands, its
    /// segments already encoded by `segment`. Joined on the encoded path,
    /// never through `appendingPathComponent`, which would encode every `%`
    /// a second time (a name with a space reached the server as `%20`).
    /// A path that is not encoded (a space, a stray `%`) gives nil: setting
    /// it as the encoded path would end the process (`percentEncodedPath`
    /// requires a valid encoding).
    nonisolated static func address(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        guard isEncodedPath(path) else { return nil }
        guard var comp = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = comp.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        comp.percentEncodedPath = basePath + "/" + path
        if !query.isEmpty { comp.setQuery(query) }
        return comp.url
    }

    // MARK: - Payload parsing (pure, tested. Fix 01.08)

    /// The subscriptions body: a string array (plain form) or the change
    /// format. ANYTHING else. Captive-portal HTML, a proxy login page, an
    /// empty body, foreign JSON. Throws `badPayload` instead of decaying to
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
