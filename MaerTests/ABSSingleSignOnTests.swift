// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The server's answers below are rebuilt from its source (Audiobookshelf
/// 2.37.2: `server/Auth.js`, `server/auth/OidcAuthStrategy.js`), not
/// recorded from a running server.
struct ABSSingleSignOnTests {
    private let server = URL(string: "https://abs.example/books")!

    private func response(_ url: URL, _ status: Int, location: String? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: location.map { ["Location": $0] })!
    }

    private func query(_ url: URL?, _ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }

    // MARK: PKCE

    @Test("PKCE S256 nach RFC 7636, Anhang B")
    func pkceMatchesTheRFC() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let one = PKCE.randomValue()
        #expect(one.count == 43)
        #expect(one.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(one != PKCE.randomValue())
    }

    // MARK: Start

    @Test("Der Start nennt Challenge, S256, die Rueckkehr der App, code und den Zustand")
    func startAddress() throws {
        let start = try #require(ABSSSO.startURL(server: server, challenge: "ch", state: "st"))
        #expect(start.path == "/books/auth/openid")
        #expect(query(start, "code_challenge") == "ch")
        #expect(query(start, "code_challenge_method") == "S256")
        #expect(query(start, "redirect_uri") == "audiobookshelf://oauth")
        #expect(query(start, "response_type") == "code")
        #expect(query(start, "state") == "st")
    }

    @Test("Die Seite des Anbieters kommt als Weiterleitung auf https")
    func providerPageOnHTTPS() throws {
        let page = try ABSSSO.providerPage(status: 302, location: "https://id.example/authorize?state=st", body: Data())
        #expect(page.host == "id.example")
    }

    @Test("Ein Anbieter ohne https bricht vor dem Fenster ab")
    func providerWithoutHTTPS() {
        #expect(throws: ABSSSO.Failure.providerNotSecure) {
            try ABSSSO.providerPage(status: 302, location: "http://id.example/authorize", body: Data())
        }
    }

    @Test("Invalid redirect_uri: der Server laesst die Rueckkehr der App nicht zu")
    func returnAddressRefused() {
        #expect(throws: ABSSSO.Failure.returnAddressRefused) {
            try ABSSSO.providerPage(status: 400, location: nil, body: Data("Invalid redirect_uri".utf8))
        }
        #expect(throws: ABSSSO.Failure.startUnanswered(status: 400)) {
            try ABSSSO.providerPage(status: 400, location: nil, body: Data("code_challenge required for mobile flow (PKCE)".utf8))
        }
        #expect(throws: ABSSSO.Failure.startUnanswered(status: 302)) {
            try ABSSSO.providerPage(status: 302, location: nil, body: Data())
        }
        #expect(throws: ABSSSO.Failure.startUnanswered(status: 200)) {
            try ABSSSO.providerPage(status: 200, location: nil, body: Data("<html>".utf8))
        }
    }

    // MARK: Return

    @Test("Die Rueckkehr traegt den Code nur mit dem Zustand dieses Ablaufs")
    func returnCarriesTheCode() throws {
        let back = try #require(URL(string: "audiobookshelf://oauth?code=c0de&state=st"))
        #expect(try ABSSSO.code(fromReturn: back, state: "st") == "c0de")
        #expect(throws: ABSSSO.Failure.foreignState) { try ABSSSO.code(fromReturn: back, state: "other") }
        #expect(throws: ABSSSO.Failure.noCode) {
            try ABSSSO.code(fromReturn: URL(string: "audiobookshelf://oauth?state=st")!, state: "st")
        }
        #expect(throws: ABSSSO.Failure.noCode) {
            try ABSSSO.code(fromReturn: URL(string: "maer://oauth?code=c0de&state=st")!, state: "st")
        }
        #expect(throws: ABSSSO.Failure.refusedBySignIn("access_denied")) {
            try ABSSSO.code(fromReturn: URL(string: "audiobookshelf://oauth?error=access_denied&state=st")!, state: "st")
        }
    }

    // MARK: Exchange

    @Test("Der Tausch nimmt das langlebige token")
    func exchangeTakesTheLongLivedToken() throws {
        let body = Data(#"{"user":{"id":"u1","token":"legacy","accessToken":"short","refreshToken":"long"},"userDefaultLibraryId":"l1"}"#.utf8)
        #expect(try ABSSSO.token(status: 200, location: nil, body: body) == "legacy")
    }

    @Test("Ohne token meldet der Tausch nicht an: der Server braucht die Erneuerung")
    func exchangeWithoutTokenSignsNobodyIn() {
        let body = Data(#"{"user":{"id":"u1","accessToken":"short","refreshToken":"long"}}"#.utf8)
        #expect(throws: ABSSSO.Failure.needsRenewal) { try ABSSSO.token(status: 200, location: nil, body: body) }
        #expect(throws: ABSSSO.Failure.exchangeUnanswered(status: 200)) {
            try ABSSSO.token(status: 200, location: nil, body: Data(#"{"user":{"id":"u1"}}"#.utf8))
        }
        #expect(throws: ABSSSO.Failure.exchangeUnanswered(status: 200)) {
            try ABSSSO.token(status: 200, location: nil, body: Data("<html>".utf8))
        }
    }

    @Test("No session: der Server kennt den Ablauf nicht mehr")
    func exchangeWithoutTheFlowCookie() {
        #expect(throws: ABSSSO.Failure.flowUnknown) {
            try ABSSSO.token(status: 400, location: nil, body: Data("No session".utf8))
        }
    }

    @Test("Ein Fehler im Tausch kommt als Weiterleitung zur Anmeldeseite mit Grund")
    func exchangeFailureAsRedirect() {
        #expect(throws: ABSSSO.Failure.refusedBySignIn("Unauthorized")) {
            try ABSSSO.token(status: 302, location: "/login?error=Unauthorized&autoLaunch=0", body: Data())
        }
        #expect(throws: ABSSSO.Failure.exchangeUnanswered(status: 500)) {
            try ABSSSO.token(status: 500, location: nil, body: Data())
        }
    }

    // MARK: The whole flow

    private actor Requests {
        var urls: [URL] = []
        func add(_ url: URL) { urls.append(url) }
    }

    private struct FakeWindow: SignInWindow {
        let answer: (URL) -> URL
        func signIn(at page: URL, returnScheme: String) async throws -> URL {
            #expect(returnScheme == "audiobookshelf")
            return answer(page)
        }
    }

    private func flow(window: FakeWindow, requests: Requests, exchange: Data) -> ABSSSOFlow {
        let start = response(server, 302, location: "https://id.example/authorize")
        let done = response(server, 200)
        var values = ["verifier-value", "state-value"]
        return ABSSSOFlow(fetch: { request in
            await requests.add(request.url!)
            return request.url!.path.hasSuffix("/callback") ? (exchange, done) : (Data(), start)
        }, window: window, randomValue: { values.removeFirst() })
    }

    @Test("Der ganze Ablauf: Start, Fenster, Tausch mit dem Verifier zur Challenge")
    func wholeFlow() async throws {
        let requests = Requests()
        let window = FakeWindow { _ in URL(string: "audiobookshelf://oauth?code=c0de&state=state-value")! }
        let body = Data(#"{"user":{"token":"legacy","accessToken":"short"}}"#.utf8)
        let token = try await flow(window: window, requests: requests, exchange: body).run(server: server)
        #expect(token == "legacy")
        let urls = await requests.urls
        #expect(urls.count == 2)
        let challenge = query(urls.first, "code_challenge")
        let verifier = query(urls.last, "code_verifier")
        #expect(verifier.map(PKCE.challenge(for:)) == challenge)
        #expect(query(urls.last, "code") == "c0de")
        #expect(query(urls.last, "state") == query(urls.first, "state"))
    }

    @Test("Ein fremder Zustand meldet niemanden an, der Tausch wird nicht gefragt")
    func foreignReturnExchangesNothing() async {
        let requests = Requests()
        let window = FakeWindow { _ in URL(string: "audiobookshelf://oauth?code=c0de&state=another-flow")! }
        await #expect(throws: ABSSSO.Failure.foreignState) {
            try await flow(window: window, requests: requests, exchange: Data()).run(server: self.server)
        }
        #expect(await requests.urls.count == 1)
    }
}
#endif
