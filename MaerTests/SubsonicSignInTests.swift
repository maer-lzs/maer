// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import CryptoKit
import Network
import os
@testable import Maer

/// The key sign-in of a Subsonic server (Nextcloud Music), against the
/// codes measured on the test stand: the rule, the address the client
/// builds, the negotiation on the wire, the sentences, and the fence that
/// keeps the key out of every log line.
@MainActor
struct SubsonicSignInTests {
    /// A server name no other case uses, so a persisted mode cannot leak.
    static func freshServer() -> String { "signin-\(UUID().uuidString.lowercased()).test" }

    static func names(_ url: URL?) -> [String] {
        (URLComponents(url: url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map(\.name)
    }

    static func value(_ name: String, in url: URL?) -> String? {
        URLComponents(url: url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    // MARK: The rule

    @Test("mit dem Schluessel reist nichts anderes: kein u, t, s oder p")
    func theKeyTravelsAlone() {
        let items = SubsonicSignIn.items(.apiKey, username: "hoerer", secret: "k", token: "t0", salt: "s0")
        #expect(items.map(\.name) == ["apiKey"])
        #expect(items.first?.value == "k")
        let token = SubsonicSignIn.items(.token, username: "hoerer", secret: "k", token: "t0", salt: "s0")
        #expect(token.map(\.name) == ["u", "t", "s"], "die Token-Anmeldung wie vor E3")
        #expect(!token.contains { $0.value == "k" }, "das Passwort reist beim Token nie im Klartext")
    }

    @Test("nach einem Code: 41 nur mit Angebot UND verschluesselt zum Schluessel, 42 zurueck zum Token")
    func decisionTable() {
        func d(_ code: Int, _ mode: SubsonicSignIn.Mode, offers: Bool = true, safe: Bool = true) -> SubsonicSignIn.Decision {
            SubsonicSignIn.decision(afterCode: code, current: mode, offersKeySignIn: offers, transportIsSafe: safe)
        }
        #expect(d(41, .token) == .retry(.apiKey))
        #expect(d(41, .token, safe: false) == .needsEncryption, "ueber http nie der Schluessel")
        #expect(d(41, .token, offers: false) == .stand)
        #expect(d(41, .token, offers: false, safe: false) == .stand, "ohne Angebot bleibt der Satz von 41")
        #expect(d(42, .apiKey) == .retry(.token))
        #expect(d(41, .apiKey) == .stand)
        for code in [40, 43, 44, 10, 30, 70] {
            #expect(d(code, .token) == .stand)
            #expect(d(code, .apiKey) == .stand)
        }
    }

    @Test("nur https traegt den Schluessel")
    func onlyHTTPSCarriesTheKey() throws {
        #expect(SubsonicSignIn.keyTransportIsSafe(try #require(URL(string: "https://music.example/sub"))))
        #expect(SubsonicSignIn.keyTransportIsSafe(try #require(URL(string: "HTTPS://music.example/sub"))))
        #expect(!SubsonicSignIn.keyTransportIsSafe(try #require(URL(string: "http://music.example/sub"))))
        #expect(!SubsonicSignIn.keyTransportIsSafe(try #require(URL(string: "http://127.0.0.1:4533"))))
    }

    /// The wire corpus of the test stand (10.09. and 23.09.): Nextcloud
    /// Music offers the key sign-in, Navidrome does not.
    @Test("die Erweiterungen am Wire-Korpus: Nextcloud Music ja, Navidrome nein")
    func extensionsFromTheCorpus() throws {
        let nextcloud = #"{"subsonic-response":{"openSubsonicExtensions":[{"name":"apiKeyAuthentication","versions":[1]},{"name":"formPost","versions":[1]},{"name":"getPodcastEpisode","versions":[1]},{"name":"songLyrics","versions":[1]},{"name":"indexBasedQueue","versions":[1]}],"status":"ok","version":"1.16.1","type":"nextcloud music","serverVersion":"3.2.1","openSubsonic":true}}"#
        let navidrome = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.63.2 (be10f89c)","openSubsonic":true,"openSubsonicExtensions":[{"name":"transcodeOffset","versions":[1]},{"name":"formPost","versions":[1]},{"name":"songLyrics","versions":[1,2]},{"name":"indexBasedQueue","versions":[1]},{"name":"transcoding","versions":[1]},{"name":"playbackReport","versions":[1]}]}}"#
        let nc = try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(nextcloud.utf8)).subsonicResponse
        let nd = try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(navidrome.utf8)).subsonicResponse
        #expect(nc.openSubsonicExtensions?.count == 5, "the corpus was read")
        #expect(nd.openSubsonicExtensions?.count == 6, "the corpus was read")
        #expect(SubsonicSignIn.offersKeySignIn(nc.openSubsonicExtensions ?? []))
        #expect(!SubsonicSignIn.offersKeySignIn(nd.openSubsonicExtensions ?? []))
        #expect(!SubsonicSignIn.offersKeySignIn([.init(name: "apiKeyAuthentication", versions: [2])]),
                "a version this client does not speak is no offer")
    }

    // MARK: The address the client builds

    @Test("die gebaute Adresse: Token wie vor E3, Schluessel ohne u, t, s, p")
    func theBuiltAddress() throws {
        let server = Self.freshServer()
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.\(server)/sub") }
        let client = try #require(SubsonicClient(serverURL: "https://\(server)/sub", username: "hoerer", password: "geheim-42"))

        let before = client.mediaURL("stream", ["id": "x"])
        #expect(Self.names(before) == ["u", "t", "s", "v", "c", "f", "id"], "Reihenfolge wie vor E3")
        let salt = try #require(Self.value("s", in: before))
        let expected = Insecure.MD5.hash(data: Data(("geheim-42" + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(Self.value("t", in: before) == expected, "der Token ist md5(Passwort + Salz) wie vor E3")

        SubsonicClient.persistSignIn(.apiKey, server: "\(server)/sub")
        #expect(AppStorageKeys.string("subsonicSignIn.\(server)/sub") == "apiKey",
                "gespeichert wird nur die Art, nie der Schluessel")
        let keyed = client.mediaURL("stream", ["id": "x"])
        #expect(Self.names(keyed) == ["apiKey", "v", "c", "f", "id"])
        #expect(Self.value("apiKey", in: keyed) == "geheim-42")
        for name in ["u", "t", "s", "p"] {
            #expect(!Self.names(keyed).contains(name), "\(name) reist neben dem Schluessel")
        }
    }

    @Test("eine gemerkte Schluessel-Art gilt nicht fuer eine http-Adresse")
    func aStoredKeyModeStaysOffPlainHTTP() throws {
        let server = Self.freshServer()
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.\(server)/sub") }
        SubsonicClient.persistSignIn(.apiKey, server: "\(server)/sub")
        let plain = try #require(SubsonicClient(serverURL: "http://\(server)/sub", username: "hoerer", password: "geheim-42"))
        let url = plain.mediaURL("stream", ["id": "x"])
        #expect(Self.names(url) == ["u", "t", "s", "v", "c", "f", "id"], "ueber http der Token")
        #expect(Self.value("apiKey", in: url) == nil && !(url?.absoluteString.contains("geheim-42") ?? true),
                "das Passwort steht nicht in der Adresse")
        let secure = try #require(SubsonicClient(serverURL: "https://\(server)/sub", username: "hoerer", password: "geheim-42"))
        #expect(Self.names(secure.mediaURL("stream", ["id": "x"])).first == "apiKey", "Gegenprobe: https traegt ihn")
    }

    // MARK: The negotiation on the wire

    /// A loopback server that answers like Nextcloud Music as measured:
    /// token 41, extensions public, key alone ok, key plus user 43.
    @Test("am Draht: Token 41, Erweiterungen ohne Anmeldung, dann der Schluessel allein")
    func theNegotiationOnTheWire() async throws {
        let stand = try await Loopback.start(offersKey: true, key: "geheim-42")
        defer { stand.stop() }
        let base = "http://127.0.0.1:\(stand.port)/sub"
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.127.0.0.1/sub") }
        AppStorageKeys.set(nil, for: "subsonicSignIn.127.0.0.1/sub")
        // The loopback speaks plain http; the witness hands in a transport
        // check that trusts it, the app's own check is https only.
        let trustsLoopback: @Sendable (URL) -> Bool = { _ in true }
        let built = SubsonicClient(serverURL: base, username: "hoerer", password: "geheim-42",
                                   keyTransportIsSafe: trustsLoopback)
        let client = try #require(built)
        try await client.ping()
        let seen = stand.requests
        #expect(seen.count == 3, "ping mit Token, Erweiterungen, ping mit Schluessel: \(seen.map(\.endpoint))")
        #expect(seen.map(\.endpoint) == ["ping", "getOpenSubsonicExtensions", "ping"])
        #expect(seen.first?.names.contains("t") == true, "zuerst der Token wie heute")
        #expect(seen.dropFirst().first.map { !$0.names.contains("u") && !$0.names.contains("apiKey") } == true,
                "die Erweiterungen werden ohne jede Anmeldung gefragt")
        #expect(seen.last?.names.prefix(1) == ["apiKey"])
        #expect(seen.last.map { Set($0.names).isDisjoint(with: ["u", "t", "s", "p"]) } == true)
        #expect(SubsonicClient.negotiatedSignIn(server: "127.0.0.1/sub") == .apiKey)
        // The next request goes straight to the key, no second negotiation.
        try await client.ping()
        #expect(stand.requests.count == 4 && stand.requests.last?.names.first == "apiKey")
    }

    @Test("am Draht: ein Server ohne Schluessel-Angebot behaelt 41 und seinen Satz")
    func noOfferKeepsTheRefusal() async throws {
        let stand = try await Loopback.start(offersKey: false, key: "geheim-42")
        defer { stand.stop() }
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.127.0.0.1/sub") }
        AppStorageKeys.set(nil, for: "subsonicSignIn.127.0.0.1/sub")
        let client = try #require(SubsonicClient(serverURL: "http://127.0.0.1:\(stand.port)/sub",
                                                 username: "hoerer", password: "geheim-42"))
        var caught: SubsonicClient.SubsonicError?
        do { try await client.ping() } catch let error as SubsonicClient.SubsonicError { caught = error }
        #expect(caught == .api(code: 41, message: "Token-based authentication not supported"))
        #expect(SubsonicClient.negotiatedSignIn(server: "127.0.0.1/sub") == nil, "nichts gewechselt")
        #expect(!stand.requests.contains { $0.names.contains("apiKey") }, "kein Schluessel ohne Angebot")
    }

    @Test("am Draht ueber http: Angebot und 41, aber kein Schluessel, ein eigener Satz")
    func plainHTTPNeverSendsTheKey() async throws {
        let stand = try await Loopback.start(offersKey: true, key: "geheim-42")
        defer { stand.stop() }
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.127.0.0.1/sub") }
        AppStorageKeys.set(nil, for: "subsonicSignIn.127.0.0.1/sub")
        let client = try #require(SubsonicClient(serverURL: "http://127.0.0.1:\(stand.port)/sub",
                                                 username: "hoerer", password: "geheim-42"))
        var caught: SubsonicClient.SubsonicError?
        do { try await client.ping() } catch let error as SubsonicClient.SubsonicError { caught = error }
        #expect(caught == .keySignInNeedsEncryption)
        #expect(stand.requests.map(\.endpoint) == ["ping", "getOpenSubsonicExtensions"],
                "nach dem Angebot keine weitere Anfrage: \(stand.requests.map(\.endpoint))")
        #expect(!stand.requests.contains { $0.names.contains("apiKey") }, "kein Schluessel ueber http")
        #expect(SubsonicClient.negotiatedSignIn(server: "127.0.0.1/sub") == nil, "nichts gemerkt")
    }

    // MARK: A redirect to an unencrypted address

    /// The loopback plays both roles: `127.0.0.1` is the trusted address
    /// (the witness's transport check), `localhost` on the same port the
    /// unencrypted one a redirect points to.
    nonisolated static func trusting127(_ url: URL) -> Bool { url.host == "127.0.0.1" }

    @Test("mit Schluessel folgt der Client keiner Umleitung auf eine unverschluesselte Adresse")
    func theKeyDoesNotFollowARedirectToPlainHTTP() async throws {
        let stand = try await Loopback.start(offersKey: true, key: "geheim-42")
        defer { stand.stop() }
        let server = "127.0.0.1/sub"
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.\(server)") }
        SubsonicClient.persistSignIn(.apiKey, server: server)
        stand.redirectOnce(to: "localhost")
        let trusts: @Sendable (URL) -> Bool = { Self.trusting127($0) }
        let built = SubsonicClient(serverURL: "http://127.0.0.1:\(stand.port)/sub", username: "hoerer",
                                   password: "geheim-42", keyTransportIsSafe: trusts)
        let client = try #require(built)
        var caught: SubsonicClient.SubsonicError?
        do { try await client.ping() } catch let error as SubsonicClient.SubsonicError { caught = error }
        #expect(caught == .keySignInNeedsEncryption, "der Satz aus E3-1: \(String(describing: caught))")
        #expect(stand.requests.count == 1, "die Umleitung wurde nicht verfolgt: \(stand.requests.count) Anfragen")
    }

    @Test("Gegenprobe: eine Umleitung auf eine erlaubte Adresse wird verfolgt, und der Token folgt jeder wie heute")
    func allowedRedirectsAreFollowed() async throws {
        let stand = try await Loopback.start(offersKey: true, key: "geheim-42")
        defer { stand.stop() }
        let server = "127.0.0.1/sub"
        defer { AppStorageKeys.set(nil, for: "subsonicSignIn.\(server)") }
        SubsonicClient.persistSignIn(.apiKey, server: server)
        stand.redirectOnce(to: "localhost")
        let trustsAll: @Sendable (URL) -> Bool = { _ in true }
        let keyed = try #require(SubsonicClient(serverURL: "http://127.0.0.1:\(stand.port)/sub", username: "hoerer",
                                                password: "geheim-42", keyTransportIsSafe: trustsAll))
        try await keyed.ping()
        #expect(stand.requests.count == 2, "die erlaubte Umleitung wurde verfolgt")
        // The token carries no clear-text secret and keeps today's behaviour:
        // no guard, a redirect is followed.
        AppStorageKeys.set(nil, for: "subsonicSignIn.\(server)")
        let tokenStand = try await Loopback.start(offersKey: false, key: "geheim-42")
        defer { tokenStand.stop() }
        tokenStand.redirectOnce(to: "localhost")
        let token = try #require(SubsonicClient(serverURL: "http://127.0.0.1:\(tokenStand.port)/sub",
                                                username: "hoerer", password: "geheim-42"))
        _ = try? await token.ping()
        let seen = tokenStand.requests
        #expect(seen.count >= 2 && seen[1].endpoint == "ping" && seen[1].names.contains("t"),
                "der Token folgte der Umleitung: \(seen.map(\.endpoint))")
    }

    // MARK: The sentences

    @Test("die Saetze folgen den gemessenen Codes; 41 und 43 sagen dasselbe")
    func sentences() {
        func text(_ code: Int) -> String? { SubsonicClient.SubsonicError.api(code: code, message: "raw").errorDescription }
        #expect(text(41) == text(43))
        #expect(text(44) != text(41) && text(10) != text(41) && text(44) != text(10))
        #expect(text(40) == String(localized: "Wrong username or password."), "40 wie vor E3")
        #expect(text(70) == "raw", "ein anderer Code behaelt die Meldung des Servers")
        let https = SubsonicClient.SubsonicError.keySignInNeedsEncryption.errorDescription
        #expect(https != nil && https != text(41) && https != text(44), "http hat seinen eigenen Satz")
        #expect(SubsonicSignIn.refusal(forCode: 43) == .mechanismMismatch)
        #expect(SubsonicSignIn.refusal(forCode: 44) == .wrongKey)
        #expect(SubsonicSignIn.refusal(forCode: 10) == .noSignIn)
    }

    // MARK: E3c, the fence

    /// The interpolated expressions of every `Logger.` line in a text.
    nonisolated static func loggedExpressions(in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") where line.contains("Logger.")
            && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            var rest = Substring(line)
            while let open = rest.range(of: "\\(") {
                let tail = rest[open.upperBound...]
                var depth = 1, end = tail.startIndex
                for index in tail.indices {
                    if tail[index] == "(" { depth += 1 }
                    if tail[index] == ")" { depth -= 1; if depth == 0 { end = index; break } }
                }
                out.append(String(tail[..<end]))
                rest = tail[end...]
            }
        }
        return out
    }

    /// Words that name a credential or the builder of an address that
    /// carries one. A plain address is the neighbouring fence's
    /// (`PublicLogAddressFenceTests`), and a host is no credential.
    nonisolated static let credentialWords = ["password", "apikey", "secret", "token", "salt",
                                              "requesturl", "queryitems"]

    nonisolated static func credentialExpressions(in text: String) -> [String] {
        loggedExpressions(in: text).filter { expr in
            let lower = expr.lowercased()
            return credentialWords.contains { lower.contains($0) }
        }
    }

    @Test("keine Logzeile der Subsonic-Anmeldung nennt einen Zugangswert", .needsTheSources)
    func noLogLineNamesACredential() throws {
        let files = ["Sources/Networking/SubsonicClient.swift", "Sources/Providers/SubsonicProvider.swift",
                     "Sources/Models/SubsonicSignIn.swift"]
        var read = 0
        for file in files {
            let text = try String(contentsOf: SourceTree.root.appendingPathComponent(file), encoding: .utf8)
            read += text.contains("Logger.") || file.hasSuffix("SubsonicSignIn.swift") ? 1 : 0
            #expect(Self.credentialExpressions(in: text).isEmpty, "\(file): \(Self.credentialExpressions(in: text))")
        }
        #expect(read == files.count, "der Zaun hat seine Dateien gelesen")
        #expect(Self.credentialExpressions(in: #"Logger.music.notice("x \(password, privacy: .public)")"#) == ["password, privacy: .public"])
        #expect(Self.credentialExpressions(in: #"Logger.music.notice("u \(requestURL("ping")?.query ?? "")")"#).count == 1)
        #expect(Self.credentialExpressions(in: #"Logger.music.notice("to \(next.rawValue, privacy: .public) for \(self.baseURL.host ?? "?", privacy: .public)")"#).isEmpty,
                "die Art und der Host sind keine Zugangswerte")
        #expect(Self.credentialExpressions(in: #"Logger.music.error("client built WITHOUT a password")"#).isEmpty,
                "ein Wort im Text ist kein Wert")
    }
}

/// A plain HTTP/1.1 server on the loopback, one request per connection,
/// read up to the end of the head (never to the end of the stream).
/// Unchecked because one lock guards the recorded requests.
nonisolated final class Loopback: @unchecked Sendable {
    struct Seen: Sendable {
        let endpoint: String
        let names: [String]
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var seen: [Seen] = []
    private let offersKey: Bool
    /// When set, the first `ping` answers with a redirect to this host on
    /// the same port and path; every later request is served.
    private var redirectHost: String?

    func redirectOnce(to host: String) { lock.withLock { redirectHost = host } }
    private let key: String
    private(set) var port: UInt16 = 0

    var requests: [Seen] { lock.withLock { seen } }

    private init(offersKey: Bool, key: String) throws {
        self.offersKey = offersKey
        self.key = key
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(offersKey: Bool, key: String) async throws -> Loopback {
        let server = try Loopback(offersKey: offersKey, key: key)
        server.listener.newConnectionHandler = { [server] connection in server.serve(connection) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            server.listener.stateUpdateHandler = { [server] state in
                let first = once.withLock { done in
                    let was = done
                    if case .ready = state { done = true } else if case .failed = state { done = true }
                    return !was && done
                }
                if first, case .ready = state { continuation.resume(returning: server.listener.port?.rawValue ?? 0) }
                if first, case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            server.listener.start(queue: .global())
        }
        server.port = port
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                answer(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if !done, error == nil {
                receiveHead(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String) {
        let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let comps = URLComponents(string: target)
        let endpoint = (comps?.path.split(separator: "/").last.map(String.init) ?? "")
            .replacingOccurrences(of: ".view", with: "")
        let items = comps?.queryItems ?? []
        let names = items.map(\.name)
        lock.withLock { seen.append(Seen(endpoint: endpoint, names: names)) }
        let redirect: String? = lock.withLock {
            guard endpoint == "ping", let host = redirectHost else { return nil }
            redirectHost = nil
            return host
        }
        if let redirect {
            let response = "HTTP/1.1 302 Found\r\nLocation: http://\(redirect):\(port)\(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let json: String
        if endpoint == "getOpenSubsonicExtensions" {
            let offer = offersKey ? #"{"name":"apiKeyAuthentication","versions":[1]},"# : ""
            json = #"{"subsonic-response":{"status":"ok","version":"1.16.1","openSubsonicExtensions":["# + offer + #"{"name":"formPost","versions":[1]}]}}"#
        } else if names.contains("apiKey") {
            if names.contains("t") {
                json = Self.failure(41, "Token-based authentication not supported")
            } else if names.contains("u") {
                json = Self.failure(43, "Multiple conflicting authentication mechanisms provided")
            } else if items.first(where: { $0.name == "apiKey" })?.value != key {
                json = Self.failure(44, "Invalid API key")
            } else {
                json = #"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#
            }
        } else if names.contains("t") {
            json = Self.failure(41, "Token-based authentication not supported")
        } else {
            json = Self.failure(10, "User authentication required")
        }
        let body = Data(json.utf8)
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func failure(_ code: Int, _ message: String) -> String {
        #"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":"# + "\(code)" + #","message":""# + message + #""}}}"#
    }
}
#endif
