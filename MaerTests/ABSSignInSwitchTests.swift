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

/// A sign-in to an Audiobookshelf server runs on a fresh client: the
/// request to a new address carries no token of the server signed in
/// before, a failed sign-in leaves the shared client as it was, and only a
/// sign-in that worked hands it address and token. Through the real
/// `connect()` against a loopback server that writes down what it was sent.
@MainActor
@Suite(.serialized)
struct ABSSignInSwitchTests {
    /// Everything a sign-in writes outside the client, put back after the
    /// witness.
    struct Stand {
        let url = KeychainStore.load(forKey: KeychainKey.serverURL)
        let token = KeychainStore.load(forKey: KeychainKey.apiToken)
        let signedIn = AppStorageKeys.string(AppStorageKeys.absSignedInServer)
        let signedInUser = AppStorageKeys.string(AppStorageKeys.absSignedInUser)
        let switchedAt = UserDefaults.standard.object(forKey: AppStorageKeys.absServerSwitchedAt)
        let moreThanOne = UserDefaults.standard.object(forKey: AppStorageKeys.absMoreThanOneServer)
        let known = UserDefaults.standard.data(forKey: KnownServers.storeKey)
        func restore() {
            if let url { KeychainStore.save(url, forKey: KeychainKey.serverURL) } else { KeychainStore.delete(forKey: KeychainKey.serverURL) }
            if let token { KeychainStore.save(token, forKey: KeychainKey.apiToken) } else { KeychainStore.delete(forKey: KeychainKey.apiToken) }
            AppStorageKeys.set(signedIn, for: AppStorageKeys.absSignedInServer)
            AppStorageKeys.set(signedInUser, for: AppStorageKeys.absSignedInUser)
            UserDefaults.standard.set(switchedAt, forKey: AppStorageKeys.absServerSwitchedAt)
            UserDefaults.standard.set(moreThanOne, forKey: AppStorageKeys.absMoreThanOneServer)
            UserDefaults.standard.set(known, forKey: KnownServers.storeKey)
        }
    }

    /// Signed in to A: the shared client holds A's address and token.
    private func signedInToA(_ address: String = "https://abs.a.example") -> AuthViewModel {
        AuthViewModel(read: { key in
            switch key {
            case KeychainKey.serverURL: return .value(address)
            case KeychainKey.apiToken: return .value("token-of-a")
            default: return .missing
            }
        })
    }

    @Test("die Anmelde-Anfrage an eine neue Adresse traegt keinen Bearer von A")
    func theSignInToANewAddressCarriesNoTokenOfA() async throws {
        let stand = Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .accept("token-of-b"), libraries: .accept)
        defer { server.stop() }
        let auth = signedInToA()
        auth.serverURLString = server.address
        auth.loginMode = .password
        auth.username = "hoerer"
        auth.password = "passwort-fuer-b"
        await auth.connect()
        let seen = server.requests
        #expect(seen.map(\.path) == ["/login", "/api/libraries", "/api/me"], "\(seen.map(\.path)) \(server.diagnosis)")
        #expect(seen.first?.authorization == nil, "the sign-in to B carried: \(String(describing: seen.first?.authorization))")
        #expect(!seen.contains { $0.authorization?.contains("token-of-a") == true }, "a request to B carried the token of A")
    }

    @Test("eine gescheiterte Anmeldung laesst den geteilten Client auf A mit dem Token von A, mit Passwort und mit Token")
    func aFailedSignInLeavesTheSharedClient() async throws {
        let stand = Stand()
        defer { stand.restore() }
        let refusing = try await ABSLoopback.start(login: .refuse, libraries: .refuse)
        defer { refusing.stop() }
        for mode in [AuthViewModel.LoginMode.password, .token] {
            let auth = signedInToA()
            auth.serverURLString = refusing.address
            auth.loginMode = mode
            auth.username = "hoerer"
            auth.password = "falsch"
            auth.apiToken = "token-typed-for-b"
            await auth.connect()
            #expect(auth.errorMessage != nil, "\(mode): the precondition: the sign-in failed")
            #expect(auth.apiClient.baseURL.absoluteString == "https://abs.a.example",
                    "\(mode): the shared client points at \(auth.apiClient.baseURL)")
            #expect(auth.apiClient.token == "token-of-a", "\(mode): the shared client holds another token")
        }
    }

    @Test("eine gelungene Anmeldung gibt dem geteilten Client die Adresse und den Token von B")
    func aSignInThatWorkedHandsOverBoth() async throws {
        let stand = Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .accept("token-of-b"), libraries: .accept)
        defer { server.stop() }
        let auth = signedInToA()
        auth.serverURLString = server.address
        auth.loginMode = .password
        auth.username = "hoerer"
        auth.password = "passwort-fuer-b"
        await auth.connect()
        #expect(auth.errorMessage == nil, "\(String(describing: auth.errorMessage)) \(server.diagnosis)")
        #expect(auth.apiClient.baseURL.absoluteString == server.address)
        #expect(auth.apiClient.token == "token-of-b")
        #expect(KeychainStore.load(forKey: KeychainKey.apiToken) == "token-of-b")
    }

    /// A sign-in to another server forgets the former server's titles in
    /// the widget, its rows and its snapshot, and from iOS 27 its books in
    /// the device's search, as a sign out does; a sign-in again to the same
    /// server keeps them. The widget's files and the index are put back
    /// after the witness.
    @Test("eine Anmeldung an einem anderen Server vergisst die Titel des Widgets und die Buecher der Suche, eine erneute an demselben nicht")
    func aSignInToAnotherServerForgetsTheWidgetsTitles() async throws {
        let recorder = SpotlightRecorder()
        var restoreIndex: () -> Void = {}
        if #available(iOS 27, *) {
            let kept = SpotlightIndex.index
            SpotlightIndex.index = recorder.index()
            restoreIndex = { SpotlightIndex.index = kept }
        }
        defer { restoreIndex() }
        let stand = Stand()
        defer { stand.restore() }
        let snapshotURL = try #require(WidgetSnapshot.snapshotURL)
        let rowsURL = try #require(ContinueRows.url)
        let keptSnapshot = try? Data(contentsOf: snapshotURL)
        let keptRows = try? Data(contentsOf: rowsURL)
        defer {
            for (url, data) in [(snapshotURL, keptSnapshot), (rowsURL, keptRows)] {
                if let data { try? data.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
            }
        }
        let server = try await ABSLoopback.start(login: .accept("token-new"), libraries: .accept, userId: "user-b")
        defer { server.stop() }
        let sameServer = server.address.replacingOccurrences(of: "http://", with: "https://")
        // Another server; the same server again; the same server with
        // another user, which is another account.
        for (stored, storedUser, forgets) in [("https://abs.a.example", nil, true), (sameServer, nil, false),
                                              (sameServer, "user-a", true)] as [(String, String?, Bool)] {
            AppStorageKeys.set(storedUser, for: AppStorageKeys.absSignedInUser)
            WidgetSnapshot(itemId: "li_former", title: "Titel", author: nil, fraction: 0.5, remainingText: nil, isPlaying: false).save()
            let former = WidgetSourceRow(source: .audiobooks, itemId: "li_former", title: "Titel", subtitle: nil, fraction: 0.5,
                                         remainingText: nil, isLive: false, kindSymbol: "book", cover: nil, playedAt: 1)
            #expect(ContinueRows(rows: [former], passAtMs: 1).save(), "\(stored): the precondition, a row of the former server")
            recorder.calls = []
            let auth = signedInToA(stored)
            auth.serverURLString = server.address
            auth.loginMode = .password
            auth.username = "hoerer"
            auth.password = "passwort"
            await auth.connect()
            #expect(auth.errorMessage == nil, "\(stored): \(String(describing: auth.errorMessage)) \(server.diagnosis)")
            #expect((WidgetSnapshot.load() == nil) == forgets, "\(stored): the title of the former server")
            #expect(AppStorageKeys.string(AppStorageKeys.absSignedInUser) == "user-b", "the signed-in user is not noted")
            let rows = ContinueRows.load()?.rows.map(\.itemId)
            #expect(rows == (forgets ? [] : ["li_former"]), "\(stored): the widget's rows \(String(describing: rows))")
            if #available(iOS 27, *) {
                #expect(recorder.calls == (forgets ? ["remove"] : []), "\(stored): the books in the search \(recorder.calls)")
            }
        }
    }

    /// One place forgets what a server leaves on the device; the sign out
    /// and the switch both call it, the switch before the sources change.
    @Test("der alte Server wird an einer Stelle vergessen, von der Abmeldung und vom Wechsel, beim Wechsel vor dem Anstoss der Quellen", .needsTheSources)
    func theFormerServerIsForgottenInOnePlace() throws {
        let auth = try FetchAnswerTests.squeezedSource("Sources/ViewModels/AuthViewModel.swift")
        #expect(auth.contains("static func forgetFormerServer(player: PlayerCoordinator? = nil) async { await ServerLeaving.forget(ItemNamespace.isAudiobookshelf, covers: .audiobookshelf, allRows: true, player: player) if #available(iOS 27, *) { await SpotlightIndex.forget() } }"),
                "the one place does not let the server leave the device, or forgets not the search")
        for forget in ["ServerLeaving.forget(", "SpotlightIndex.forget("] {
            #expect(auth.components(separatedBy: forget).count == 2, "\(forget) is called past the one place")
        }
        #expect(auth.contains("AppSession.shared.notifySourcesChanged() Task { await Self.forgetFormerServer() } }"),
                "the sign out does not forget the former server")
        #expect(auth.contains("if switched { await Self.forgetFormerServer() } if switched, !serverSwitched { await SyncQueue.shared.forgetPending(onServer: formerAddress) } AppSession.shared.notifySourcesChanged() } catch {"),
                "the switch does not forget the former server before the sources change")
    }

    @Test("dieselbe Adresse, nur anderes Schema: die Anmeldung uebernimmt wie bei jeder Adresse erst nach Erfolg")
    func theSameServerSignsInTheSameWay() async throws {
        let stand = Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .accept("token-new"), libraries: .accept)
        defer { server.stop() }
        // Stored with https, typed with http: the same server by the one rule.
        let stored = server.address.replacingOccurrences(of: "http://", with: "https://")
        #expect(!ServerAddressSwitch.isSwitch(from: stored, to: server.address), "the precondition: one server")
        let auth = signedInToA(stored)
        auth.serverURLString = server.address
        auth.loginMode = .password
        auth.username = "hoerer"
        auth.password = "passwort"
        await auth.connect()
        #expect(auth.errorMessage == nil, "\(String(describing: auth.errorMessage))")
        #expect(server.requests.first?.authorization == nil, "the sign-in carried the stored token")
        #expect(auth.apiClient.baseURL.absoluteString == server.address && auth.apiClient.token == "token-new")
    }

    @Test("die Anmeldung laeuft nie ueber den geteilten Client, und Clients entstehen an einer Stelle", .needsTheSources)
    func theSignInNeverRunsOnTheSharedClient() throws {
        let auth = try FetchAnswerTests.squeezedSource("Sources/ViewModels/AuthViewModel.swift")
        #expect(!auth.contains("apiClient.login("), "the sign-in runs on the shared client")
        #expect(auth.contains("let trial = Self.makeClient(baseURL: url, token: nil)"))
        let adopted = try #require(auth.range(of: "apiClient.updateBaseURL(url) apiClient.updateToken(token)"))
        let answered = try #require(auth.range(of: "_ = try await trial.fetchLibraries()"))
        #expect(answered.upperBound <= adopted.lowerBound, "the shared client takes the server before it answered")
        var builders: [String] = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() where file != "APIClient.swift" {
            if FetchAnswerTests.squeezed(text).contains("APIClient(baseURL:") { builders.append(file) }
        }
        #expect(builders == ["AuthViewModel.swift"], "another place builds a client: \(builders)")
    }
}

/// A plain HTTP/1.1 Audiobookshelf stand-in on the loopback: `/login` and
/// `/api/libraries`, one request per connection, each written down with
/// its path and its Authorization header. Unchecked because one lock
/// guards the recorded requests.
nonisolated final class ABSLoopback: @unchecked Sendable {
    /// The answer to `POST /login`. As the server does (`server/Auth.js`),
    /// an accepted sign-in sets the cookie `refresh_token` unless the
    /// request carries `x-return-tokens: true`.
    enum Answer: Sendable {
        case accept(String)
        /// A server that sets the cookie whatever the request asks.
        case acceptSettingTheCookie(String)
        /// A server that restarts: the first sign-in gets 503, the next one
        /// is accepted.
        case acceptAfterUnavailable(String)
        case refuse
    }
    enum Listing: Sendable {
        case accept
        case refuse
    }
    /// The single sign-on as the server runs it, rebuilt from its source
    /// (Audiobookshelf 2.37.2, `server/Auth.js`): the start sets the flow's
    /// cookie and redirects to the provider with the app's state, the
    /// exchange without that cookie is `400 No session`.
    enum SingleSignOn: Sendable {
        /// The exchange answers with the long-lived token.
        case token(String)
        /// The exchange answers only with tokens that expire.
        case expiringOnly
    }
    struct Seen: Sendable {
        let path: String
        let authorization: String?
        var cookie: String? = nil
        var returnTokens: String? = nil
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var seen: [Seen] = []
    private var events: [String] = []
    private var loginsAnswered = 0
    private let login: Answer
    private let libraries: Listing
    /// The user id `api/me` answers with; nil answers without one.
    private let userId: String?
    private let singleSignOn: SingleSignOn?
    private(set) var port: UInt16 = 0

    var requests: [Seen] { lock.withLock { seen } }
    var diagnosis: String { lock.withLock { "requests=\(seen.count) events=\(events)" } }
    var address: String { "http://127.0.0.1:\(port)" }

    private init(login: Answer, libraries: Listing, userId: String?, singleSignOn: SingleSignOn?) throws {
        self.login = login
        self.libraries = libraries
        self.userId = userId
        self.singleSignOn = singleSignOn
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(login: Answer, libraries: Listing, userId: String? = nil,
                      singleSignOn: SingleSignOn? = nil) async throws -> ABSLoopback {
        let server = try ABSLoopback(login: login, libraries: libraries, userId: userId, singleSignOn: singleSignOn)
        server.listener.newConnectionHandler = { [server] connection in
            connection.start(queue: .global())
            server.receiveHead(connection, buffer: Data())
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            server.listener.stateUpdateHandler = { state in
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

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                answer(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if !done, error == nil {
                receiveHead(connection, buffer: buffer)
            } else {
                lock.withLock { events.append("closed before a full head") }
                connection.cancel()
            }
        }
    }

    private func answer(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let authorization = lines.dropFirst().first { $0.lowercased().hasPrefix("authorization:") }
            .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
        let cookie = lines.dropFirst().first { $0.lowercased().hasPrefix("cookie:") }
            .map { String($0.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) }
        let returnTokens = lines.dropFirst().first { $0.lowercased().hasPrefix("x-return-tokens:") }
            .map { String($0.dropFirst("x-return-tokens:".count)).trimmingCharacters(in: .whitespaces) }
        let bare = URLComponents(string: path)?.path ?? path
        lock.withLock {
            seen.append(Seen(path: bare, authorization: authorization, cookie: cookie, returnTokens: returnTokens))
        }
        if let singleSignOn, bare.hasPrefix("/auth/openid") {
            let query = URLComponents(string: path)?.queryItems ?? []
            answerSingleSignOn(connection, path: bare, query: query, cookie: cookie, singleSignOn)
            return
        }
        let renewalCookie = "Set-Cookie: refresh_token=renewal-\(UUID().uuidString); Max-Age=2592000; Path=/; HttpOnly"
        switch (bare, login) {
        case ("/login", .accept(let token)):
            let asked = returnTokens == "true"
            let json = #"{"user":{"token":""# + token + #"","refreshToken":"# + (asked ? #""renewal""# : "null") + "}}"
            send(connection, status: "200 OK",
                 headers: ["Content-Type: application/json"] + (asked ? [] : [renewalCookie]), body: json)
            return
        case ("/login", .acceptSettingTheCookie(let token)):
            send(connection, status: "200 OK", headers: ["Content-Type: application/json", renewalCookie],
                 body: #"{"user":{"token":""# + token + #""}}"#)
            return
        case ("/login", .acceptAfterUnavailable(let token)):
            let first = lock.withLock { () -> Bool in
                loginsAnswered += 1
                return loginsAnswered == 1
            }
            if first {
                send(connection, status: "503 Service Unavailable", headers: [], body: "")
            } else {
                send(connection, status: "200 OK", headers: ["Content-Type: application/json"],
                     body: #"{"user":{"token":""# + token + #""}}"#)
            }
            return
        default:
            break
        }
        let status: String, json: String
        switch (bare, login, libraries) {
        case ("/login", .refuse, _):
            status = "401 Unauthorized"; json = "{}"
        case ("/api/libraries", _, .accept):
            status = "200 OK"; json = #"{"libraries":[]}"#
        case ("/api/me", _, _):
            status = "200 OK"; json = userId.map { #"{"id":""# + $0 + #""}"# } ?? "{}"
        default:
            status = "401 Unauthorized"; json = "{}"
        }
        send(connection, status: status, headers: ["Content-Type: application/json"], body: json)
    }

    /// The two routes of the single sign-on: `/auth/openid` and
    /// `/auth/openid/callback`.
    private func answerSingleSignOn(_ connection: NWConnection, path: String, query: [URLQueryItem],
                                    cookie: String?, _ singleSignOn: SingleSignOn) {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch path {
        case "/auth/openid":
            guard value("redirect_uri") == "audiobookshelf://oauth" else {
                send(connection, status: "400 Bad Request", headers: [], body: "Invalid redirect_uri")
                return
            }
            let state = value("state") ?? ""
            send(connection, status: "302 Found", headers: [
                "Location: https://id.example/authorize?response_type=code&state=\(state)",
                "Set-Cookie: connect.sid=flow-\(UUID().uuidString); Path=/; HttpOnly",
                "Set-Cookie: auth_method=openid-mobile; Max-Age=315360000; Path=/; HttpOnly",
            ], body: "")
        case "/auth/openid/callback":
            guard cookie?.contains("connect.sid=flow-") == true else {
                send(connection, status: "400 Bad Request", headers: [], body: "No session")
                return
            }
            let json = switch singleSignOn {
            case .token(let token): #"{"user":{"id":"u","token":""# + token + #"","accessToken":"short","refreshToken":"long"}}"#
            case .expiringOnly: #"{"user":{"id":"u","accessToken":"short","refreshToken":"long"}}"#
            }
            send(connection, status: "200 OK", headers: ["Content-Type: application/json"], body: json)
        default:
            send(connection, status: "404 Not Found", headers: [], body: "")
        }
    }

    private func send(_ connection: NWConnection, status: String, headers: [String], body text: String) {
        let body = Data(text.utf8)
        let head = (["HTTP/1.1 \(status)"] + headers + ["Content-Length: \(body.count)", "Connection: close"])
            .joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
