// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Where the Mär sync service is and the token this device holds for it.
/// The token was issued to ONE device by the sign-in; it rides in a
/// header and never in an address, because an address is copied into
/// every access log and proxy record between the device and the service.
nonisolated struct MaerSyncAccess: Equatable, Sendable {
    var baseURL: URL
    var token: String

    /// What the person set up, or nil while no service is configured. An
    /// address without a token is not an access: the sign-in issues the
    /// token, and until then nothing runs.
    static func stored() -> MaerSyncAccess? {
        guard let url = MaerSyncPaths.normalized(AppStorageKeys.maerSyncURLValue) else { return nil }
        let token = AppStorageKeys.maerSyncTokenValue
        guard !token.isEmpty else { return nil }
        return MaerSyncAccess(baseURL: url, token: token)
    }
}

/// One document as the service hands it out: the bytes, the format the
/// writer named, and the version that is its etag.
nonisolated struct MaerSyncDocument: Equatable, Sendable {
    var body: Data
    var format: Int
    var etag: String
}

/// One entry of a listing: a scope that holds a document, the version
/// that reads back, its format. Names only, never bodies.
nonisolated struct MaerSyncListed: Equatable, Sendable {
    var scope: String
    var etag: String
    var format: Int
}

/// What a write came back as. `stale` is the compare-and-set saying no:
/// the version named is not the stored one, and `current` is the stored
/// one when the service said it. `refused` is one of the gates, and the
/// sentence names which.
nonisolated enum MaerSyncWriteOutcome: Equatable, Sendable {
    case written(etag: String)
    case stale(current: String?)
    case refused(reason: String)
}

/// One announcement off the changes socket: which document moved.
nonisolated struct MaerSyncAnnouncement: Equatable, Sendable {
    var kind: String
    var scope: String
    var version: String
}

/// Why the service could not answer. `unauthorized` stops the rounds
/// until the person signs in again; the rest is tried again at the next
/// occasion.
nonisolated enum MaerSyncFailure: Error, Equatable, Sendable {
    case unauthorized
    case status(Int)
    case unreadable

    /// The reason in a log line: a code or a type, never an address.
    static func reason(of error: Error) -> String {
        if let failure = error as? MaerSyncFailure { return String(describing: failure) }
        if let urlError = error as? URLError { return "urlError=\(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }
}

/// The last refusal the service gave this device, for the settings page:
/// a refused write is the one failure that must not stay silent (a pot
/// that shrank, a format the service holds newer), and the queue waits
/// behind it until someone looks.
nonisolated struct MaerSyncRefusal: Equatable, Sendable {
    var kind: String
    var reason: String
    var at: Date
}

/// The questions the carriers ask the service. Small on purpose: a
/// witness answers them from a dictionary.
protocol MaerSyncTransport: AnyObject, Sendable {
    /// The document, or nil when the service holds none.
    func fetch(kind: String, scope: String, access: MaerSyncAccess) async throws -> MaerSyncDocument?
    /// `declaredShrink` says "I meant to make it smaller". The stands
    /// never declare it: a smaller pot is the loss the service refuses.
    func write(kind: String, scope: String, body: Data, format: Int, ifMatch: String?,
               declaredShrink: Bool, access: MaerSyncAccess) async throws -> MaerSyncWriteOutcome
    func list(kind: String, access: MaerSyncAccess) async throws -> [MaerSyncListed]
    /// A token for this device, for an owner and a secret. The secret is
    /// sent once and kept nowhere.
    func token(owner: String, secret: String, device: String, at baseURL: URL) async throws -> String
    func health(at baseURL: URL) async throws -> Bool
}

/// The changes socket: opened once, it hands over announcements until it
/// closes, and says so once. It never reconnects by itself. The occasions
/// the runners already have (the start, the foreground, the tick while
/// playing) open it again and fetch what was missed, so there is no timer
/// of its own to keep.
@MainActor
protocol MaerSyncAnnouncer: AnyObject {
    var isOpen: Bool { get }
    func open(access: MaerSyncAccess,
              onAnnouncement: @escaping @MainActor (MaerSyncAnnouncement) -> Void,
              onClose: @escaping @MainActor () -> Void)
    func close()
}

// MARK: - The addresses, in one place

/// The addresses of the service. A token goes into none of them.
nonisolated enum MaerSyncPaths {
    static func document(_ base: URL, kind: String, scope: String) -> URL {
        let path = base.appendingPathComponent("v1/doc/\(kind)")
        guard !scope.isEmpty,
              var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else { return path }
        components.queryItems = [URLQueryItem(name: "scope", value: scope)]
        return components.url ?? path
    }

    static func listing(_ base: URL, kind: String) -> URL {
        base.appendingPathComponent("v1/docs/\(kind)")
    }

    static func token(_ base: URL) -> URL { base.appendingPathComponent("v1/token") }

    static func health(_ base: URL) -> URL { base.appendingPathComponent("v1/health") }

    /// The socket's address: the same host, over wss where the service is
    /// reached over https and over ws otherwise.
    static func changes(_ base: URL) -> URL? {
        guard var components = URLComponents(url: base.appendingPathComponent("v1/changes"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = base.scheme?.lowercased() == "https" ? "wss" : "ws"
        return components.url
    }

    /// A typed address as a base: trimmed, without a trailing slash, http
    /// or https with a host, or nil. A user or password in it is refused
    /// rather than stripped. The service takes a token, and an address
    /// that carries a secret is the one shape that must never be stored.
    static func normalized(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// The one header every request to the service carries.
nonisolated enum MaerSyncHeaders {
    static func authorize(_ request: inout URLRequest, _ access: MaerSyncAccess) {
        request.setValue("Bearer \(access.token)", forHTTPHeaderField: "Authorization")
    }
}

// MARK: - The documents as bytes

/// The stands document: JSON, item id to entry (`[position, updatedAtMs,
/// duration?, form?]`), keys sorted so the same pot gives the same bytes.
nonisolated enum MaerSyncStandsWire {
    static let format = 1

    static func encode(_ stands: [String: [Double]]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stands)
    }

    /// Entries with fewer than a position and a moment are not stands and
    /// are dropped, like the blob's half entries. Bytes that are not the
    /// document at all throw: unreadable is not empty.
    static func decode(_ data: Data) throws -> [String: [Double]] {
        try JSONDecoder().decode([String: [Double]].self, from: data).filter { $0.value.count >= 2 }
    }
}

/// The claim document: the claim's plist form as JSON, so the wire says
/// exactly what the key-value store says and a field added there travels
/// here without a second definition.
nonisolated enum MaerSyncClaimWire {
    static let format = 1

    static func encode(_ claim: PlaybackClaim) throws -> Data {
        try JSONSerialization.data(withJSONObject: claim.plist, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> PlaybackClaim? {
        // tragbar, weil ein unlesbarer Anspruch wie keiner zaehlt: der naechste Schrieb des Geraets ersetzt ihn
        PlaybackClaim.from(plist: try? JSONSerialization.jsonObject(with: data))
    }
}

/// The statistics pot of one device: its own Codable form as JSON with
/// sorted keys, so the same pot gives the same bytes. Format 1.
nonisolated enum MaerSyncStatsWire {
    static let format = 1

    static func encode(_ pot: ListeningStatsData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(pot)
    }

    static func decode(_ data: Data) -> ListeningStatsData? {
        // tragbar, weil ein unlesbarer fremder Topf wie keiner zaehlt; der naechste Schrieb des Geraets ersetzt ihn
        try? JSONDecoder().decode(ListeningStatsData.self, from: data)
    }
}

/// What a listing answers with.
nonisolated private struct MaerSyncListing: Decodable {
    struct Entry: Decodable {
        var scope: String
        var version: String
        var format: Int
    }
    var documents: [Entry]
}

// MARK: - The service over the HTTP door

/// The service over the HTTP door: every request carries the token as a
/// bearer header, the door adds the identity and the retry ladder, and a
/// compare-and-set answer (412, 409) comes back as an outcome rather than
/// an error, because the caller decides what to do with it.
nonisolated final class MaerSyncHTTP: MaerSyncTransport, Sendable {
    init() {}

    func fetch(kind: String, scope: String, access: MaerSyncAccess) async throws -> MaerSyncDocument? {
        var request = URLRequest(url: MaerSyncPaths.document(access.baseURL, kind: kind, scope: scope))
        MaerSyncHeaders.authorize(&request, access)
        let (data, response) = try await HTTP.data(for: request)
        guard let response else { throw MaerSyncFailure.unreadable }
        switch response.statusCode {
        case 200:
            guard let etag = response.value(forHTTPHeaderField: "ETag"),
                  let format = response.value(forHTTPHeaderField: "X-Maer-Format").flatMap({ Int($0) })
            else { throw MaerSyncFailure.unreadable }
            return MaerSyncDocument(body: data, format: format, etag: etag)
        case 404: return nil
        case 401: throw MaerSyncFailure.unauthorized
        default: throw MaerSyncFailure.status(response.statusCode)
        }
    }

    func write(kind: String, scope: String, body: Data, format: Int, ifMatch: String?,
               declaredShrink: Bool, access: MaerSyncAccess) async throws -> MaerSyncWriteOutcome {
        var request = URLRequest(url: MaerSyncPaths.document(access.baseURL, kind: kind, scope: scope))
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(format), forHTTPHeaderField: "X-Maer-Format")
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        if declaredShrink { request.setValue("1", forHTTPHeaderField: "X-Maer-Declared-Shrink") }
        MaerSyncHeaders.authorize(&request, access)
        let (data, response) = try await HTTP.data(for: request)
        guard let response else { throw MaerSyncFailure.unreadable }
        switch response.statusCode {
        case 200:
            guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw MaerSyncFailure.unreadable }
            return .written(etag: etag)
        case 412: return .stale(current: response.value(forHTTPHeaderField: "ETag"))
        case 409: return .refused(reason: Self.reason(in: data))
        case 401: throw MaerSyncFailure.unauthorized
        default: throw MaerSyncFailure.status(response.statusCode)
        }
    }

    func list(kind: String, access: MaerSyncAccess) async throws -> [MaerSyncListed] {
        var request = URLRequest(url: MaerSyncPaths.listing(access.baseURL, kind: kind))
        MaerSyncHeaders.authorize(&request, access)
        let (data, response) = try await HTTP.data(for: request)
        guard let response else { throw MaerSyncFailure.unreadable }
        switch response.statusCode {
        case 200:
            // tragbar, weil ein unlesbarer Rumpf gleich darunter als unreadable geworfen wird; der Grund reist als Fehler weiter
            guard let listing = try? JSONDecoder().decode(MaerSyncListing.self, from: data) else {
                throw MaerSyncFailure.unreadable
            }
            return listing.documents.map { MaerSyncListed(scope: $0.scope, etag: $0.version, format: $0.format) }
        case 401: throw MaerSyncFailure.unauthorized
        default: throw MaerSyncFailure.status(response.statusCode)
        }
    }

    func token(owner: String, secret: String, device: String, at baseURL: URL) async throws -> String {
        var request = URLRequest(url: MaerSyncPaths.token(baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["owner": owner, "secret": secret, "device": device])
        // No retry: the ladder would send the secret again on a hiccup,
        // and a sign-in is a thing the person repeats, not the app.
        let (data, response) = try await HTTP.data(for: request, retry: false)
        guard let response else { throw MaerSyncFailure.unreadable }
        switch response.statusCode {
        case 200:
            // tragbar, weil ein unlesbarer Rumpf gleich darunter als unreadable geworfen wird; der Grund reist als Fehler weiter
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = object["token"] as? String, !token.isEmpty else { throw MaerSyncFailure.unreadable }
            return token
        case 401: throw MaerSyncFailure.unauthorized
        default: throw MaerSyncFailure.status(response.statusCode)
        }
    }

    func health(at baseURL: URL) async throws -> Bool {
        let (_, response) = try await HTTP.data(for: URLRequest(url: MaerSyncPaths.health(baseURL)), retry: false)
        return response?.statusCode == 200
    }

    /// The gate's sentence out of a refusal, or the bare word when the
    /// body carried none.
    private static func reason(in data: Data) -> String {
        // tragbar, weil ein Rumpf ohne Satz nur die Logzeile aermer macht; der Statuscode traegt die Entscheidung
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["reason"] as? String ?? "refused"
    }
}

// MARK: - The changes socket

/// The changes socket over the door's socket session. The receive loop
/// runs until the task fails or is cancelled; either way `onClose` says
/// so once and the announcer is closed until the next `open`.
@MainActor
final class MaerSyncSocket: MaerSyncAnnouncer {
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private(set) var isOpen = false

    func open(access: MaerSyncAccess,
              onAnnouncement: @escaping @MainActor (MaerSyncAnnouncement) -> Void,
              onClose: @escaping @MainActor () -> Void) {
        close()
        guard let url = MaerSyncPaths.changes(access.baseURL) else { return }
        var request = URLRequest(url: url)
        MaerSyncHeaders.authorize(&request, access)
        let socket = HTTP.webSocket(for: request)
        task = socket
        isOpen = true
        socket.resume()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    if let announcement = Self.announcement(in: message) { onAnnouncement(announcement) }
                } catch {
                    break
                }
            }
            guard let self, self.task === socket else { return }
            self.isOpen = false
            self.task = nil
            self.loop = nil
            onClose()
        }
    }

    func close() {
        loop?.cancel()
        loop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isOpen = false
    }

    /// The announcement in a frame, or nil for a frame that is not one.
    nonisolated static func announcement(in message: URLSessionWebSocketTask.Message) -> MaerSyncAnnouncement? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return nil
        }
        // tragbar, weil eine unlesbare Meldung nur eine verpasste Beschleunigung ist; der naechste Anlass holt nach
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = object["kind"] as? String,
              let version = object["version"] as? String else { return nil }
        return MaerSyncAnnouncement(kind: kind, scope: object["scope"] as? String ?? "", version: version)
    }
}
