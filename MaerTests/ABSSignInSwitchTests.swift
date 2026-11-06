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
    private struct Stand {
        let url = KeychainStore.load(forKey: KeychainKey.serverURL)
        let token = KeychainStore.load(forKey: KeychainKey.apiToken)
        let signedIn = AppStorageKeys.string(AppStorageKeys.absSignedInServer)
        let switchedAt = UserDefaults.standard.object(forKey: AppStorageKeys.absServerSwitchedAt)
        let moreThanOne = UserDefaults.standard.object(forKey: AppStorageKeys.absMoreThanOneServer)
        let known = UserDefaults.standard.data(forKey: KnownServers.storeKey)
        func restore() {
            if let url { KeychainStore.save(url, forKey: KeychainKey.serverURL) } else { KeychainStore.delete(forKey: KeychainKey.serverURL) }
            if let token { KeychainStore.save(token, forKey: KeychainKey.apiToken) } else { KeychainStore.delete(forKey: KeychainKey.apiToken) }
            AppStorageKeys.set(signedIn, for: AppStorageKeys.absSignedInServer)
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
        #expect(seen.map(\.path) == ["/login", "/api/libraries"], "\(seen.map(\.path)) \(server.diagnosis)")
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
        let server = try await ABSLoopback.start(login: .accept("token-new"), libraries: .accept)
        defer { server.stop() }
        let sameServer = server.address.replacingOccurrences(of: "http://", with: "https://")
        for (stored, forgets) in [("https://abs.a.example", true), (sameServer, false)] {
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
        #expect(auth.contains("static func forgetFormerServer(player: PlayerCoordinator? = nil) async { await ServerLeaving.forget(ItemNamespace.isAudiobookshelf, allRows: true, player: player) if #available(iOS 27, *) { await SpotlightIndex.forget() } }"),
                "the one place does not let the server leave the device, or forgets not the search")
        for forget in ["ServerLeaving.forget(", "SpotlightIndex.forget("] {
            #expect(auth.components(separatedBy: forget).count == 2, "\(forget) is called past the one place")
        }
        #expect(auth.contains("AppSession.shared.notifySourcesChanged() Task { await Self.forgetFormerServer() } }"),
                "the sign out does not forget the former server")
        #expect(auth.contains("if switched { await Self.forgetFormerServer() } AppSession.shared.notifySourcesChanged() } catch {"),
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
    enum Answer: Sendable {
        case accept(String)
        case refuse
    }
    enum Listing: Sendable {
        case accept
        case refuse
    }
    struct Seen: Sendable {
        let path: String
        let authorization: String?
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var seen: [Seen] = []
    private var events: [String] = []
    private let login: Answer
    private let libraries: Listing
    private(set) var port: UInt16 = 0

    var requests: [Seen] { lock.withLock { seen } }
    var diagnosis: String { lock.withLock { "requests=\(seen.count) events=\(events)" } }
    var address: String { "http://127.0.0.1:\(port)" }

    private init(login: Answer, libraries: Listing) throws {
        self.login = login
        self.libraries = libraries
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(login: Answer, libraries: Listing) async throws -> ABSLoopback {
        let server = try ABSLoopback(login: login, libraries: libraries)
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
        let bare = URLComponents(string: path)?.path ?? path
        lock.withLock { seen.append(Seen(path: bare, authorization: authorization)) }
        let status: String, json: String
        switch (bare, login, libraries) {
        case ("/login", .accept(let token), _):
            status = "200 OK"; json = #"{"user":{"token":""# + token + #""}}"#
        case ("/login", .refuse, _):
            status = "401 Unauthorized"; json = "{}"
        case ("/api/libraries", _, .accept):
            status = "200 OK"; json = #"{"libraries":[]}"#
        default:
            status = "401 Unauthorized"; json = "{}"
        }
        let body = Data(json.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
