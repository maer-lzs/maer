// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Network
import os
import Testing
@testable import Maer

/// Sign-in to Jellyfin without a password: Mär shows a code, the person
/// approves it in a Jellyfin session where they are signed in, and Mär
/// trades the code's secret for a token. The answers are the ones the
/// server gives (`/QuickConnect/Enabled`, `/Initiate`, `/Connect`,
/// `/Users/AuthenticateWithQuickConnect`); a loopback answers in that form.
@MainActor
@Suite(.serialized)
struct JellyfinQuickConnectTests {
    @Test("one look at the code: approved, still waiting, gone, or a failure of the server")
    func answers() {
        #expect(JellyfinQuickConnect.answer(status: 200, authenticated: true) == .approved)
        #expect(JellyfinQuickConnect.answer(status: 200, authenticated: false) == .waiting)
        #expect(JellyfinQuickConnect.answer(status: 200, authenticated: nil) == .failed(status: 200), "an answer without its field")
        #expect(JellyfinQuickConnect.answer(status: 404, authenticated: nil) == .gone, "an expired or unknown code")
        #expect(JellyfinQuickConnect.answer(status: 401, authenticated: nil) == .failed(status: 401))
        #expect(JellyfinQuickConnect.answer(status: nil, authenticated: nil) == .failed(status: nil))
    }

    @Test("the server offers Quick Connect only when it answers true")
    func offered() {
        #expect(JellyfinQuickConnect.offered(status: 200, body: Data("true".utf8)))
        #expect(!JellyfinQuickConnect.offered(status: 200, body: Data("false".utf8)))
        #expect(!JellyfinQuickConnect.offered(status: 200, body: Data("<html>".utf8)))
        #expect(!JellyfinQuickConnect.offered(status: 404, body: Data("true".utf8)))
        #expect(!JellyfinQuickConnect.offered(status: nil, body: Data()))
    }

    /// Drives the flow with answers in turn; counts the waits and the finishes.
    private final class Script {
        var answers: [JellyfinQuickConnect.Answer]
        var finishes = 0
        var waits = 0
        var finishSays: String?
        var cancelAtWait: Int?
        init(_ answers: [JellyfinQuickConnect.Answer]) { self.answers = answers }

        func run() async -> JellyfinQuickConnect.Outcome {
            await JellyfinQuickConnect.run(
                look: { self.answers.isEmpty ? .gone : self.answers.removeFirst() },
                finish: { self.finishes += 1; return self.finishSays },
                wait: {
                    self.waits += 1
                    if self.waits == self.cancelAtWait { throw CancellationError() }
                })
        }
    }

    @Test("the flow looks until the code is approved, then finishes once")
    func approvedAfterWaiting() async {
        let script = Script([.waiting, .waiting, .approved])
        #expect(await script.run() == .signedIn)
        #expect(script.finishes == 1)
        #expect(script.waits == 2)
    }

    @Test("a gone code ends the flow with its sentence and stores nothing")
    func goneCode() async {
        let script = Script([.waiting, .gone])
        let outcome = await script.run()
        #expect(outcome == .gone)
        #expect(outcome.sentence == JellyfinQuickConnect.goneSentence)
        #expect(script.finishes == 0)
    }

    @Test("a cancel while waiting ends the flow without a sentence and stores nothing")
    func cancelledWhileWaiting() async {
        let script = Script([.waiting, .waiting, .approved])
        script.cancelAtWait = 1
        let outcome = await script.run()
        #expect(outcome == .cancelled)
        #expect(outcome.sentence == nil)
        #expect(script.finishes == 0)
    }

    @Test("a failure of the server ends the flow with the client's sentence; a failed finish says its own")
    func failures() async {
        let refused = await Script([.failed(status: 401)]).run()
        #expect(refused.sentence == JellyfinClient.failure(forStatus: 401).errorDescription)
        let script = Script([.approved])
        script.finishSays = "stored nothing"
        #expect(await script.run() == .failed("stored nothing"))
    }

    @Test("the client asks, starts, looks and trades the secret in the server's form, with no password and no token before")
    func clientAgainstTheServer() async throws {
        let server = try await JellyfinLoopback.start(waitingLooks: 1)
        defer { server.stop() }
        let client = JellyfinClient(serverURL: server.address, username: "", password: "", deviceId: "device-qc",
                                    accessToken: nil, userId: nil)
        #expect(await client.quickConnectOffered())
        let start = try await client.quickConnectStart()
        #expect(start.code == JellyfinLoopback.code)
        #expect(await client.quickConnectAnswer(secret: start.secret) == .waiting)
        #expect(await client.quickConnectAnswer(secret: start.secret) == .approved)
        #expect(await client.quickConnectAnswer(secret: "unknown") == .gone)
        let signed = try await client.signIn(quickConnectSecret: start.secret)
        #expect(signed.token == JellyfinLoopback.token)
        #expect(signed.userId == "user-qc")
        #expect(signed.userName == "hoerer")
        let seen = server.requests
        #expect(seen.map(\.path) == ["/QuickConnect/Enabled", "/QuickConnect/Initiate", "/QuickConnect/Connect",
                                     "/QuickConnect/Connect", "/QuickConnect/Connect", "/Users/AuthenticateWithQuickConnect"],
                "\(seen.map(\.path)) \(server.diagnosis)")
        #expect(seen.allSatisfy { $0.authorization?.hasPrefix("MediaBrowser ") == true && $0.authorization?.contains("Token=") == false },
                "a request before the sign-in carries a token or no client header")
        #expect(seen.last?.method == "POST")
        #expect(seen.last?.body.contains("\"Secret\":\"\(start.secret)\"") == true, "the trade does not carry the secret")
        #expect(!seen.contains { $0.body.contains("Pw") }, "a request carries a password field")
    }

    @Test("a server without Quick Connect is not offered")
    func notOffered() async throws {
        let server = try await JellyfinLoopback.start(enabled: false)
        defer { server.stop() }
        let client = JellyfinClient(serverURL: server.address, username: "", password: "", deviceId: "device-qc",
                                    accessToken: nil, userId: nil)
        #expect(!(await client.quickConnectOffered()))
    }

    @Test("a token without a password: the check asks the server with the token, and a refused token asks to sign in again")
    func tokenWithoutPassword() async throws {
        let server = try await JellyfinLoopback.start()
        defer { server.stop() }
        let held = JellyfinClient(serverURL: server.address, username: "hoerer", password: "", deviceId: "device-qc",
                                  accessToken: JellyfinLoopback.token, userId: "user-qc")
        #expect(await held.testConnection() == nil, "\(server.requests.map(\.path)) \(server.diagnosis)")
        #expect(server.requests.last?.path == "/Users/Me")
        let refused = JellyfinClient(serverURL: server.address, username: "hoerer", password: "", deviceId: "device-qc",
                                     accessToken: "token-revoked", userId: "user-qc")
        #expect(await refused.testConnection() == JellyfinClient.JellyfinError.signInAgain.errorDescription)
    }

    /// What a Quick Connect sign-in writes outside the client, put back after the witness.
    struct Stand {
        let url = AppStorageKeys.jellyfinServerURLValue
        let user = AppStorageKeys.jellyfinUsernameValue
        let password = AppStorageKeys.jellyfinPasswordValue
        let token = AppStorageKeys.jellyfinTokenValue
        let userId = AppStorageKeys.jellyfinUserIdValue
        let enabled = AppStorageKeys.jellyfinEnabledValue
        func restore() {
            AppStorageKeys.jellyfinEnabledValue = enabled
            AppStorageKeys.jellyfinServerURLValue = url
            AppStorageKeys.jellyfinUsernameValue = user
            AppStorageKeys.setJellyfinPassword(password)
            AppStorageKeys.setJellyfinToken(token)
            AppStorageKeys.jellyfinUserIdValue = userId
            JellyfinProvider.shared.reloadConfig()
        }
    }

    @Test("an approved sign-in keeps the address, the server's user name, the token in the keychain and the user id; the password of another account goes")
    func signedInIsStored() async throws {
        let stand = Stand()
        defer { stand.restore() }
        let server = try await JellyfinLoopback.start()
        defer { server.stop() }
        AppStorageKeys.jellyfinEnabledValue = false
        AppStorageKeys.jellyfinServerURLValue = "https://jf.other.example"
        AppStorageKeys.jellyfinUsernameValue = "someone-else"
        AppStorageKeys.setJellyfinPassword("passwort-des-anderen")
        AppStorageKeys.setJellyfinToken("")
        let client = JellyfinProvider.quickConnectClient(address: server.address)
        let start = try await client.quickConnectStart()
        _ = await client.quickConnectAnswer(secret: start.secret)
        let failure = await JellyfinProvider.finishQuickConnect(client: client, secret: start.secret) { user in
            JellyfinSourceView.keep(serverURL: server.address, username: user, password: "")
        }
        #expect(failure == nil, "\(failure ?? "")")
        #expect(AppStorageKeys.jellyfinServerURLValue == server.address)
        #expect(AppStorageKeys.jellyfinUsernameValue == "hoerer")
        #expect(KeychainStore.load(forKey: KeychainKey.jellyfinToken) == JellyfinLoopback.token)
        #expect(AppStorageKeys.jellyfinUserIdValue == "user-qc")
        #expect(AppStorageKeys.jellyfinPasswordValue.isEmpty, "the password of another account stays")
        let defaults = UserDefaults.standard.dictionaryRepresentation().values.compactMap { $0 as? String }
        #expect(!defaults.contains(JellyfinLoopback.token), "the token lies in the settings")
    }

    @Test("Fence: the page offers Quick Connect only after the server said so, and the sentences have their German words", .needsTheSources)
    func pageAndCatalog() throws {
        let page = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/JellyfinSourceView.swift"), encoding: .utf8))
        #expect(page.contains("if quickConnectOffered"), "the button shows without the server's answer")
        #expect(page.contains("JellyfinQuickConnect.run("), "the page runs a flow of its own")
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        for key in ["Sign in with Quick Connect",
                    "In Jellyfin, where you are signed in, open Quick Connect and enter this code.",
                    "The code is no longer valid. Start Quick Connect again.",
                    "This Jellyfin sign-in is no longer valid. Sign in again."] {
            let entry = strings[key] as? [String: Any]
            let german = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect((german?["value"] as? String)?.isEmpty == false, "\(key) has no German words")
        }
    }
}

/// A Jellyfin server on the loopback in the form the Quick Connect answers
/// take on a real one: `Enabled` as a bare boolean, `Initiate` and
/// `Connect` with `Secret`, `Code` and `Authenticated`, a 404 for a secret
/// it does not know, and the trade answered like a sign-in.
/// Unchecked because one lock guards the recorded requests and the looks.
nonisolated final class JellyfinLoopback: @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let authorization: String?
        let body: String
    }

    static let secret = "secret-qc"
    static let code = "123456"
    static let token = "token-qc"

    private let listener: NWListener
    private let lock = NSLock()
    private var seen: [Seen] = []
    private var looks = 0
    private var events: [String] = []
    private let enabled: Bool
    private let waitingLooks: Int
    private(set) var port: UInt16 = 0

    var requests: [Seen] { lock.withLock { seen } }
    var address: String { "http://127.0.0.1:\(port)" }
    var diagnosis: String { lock.withLock { "requests=\(seen.count) events=\(events)" } }

    private init(enabled: Bool, waitingLooks: Int) throws {
        self.enabled = enabled
        self.waitingLooks = waitingLooks
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(enabled: Bool = true, waitingLooks: Int = 0) async throws -> JellyfinLoopback {
        let server = try JellyfinLoopback(enabled: enabled, waitingLooks: waitingLooks)
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
        receive(connection, buffer: Data())
    }

    /// Reads the head, then as many body bytes as `Content-Length` says.
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    answer(connection, head: head, body: String(decoding: body.prefix(length), as: UTF8.self))
                    return
                }
            }
            if !done, error == nil {
                receive(connection, buffer: buffer)
            } else {
                lock.withLock { events.append("closed early: bytes=\(buffer.count)") }
                connection.cancel()
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String, body: String) {
        let lines = head.split(separator: "\r\n").map(String.init)
        let parts = (lines.first ?? "").split(separator: " ").map(String.init)
        let method = parts.first ?? ""
        let comps = URLComponents(string: parts.count > 1 ? parts[1] : "/")
        let path = comps?.path ?? "/"
        let authorization = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        lock.withLock { seen.append(Seen(method: method, path: path, authorization: authorization, body: body)) }
        let secret = comps?.queryItems?.first { $0.name == "secret" }?.value
        let (status, json): (Int, String)
        switch (method, path) {
        case ("GET", "/QuickConnect/Enabled"):
            (status, json) = (200, enabled ? "true" : "false")
        case ("POST", "/QuickConnect/Initiate"):
            (status, json) = (200, Self.state(authenticated: false))
        case ("GET", "/QuickConnect/Connect"):
            guard secret == Self.secret else { (status, json) = (404, "<html>Not Found</html>"); break }
            let look = lock.withLock { looks += 1; return looks }
            (status, json) = (200, Self.state(authenticated: look > waitingLooks))
        case ("POST", "/Users/AuthenticateWithQuickConnect"):
            (status, json) = body.contains(Self.secret)
                ? (200, #"{"AccessToken":"\#(Self.token)","ServerId":"server-qc","User":{"Id":"user-qc","Name":"hoerer"}}"#)
                : (404, "<html>Not Found</html>")
        case ("GET", "/Users/Me"):
            (status, json) = authorization?.contains("Token=\"\(Self.token)\"") == true
                ? (200, #"{"Id":"user-qc","Name":"hoerer"}"#)
                : (401, "")
        default:
            (status, json) = (404, "")
        }
        let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func state(authenticated: Bool) -> String {
        #"{"Authenticated":\#(authenticated),"Secret":"\#(secret)","Code":"\#(code)","DeviceId":"device-qc","AppName":"Maer"}"#
    }
}
#endif
