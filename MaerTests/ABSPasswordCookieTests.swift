// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The password sign-in to Audiobookshelf leaves no cookie of the server in
/// the store of the app's requests, and the start removes the two cookies a
/// former build left there, and only those. Through the real `connect()`
/// against the loopback stand-in (`ABSLoopback`, its `/login` rebuilt from
/// the server's source, not recorded).
@MainActor
@Suite(.serialized)
struct ABSPasswordCookieTests {
    private func clearShared(_ url: URL) {
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
    }

    private func signIn(at server: ABSLoopback) async -> AuthViewModel {
        let auth = AuthViewModel(read: { _ in .missing })
        auth.serverURLString = server.address
        auth.loginMode = .password
        auth.username = "hoerer"
        auth.password = "passwort"
        await auth.connect()
        return auth
    }

    @Test("Die Anmeldung mit Passwort fragt nach den Tokens und laesst kein Cookie im geteilten Speicher")
    func thePasswordSignInLeavesNoCookie() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .accept("token-pw"), libraries: .accept)
        defer { server.stop() }
        let url = try #require(URL(string: server.address))
        // Cookies belong to the host, not the port.
        clearShared(url)
        #expect((HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty, "the precondition: no cookie of the host")
        let auth = await signIn(at: server)
        #expect(auth.errorMessage == nil, "\(String(describing: auth.errorMessage)) \(server.diagnosis)")
        #expect(server.requests.first?.path == "/login" && server.requests.first?.returnTokens == "true",
                "the sign-in did not ask for its tokens: \(String(describing: server.requests.first))")
        let shared = (HTTPCookieStorage.shared.cookies(for: url) ?? []).map(\.name)
        #expect(!shared.contains("refresh_token"), "the shared store keeps \(shared)")
        let after = server.requests.dropFirst()
        #expect(!after.isEmpty && after.allSatisfy { $0.cookie == nil }, "a later request carried \(after.map(\.cookie))")
    }

    @Test("Ein Server, der das Cookie trotzdem setzt: es endet mit der Anmeldung")
    func aCookieSetAnywayEndsWithTheSignIn() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .acceptSettingTheCookie("token-pw"), libraries: .accept)
        defer { server.stop() }
        let url = try #require(URL(string: server.address))
        clearShared(url)
        let auth = await signIn(at: server)
        #expect(auth.errorMessage == nil, "\(String(describing: auth.errorMessage)) \(server.diagnosis)")
        #expect(auth.apiClient.token == "token-pw")
        let shared = (HTTPCookieStorage.shared.cookies(for: url) ?? []).map(\.name)
        #expect(!shared.contains("refresh_token"), "the shared store keeps \(shared)")
        let after = server.requests.dropFirst()
        #expect(!after.isEmpty && after.allSatisfy { $0.cookie == nil }, "a later request carried \(after.map(\.cookie))")
    }

    @Test("Beim Start gehen nur refresh_token und auth_method am Host des Servers, ein fremdes Cookie bleibt")
    func theStartSweepsOnlyTheTwoCookies() throws {
        let host = "abs-\(UUID().uuidString.lowercased()).example"
        let other = "other-\(UUID().uuidString.lowercased()).example"
        let server = try #require(URL(string: "https://\(host)/"))
        let elsewhere = try #require(URL(string: "https://\(other)/"))
        defer { clearShared(server); clearShared(elsewhere) }
        func cookie(_ name: String, _ domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v",
                                                 .expires: Date(timeIntervalSinceNow: 3600)]))
        }
        for (name, domain) in [("refresh_token", host), ("auth_method", host), ("authelia_session", host),
                               ("refresh_token", other)] {
            HTTPCookieStorage.shared.setCookie(try cookie(name, domain))
        }
        // The precondition: the store holds all four.
        #expect(Set((HTTPCookieStorage.shared.cookies(for: server) ?? []).map(\.name))
                == ["refresh_token", "auth_method", "authelia_session"])
        _ = AuthViewModel(read: { key in key == KeychainKey.serverURL ? .value(server.absoluteString) : .missing })
        #expect((HTTPCookieStorage.shared.cookies(for: server) ?? []).map(\.name) == ["authelia_session"])
        #expect((HTTPCookieStorage.shared.cookies(for: elsewhere) ?? []).map(\.name) == ["refresh_token"])
    }

    @Test("Ein Server, der neu startet und einmal 503 sagt: die Anmeldung mit Passwort fragt nach der Regel noch einmal und meldet an")
    func aRestartingServerIsAskedAgain() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .acceptAfterUnavailable("token-pw"), libraries: .accept)
        defer { server.stop() }
        let auth = await signIn(at: server)
        let logins = server.requests.filter { $0.path == "/login" }
        #expect(logins.count == 2, "the sign-in asked \(logins.count) times \(server.diagnosis)")
        #expect(auth.errorMessage == nil, "\(String(describing: auth.errorMessage))")
        #expect(auth.apiClient.token == "token-pw")
        #expect(logins.allSatisfy { $0.returnTokens == "true" }, "the repeated sign-in lost its question for the tokens")
    }

    @Test("Ein echtes Set-Cookie des Servers im geteilten Speicher, wie es ein frueherer Bau hinterliess: der Start kehrt es")
    func aCookieTheServerSetIsSweptAtTheStart() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .acceptSettingTheCookie("token-old"), libraries: .accept)
        defer { server.stop() }
        let url = try #require(URL(string: server.address))
        clearShared(url)
        defer { clearShared(url) }
        // The way of an earlier build: the sign-in through the request lane
        // of the app, whose store is the shared one.
        var login = URLRequest(url: url.appendingPathComponent("login"))
        login.httpMethod = "POST"
        _ = try await HTTP.data(for: login, lane: .api, retry: false)
        // The precondition: the server's cookie landed in the shared store.
        #expect((HTTPCookieStorage.shared.cookies(for: url) ?? []).map(\.name).contains("refresh_token"),
                "\(server.diagnosis)")
        _ = AuthViewModel(read: { key in key == KeychainKey.serverURL ? .value(server.address) : .missing })
        #expect(!(HTTPCookieStorage.shared.cookies(for: url) ?? []).map(\.name).contains("refresh_token"),
                "the start kept \((HTTPCookieStorage.shared.cookies(for: url) ?? []).map(\.name))")
    }

    /// Answers unreadable until it is opened, as the keychain before the
    /// first unlock.
    private final class Lock {
        var open = false
    }

    @Test("Ist der Schluesselbund beim Start unlesbar, gehen die zwei Cookies, sobald die Adresse nachgelesen ist")
    func theSweepFollowsTheRereadAddress() throws {
        let host = "abs-\(UUID().uuidString.lowercased()).example"
        let server = try #require(URL(string: "https://\(host)/"))
        defer { clearShared(server) }
        for name in ["refresh_token", "auth_method"] {
            HTTPCookieStorage.shared.setCookie(try #require(HTTPCookie(properties: [
                .domain: host, .path: "/", .name: name, .value: "v", .expires: Date(timeIntervalSinceNow: 3600)])))
        }
        let lock = Lock()
        let auth = AuthViewModel(read: { key in
            guard lock.open else { return .unreadable }
            switch key {
            case KeychainKey.serverURL: return .value(server.absoluteString)
            case KeychainKey.apiToken: return .value("token")
            default: return .missing
            }
        })
        // The precondition: the start could not read the address and kept the cookies.
        #expect(auth.accessUnknown)
        #expect(Set((HTTPCookieStorage.shared.cookies(for: server) ?? []).map(\.name)) == ["refresh_token", "auth_method"])
        lock.open = true
        #expect(auth.rereadIfUnknown(), "the access reads as signed in after the unlock")
        #expect((HTTPCookieStorage.shared.cookies(for: server) ?? []).isEmpty,
                "the store keeps \((HTTPCookieStorage.shared.cookies(for: server) ?? []).map(\.name))")
    }

    @Test("Die Regel nimmt nur die zwei Namen und nur den Host selbst")
    func theRuleTakesTheTwoNamesAtTheHost() throws {
        let server = try #require(URL(string: "https://Books.Example.org/abs"))
        func cookie(_ name: String, _ domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v"]))
        }
        let all = [try cookie("refresh_token", "books.example.org"), try cookie("auth_method", "books.example.org"),
                   try cookie("connect.sid", "books.example.org"), try cookie("refresh_token", ".example.org"),
                   try cookie("refresh_token", "example.org")]
        #expect(ABSCookieSweep.doomed(all, server: server).map(\.name) == ["refresh_token", "auth_method"])
    }
}
#endif
