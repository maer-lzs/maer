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
    /// The service is there and has no static key yet, so it cannot answer
    /// a handshake. Its own name rather than a bare `status(503)`, because
    /// it is a situation a PERSON can end: the operator lets the service
    /// make its identity once, and it never comes back. A number would send
    /// whoever reads it looking for a fault in the app.
    case serviceHasNoKey
    /// The session this request went through has ended (410). Costs one
    /// handshake and one retry, inside the tunnel; a caller sees it only
    /// when the retry met it again.
    case sessionEnded
    /// The service at the address offers a different key than the one this
    /// device holds. Nothing was sent to it. The rounds stop until a person
    /// has looked at both fingerprints.
    case serviceKeyChanged(held: String, offered: String)
    /// A 401 with `X-Maer-Refusal: password-changed`: this token was
    /// withdrawn because the account's password changed on some device.
    /// It stops the rounds like `unauthorized`, and it can say why.
    case passwordChanged
    /// 428 on a sign-in with a password the operator set: it only changes
    /// itself, nothing else happens with it.
    case operatorSetPassword
    /// 429: too many failed attempts for this owner from this address.
    /// `retryAfter` is the service's `Retry-After` in seconds, when it
    /// sent one. Never retried by itself.
    case tooManyAttempts(retryAfter: Int?)
    /// The service is older than this app: it has no key path (404 on
    /// `/v2/key`) or it answers a request inside the session with 426, the
    /// status it gives requests it reads as plain. Retrying cannot help;
    /// the rounds stop and the page says so, until the next sign-in or
    /// start (GT-20: the rounds used to retry on every occasion).
    case serviceIsOlder
    case status(Int)
    case unreadable

    /// The reason in a log line: a code or a name, never an address.
    ///
    /// The own cases come first and by name, because `sessionEnded` says
    /// more than any number a bridge could give them. Everything else is
    /// the shared rule, which used to stop at the class name here.
    static func reason(of error: Error) -> String {
        if let failure = error as? MaerSyncFailure { return String(describing: failure) }
        return FailureReason.of(error)
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
    /// A token for this device, for an owner and the PROOF of the password
    /// (contract version 6). The password itself never goes this way.
    func token(owner: String, proof: String, device: String, at baseURL: URL) async throws -> String
    /// The salt, the stretching and the form of an owner's password.
    func salt(owner: String, at baseURL: URL) async throws -> MaerSyncSalt
    /// A new password, sent only as its proof; answers a token for this
    /// device. `current` is a password itself only for an account the
    /// service reported in form `secret`.
    func changePassword(owner: String, device: String, current: MaerSyncCurrent,
                        new: MaerSyncNewPassword, at baseURL: URL) async throws -> String
    /// The status the health route answered with, or nil when a response
    /// carried none. A code, not a verdict: the caller turns it into a
    /// sentence, because an answer that refuses is not silence and must
    /// not be told as silence.
    func health(at baseURL: URL) async throws -> Int?
    /// The service's static public key and its written fingerprint, without
    /// a token. A REQUIREMENT and not only a method of the door: the sign-in
    /// calls it through `any MaerSyncTransport`, and a call through the
    /// existential binds to the protocol, so a method that only the door had
    /// would leave the witness driving something the sign-in never runs.
    func serviceKey(at baseURL: URL) async throws -> MaerSyncServiceKey
}

/// The changes socket: opened once, it hands over announcements until it
/// closes, and says so once. It never reconnects by itself. The occasions
/// the runners already have (the start, the foreground, the tick while
/// playing) open it again and fetch what was missed, so there is no timer
/// of its own to keep. `onClose` says whether the line ever stood (the
/// handshake passed and the first frame went out), so a failed open can be
/// told from an end after a while.
@MainActor
protocol MaerSyncAnnouncer: AnyObject {
    var isOpen: Bool { get }
    func open(access: MaerSyncAccess,
              onAnnouncement: @escaping @MainActor (MaerSyncAnnouncement) -> Void,
              onClose: @escaping @MainActor (_ established: Bool) -> Void)
    func close()
}

/// The network path of the device, as far as the sync needs it: it says
/// when the path CHANGED (another interface, reachability lost or back).
/// A socket opened on the old path is no proof of anything on the new one.
@MainActor
protocol MaerSyncPathSource: AnyObject {
    func onChange(_ handler: @escaping @MainActor () -> Void)
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

    /// The service's static public key, so this device can pin it, and the
    /// contract version it speaks. Version 6 answers the old key path with
    /// 404 on purpose, and this app asks no other: there is no second way.
    static func key(_ base: URL) -> URL { base.appendingPathComponent("v2/key") }

    /// The salt of an owner's password, inside a session only.
    static func salt(_ base: URL, owner: String) -> URL {
        let path = base.appendingPathComponent("v1/salt")
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else { return path }
        components.queryItems = [URLQueryItem(name: "owner", value: owner)]
        return components.url ?? path
    }

    /// Where a new password is set, inside a session only.
    static func password(_ base: URL) -> URL { base.appendingPathComponent("v1/password") }

    /// Where a handshake is traded for an encrypted session.
    static func session(_ base: URL) -> URL { base.appendingPathComponent("v1/session") }

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
    /// The one header that says who is asking. It goes into the HEAD of a
    /// sealed request, never onto a request in the clear: since version 5
    /// nothing this door sends carries it outside a session.
    static func authorization(_ access: MaerSyncAccess) -> [String: String] {
        ["Authorization": "Bearer \(access.token)"]
    }
}

/// The event a changed service key is: both fingerprints, for the page.
nonisolated struct MaerSyncKeyChange: Equatable, Sendable {
    var held: String
    var offered: String
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
    ///
    /// Tolerant PER ENTRY, like the playlists and the choices read: a value
    /// of the wrong shape costs ITS key and never the pot. The pot is the
    /// most valuable thing this app carries, and it was the only document
    /// without that property; one entry of the wrong type threw the whole
    /// thing away, and the comment above promised more than the code held
    /// (it covered lists that are too SHORT, not values of the wrong kind).
    static func decode(_ data: Data) throws -> [String: [Double]] {
        try JSONDecoder().decode([String: Entry].self, from: data)
            .compactMapValues(\.stand)
            .filter { $0.value.count >= 2 }
    }

    /// One entry that refuses to throw. A key whose value is not a list of
    /// numbers reads as nothing at all, and the decoder walks on.
    private struct Entry: Decodable {
        let stand: [Double]?

        init(from decoder: Decoder) throws {
            // tragbar, weil genau dieses Verschlucken der Zweck ist: ein Wert vom falschen Typ kostet seinen Schluessel und nicht den Topf
            stand = try? decoder.singleValueContainer().decode([Double].self)
        }
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

// MARK: - What an answer means

/// One answer of the service, reduced to what the translation reads: the
/// status, the few headers the contract names, and the body. Built from a
/// response by the door, and by hand in a witness.
nonisolated struct MaerSyncReply: Sendable {
    var status: Int
    var etag: String?
    var format: String?
    var session: String?
    /// `X-Maer-Contract`, on `/v2/key`: the contract version the service speaks.
    var contract: String?
    /// `X-Maer-Refusal`, on a 401: why the token no longer counts.
    var refusal: String?
    /// `Retry-After`, on a 429: seconds until the next attempt is taken.
    var retryAfter: String?
    var body: Data

    init(status: Int, etag: String? = nil, format: String? = nil, session: String? = nil,
         contract: String? = nil, refusal: String? = nil, retryAfter: String? = nil, body: Data = Data()) {
        self.status = status
        self.etag = etag
        self.format = format
        self.session = session
        self.contract = contract
        self.refusal = refusal
        self.retryAfter = retryAfter
        self.body = body
    }

    init(_ response: HTTPURLResponse, body: Data) {
        self.init(status: response.statusCode,
                  etag: response.value(forHTTPHeaderField: "ETag"),
                  format: response.value(forHTTPHeaderField: "X-Maer-Format"),
                  session: response.value(forHTTPHeaderField: "X-Maer-Session"),
                  contract: response.value(forHTTPHeaderField: "X-Maer-Contract"),
                  refusal: response.value(forHTTPHeaderField: "X-Maer-Refusal"),
                  retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                  body: body)
    }

    /// An inner reply out of the sealed frame, whose header names arrive
    /// in lower case.
    init(status: Int, lowercasedHeaders headers: [String: String], body: Data) {
        self.init(status: status, etag: headers["etag"], format: headers["x-maer-format"],
                  refusal: headers["x-maer-refusal"], retryAfter: headers["retry-after"], body: body)
    }
}

/// The key a service offers, with the contract version it says it speaks.
nonisolated struct MaerSyncServiceKey: Equatable, Sendable {
    let key: Data
    let fingerprint: String
    /// nil when the service sent no `X-Maer-Contract`.
    let contract: Int?
}

/// What `/v1/salt` says about an owner (contract version 6).
nonisolated struct MaerSyncSalt: Equatable, Sendable {
    enum Form: String, Sendable { case proof, secret }
    let salt: Data
    let rounds: Int
    /// `secret`: the service knows this account's password (not moved yet,
    /// or set by the operator). Such an account never signs in; it changes
    /// its password.
    let form: Form
}

/// Who asks for a password change: the proof of the password in force, or
/// for an account in form `secret`, that password itself (the move).
nonisolated enum MaerSyncCurrent: Equatable, Sendable {
    case proof(String)
    case secret(String)
}

/// The new password as it travels: only its proof, and how it was made.
nonisolated struct MaerSyncNewPassword: Equatable, Sendable {
    let proof: String
    let salt: Data
    let rounds: Int
}

/// The translation of a status line into an outcome, one per way, pure.
///
/// **This is the place where a number becomes a result, and it is the only
/// one.** The door fetches bytes and calls in here; a fence holds that the
/// door itself compares no status. Pure, so every line of the contract can
/// be driven at its edge without a service, including the two that carry
/// the most: **412 is never `written`** (a carrier empties its queue on
/// `written`, so a refused write translated as written would throw away
/// the very positions it was sending and report success), and **404 is not
/// an error but "not there yet"**, which is every device's first round.
nonisolated enum MaerSyncAnswer {
    static func document(_ reply: MaerSyncReply) throws -> MaerSyncDocument? {
        switch reply.status {
        case 200:
            guard let etag = reply.etag, let format = reply.format.flatMap({ Int($0) })
            else { throw MaerSyncFailure.unreadable }
            return MaerSyncDocument(body: reply.body, format: format, etag: etag)
        case 404: return nil
        case 401: throw refusedToken(reply)
        case 426: throw MaerSyncFailure.serviceIsOlder
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    static func written(_ reply: MaerSyncReply) throws -> MaerSyncWriteOutcome {
        switch reply.status {
        case 200:
            guard let etag = reply.etag else { throw MaerSyncFailure.unreadable }
            return .written(etag: etag)
        case 412: return .stale(current: reply.etag)
        case 409: return .refused(reason: reason(in: reply.body))
        case 401: throw refusedToken(reply)
        case 426: throw MaerSyncFailure.serviceIsOlder
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    static func listing(_ reply: MaerSyncReply) throws -> [MaerSyncListed] {
        switch reply.status {
        case 200:
            // tragbar, weil ein unlesbarer Rumpf gleich darunter als unreadable geworfen wird; der Grund reist als Fehler weiter
            guard let listing = try? JSONDecoder().decode(MaerSyncListing.self, from: reply.body) else {
                throw MaerSyncFailure.unreadable
            }
            return listing.documents.map { MaerSyncListed(scope: $0.scope, etag: $0.version, format: $0.format) }
        case 401: throw refusedToken(reply)
        case 426: throw MaerSyncFailure.serviceIsOlder
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    static func token(_ reply: MaerSyncReply) throws -> String {
        switch reply.status {
        case 200:
            // tragbar, weil ein unlesbarer Rumpf gleich darunter als unreadable geworfen wird; der Grund reist als Fehler weiter
            guard let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
                  let token = object["token"] as? String, !token.isEmpty else { throw MaerSyncFailure.unreadable }
            return token
        case 401: throw refusedToken(reply)
        case 428: throw MaerSyncFailure.operatorSetPassword
        case 429: throw MaerSyncFailure.tooManyAttempts(retryAfter: reply.retryAfter.flatMap { Int($0) })
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    /// A 401 says why when the service says why: a token withdrawn by a
    /// password change is not a token that was never good.
    static func refusedToken(_ reply: MaerSyncReply) -> MaerSyncFailure {
        reply.refusal == "password-changed" ? .passwordChanged : .unauthorized
    }

    /// `/v1/salt`: the salt, the stretching, and the form. A kdf this app
    /// does not know is unreadable; the rounds are judged by the derivation.
    static func salt(_ reply: MaerSyncReply) throws -> MaerSyncSalt {
        switch reply.status {
        case 200:
            // tragbar, weil ein unlesbarer Rumpf gleich darunter als unreadable geworfen wird; der Grund reist als Fehler weiter
            guard let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
                  let encoded = object["salt"] as? String, let salt = Data(base64Encoded: encoded),
                  object["kdf"] as? String == "pbkdf2-hmac-sha256",
                  let rounds = object["rounds"] as? Int,
                  let form = (object["form"] as? String).flatMap(MaerSyncSalt.Form.init(rawValue:))
            else { throw MaerSyncFailure.unreadable }
            return MaerSyncSalt(salt: salt, rounds: rounds, form: form)
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    /// `/v1/password`: a token for this device, or why not. A wrong
    /// `current` is 401, a `new` the service cannot read is 400.
    static func password(_ reply: MaerSyncReply) throws -> String {
        try token(reply)
    }

    /// The sentence the service sends with the one 503 that is its own.
    /// A 503 without it is somebody else's (a proxy under load, a proxy in
    /// maintenance) and stays a number, as it does on every other way.
    static let noKeySentence = "this service has no static key"

    /// The fingerprint is COMPUTED from the key's bytes; the field the
    /// service sends is read only as a cross check. A label that does not
    /// match the bytes is not "a different key", it is an answer that does
    /// not hold together, so it is unreadable.
    static func serviceKey(_ reply: MaerSyncReply) throws -> MaerSyncServiceKey {
        switch reply.status {
        case 200:
            // tragbar, weil ein unlesbarer Rumpf gleich darunter als unreadable geworfen wird; der Grund reist als Fehler weiter
            guard let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
                  let encoded = object["key"] as? String,
                  let raw = Data(base64Encoded: encoded),
                  let computed = ServiceKeyFingerprint.written(for: raw),
                  let printed = object["fingerprint"] as? String, printed == computed
            else { throw MaerSyncFailure.unreadable }
            return MaerSyncServiceKey(key: raw, fingerprint: computed, contract: reply.contract.flatMap { Int($0) })
        case 404, 426: throw MaerSyncFailure.serviceIsOlder
        case 503 where reason(in: reply.body) == noKeySentence: throw MaerSyncFailure.serviceHasNoKey
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    static func session(_ reply: MaerSyncReply) throws -> (reply: Data, session: String) {
        switch reply.status {
        case 200:
            guard let name = reply.session, !name.isEmpty else { throw MaerSyncFailure.unreadable }
            return (reply.body, name)
        case 404: throw MaerSyncFailure.serviceIsOlder
        case 503 where reason(in: reply.body) == noKeySentence: throw MaerSyncFailure.serviceHasNoKey
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    /// The OUTER answer to a sealed request: the sealed reply, or what the
    /// session said. The inner statuses are inside the bytes and are
    /// translated by the way that asked, once the tunnel has opened them.
    static func tunnel(_ reply: MaerSyncReply) throws -> Data {
        switch reply.status {
        case 200: return reply.body
        case 410: throw MaerSyncFailure.sessionEnded
        case 400: throw MaerSyncFailure.unreadable
        case 404, 426: throw MaerSyncFailure.serviceIsOlder
        case 503 where reason(in: reply.body) == noKeySentence: throw MaerSyncFailure.serviceHasNoKey
        default: throw MaerSyncFailure.status(reply.status)
        }
    }

    /// The gate's sentence out of a refusal, or the bare word when the
    /// body carried none.
    private static func reason(in data: Data) -> String {
        // tragbar, weil ein Rumpf ohne Satz nur die Logzeile aermer macht; der Statuscode traegt die Entscheidung
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["reason"] as? String ?? "refused"
    }
}

// MARK: - The service over the HTTP door

/// The service over the HTTP door, and since version 5 every way of it
/// goes THROUGH THE TUNNEL: the request is built as a frame (method, target,
/// headers with the token, body), sealed in the session for that service,
/// and the sealed reply goes through `MaerSyncAnswer`, so a compare-and-set
/// answer (412, 409) comes back as an outcome rather than an error, because
/// the caller decides what to do with it. Nothing here reads a status, and
/// nothing here puts a token on a request in the clear. The one way that
/// stays outside is the health route, a question about reach.
nonisolated final class MaerSyncHTTP: MaerSyncTransport, Sendable {
    private let tunnels: MaerSyncTunnels
    private let wire: MaerSyncWire

    init(tunnels: MaerSyncTunnels = MaerSyncTunnels(),
         wire: @escaping MaerSyncWire = { try await HTTP.data(for: $0, retry: false) }) {
        self.tunnels = tunnels
        self.wire = wire
    }

    private func inside(_ access: MaerSyncAccess, _ method: String, _ url: URL,
                        headers: [String: String] = [:], body: Data = Data()) async throws -> MaerSyncReply {
        try await tunnels.tunnel(for: access.baseURL)
            .exchange(method: method, target: MaerSyncFrame.target(of: url),
                      headers: headers.merging(MaerSyncHeaders.authorization(access)) { _, mine in mine },
                      body: body)
    }

    func fetch(kind: String, scope: String, access: MaerSyncAccess) async throws -> MaerSyncDocument? {
        try MaerSyncAnswer.document(
            try await inside(access, "GET", MaerSyncPaths.document(access.baseURL, kind: kind, scope: scope)))
    }

    func write(kind: String, scope: String, body: Data, format: Int, ifMatch: String?,
               declaredShrink: Bool, access: MaerSyncAccess) async throws -> MaerSyncWriteOutcome {
        var headers = ["Content-Type": "application/octet-stream", "X-Maer-Format": String(format)]
        if let ifMatch { headers["If-Match"] = ifMatch }
        if declaredShrink { headers["X-Maer-Declared-Shrink"] = "1" }
        return try MaerSyncAnswer.written(
            try await inside(access, "PUT", MaerSyncPaths.document(access.baseURL, kind: kind, scope: scope),
                             headers: headers, body: body))
    }

    func list(kind: String, access: MaerSyncAccess) async throws -> [MaerSyncListed] {
        try MaerSyncAnswer.listing(
            try await inside(access, "GET", MaerSyncPaths.listing(access.baseURL, kind: kind)))
    }

    /// The three sign-in ways go through the tunnel and carry no token:
    /// they are what a token comes from. Only a proof travels on the first,
    /// only a salt question on the second; the third carries a password
    /// itself only as `current.secret`, the move of an account the service
    /// reported in form `secret`.
    private func signInWay(_ method: String, _ url: URL, at baseURL: URL, body: Data = Data()) async throws -> MaerSyncReply {
        try await tunnels.tunnel(for: baseURL)
            .exchange(method: method, target: MaerSyncFrame.target(of: url),
                      headers: body.isEmpty ? [:] : ["Content-Type": "application/json"], body: body)
    }

    func token(owner: String, proof: String, device: String, at baseURL: URL) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["owner": owner, "proof": proof, "device": device])
        return try MaerSyncAnswer.token(try await signInWay("POST", MaerSyncPaths.token(baseURL), at: baseURL, body: body))
    }

    func salt(owner: String, at baseURL: URL) async throws -> MaerSyncSalt {
        try MaerSyncAnswer.salt(try await signInWay("GET", MaerSyncPaths.salt(baseURL, owner: owner), at: baseURL))
    }

    func changePassword(owner: String, device: String, current: MaerSyncCurrent,
                        new: MaerSyncNewPassword, at baseURL: URL) async throws -> String {
        let currentField: [String: String]
        switch current {
        case .proof(let proof): currentField = ["proof": proof]
        case .secret(let password): currentField = ["secret": password]
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "owner": owner, "device": device, "current": currentField,
            "new": ["proof": new.proof, "salt": new.salt.base64EncodedString(),
                    "kdf": "pbkdf2-hmac-sha256", "rounds": new.rounds] as [String: Any],
        ] as [String: Any])
        return try MaerSyncAnswer.password(try await signInWay("POST", MaerSyncPaths.password(baseURL), at: baseURL, body: body))
    }

    /// The service's static public key and its written fingerprint, in the
    /// clear, because it is what the session is made from.
    ///
    /// **No token, and it could not sensibly carry one:** this is the first
    /// thing a device asks for, before it can speak to anything privately.
    ///
    /// **This is the trust on first use channel, and the danger is named
    /// rather than hidden.** Over a plain connection whoever sits in the
    /// middle can answer with their own key. That is the chosen migration:
    /// trust the first time, hold on afterwards, and the holding is what
    /// turns a later swap into an event instead of a silence.
    func serviceKey(at baseURL: URL) async throws -> MaerSyncServiceKey {
        let (data, response) = try await wire(URLRequest(url: MaerSyncPaths.key(baseURL)))
        guard let response else { throw MaerSyncFailure.unreadable }
        return try MaerSyncAnswer.serviceKey(MaerSyncReply(response, body: data))
    }

    /// The one way that hands the number itself on: the health route is a
    /// question about reach, and its caller turns the number into a
    /// sentence with a rule of its own. In the clear, because it carries
    /// nothing and is asked before there is a session.
    func health(at baseURL: URL) async throws -> Int? {
        let (_, response) = try await wire(URLRequest(url: MaerSyncPaths.health(baseURL)))
        return response?.statusCode
    }
}

// MARK: - The changes socket

/// The changes socket over the door's socket session, inside a session of
/// its own. The receive loop runs until the task fails or is cancelled;
/// either way `onClose` says so once and the announcer is closed until the
/// next `open`.
///
/// **Its own session, not the request tunnel's:** a stream of announcements
/// interleaved with the replies of a request session would race its
/// counter. The upgrade carries the session's name instead of the token,
/// because the upgrade is the one thing on this path that is not sealed;
/// the FIRST frame this device sends is a sealed request head carrying the
/// token, and every announcement afterwards arrives as sealed bytes.
@MainActor
final class MaerSyncSocket: MaerSyncAnnouncer {
    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private(set) var isOpen = false
    private let wire: MaerSyncWire

    init(wire: @escaping MaerSyncWire = { try await HTTP.data(for: $0, retry: false) }) {
        self.wire = wire
    }

    func open(access: MaerSyncAccess,
              onAnnouncement: @escaping @MainActor (MaerSyncAnnouncement) -> Void,
              onClose: @escaping @MainActor (_ established: Bool) -> Void) {
        close()
        guard let url = MaerSyncPaths.changes(access.baseURL) else { return }
        isOpen = true
        let generation = UUID()
        openedAs = generation
        let wire = self.wire
        loop = Task { [weak self] in
            var established = false
            do {
                let line = try await MaerSyncTunnel.handshake(at: access.baseURL, wire: wire)
                var request = URLRequest(url: url)
                request.setValue(line.name, forHTTPHeaderField: "X-Maer-Session")
                let socket = HTTP.webSocket(for: request)
                guard let self, self.openedAs == generation else { socket.cancel(); return }
                self.task = socket
                socket.resume()
                let first = try MaerSyncFrame.pack(
                    head: MaerSyncFrame.requestHead(method: "GET", target: MaerSyncFrame.target(of: url),
                                                    headers: MaerSyncHeaders.authorization(access)),
                    body: Data())
                try await socket.send(.data(try await line.seal(first)))
                established = true
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case .data(let sealed) = message else { continue }
                    // tragbar, weil eine Meldung, die nicht aufgeht, nur eine verpasste Beschleunigung ist; der naechste Anlass holt nach
                    guard let opened = try? await line.unseal(sealed),
                          let announcement = Self.announcement(in: .data(opened)) else { continue }
                    onAnnouncement(announcement)
                }
            } catch {
                Logger.library.notice("MAERSYNC socket ended reason=\(MaerSyncFailure.reason(of: error), privacy: .public) cause=\(MaerSyncLiveness.Cause.closed.rawValue, privacy: .public) established=\(established)")
            }
            guard let self, self.openedAs == generation else { return }
            self.isOpen = false
            self.task = nil
            self.loop = nil
            onClose(established)
        }
    }

    /// Which `open` the running loop belongs to, so a loop that lost its
    /// place to a newer `open` does not close the newer one's socket.
    private var openedAs: UUID?

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
