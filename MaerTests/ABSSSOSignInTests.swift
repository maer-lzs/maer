// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The single sign-on through the real `connectWithSSO()` and the flow
/// session against the loopback stand-in (`ABSLoopback`, its routes
/// rebuilt from the server's source, not recorded). The provider's page is
/// a window that comes back at once with the state the page carried.
@MainActor
@Suite(.serialized)
struct ABSSSOSignInTests {
    /// Comes back from the provider's page with a code and the page's state.
    private struct ReturningWindow: SignInWindow {
        var state: (URL) -> String? = { page in
            URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        }
        func signIn(at page: URL, returnScheme: String) async throws -> URL {
            URL(string: "\(returnScheme)://oauth?code=c0de&state=\(state(page) ?? "")")!
        }
    }

    private func signedIn(to address: String) -> AuthViewModel {
        AuthViewModel(read: { key in
            switch key {
            case KeychainKey.serverURL: return .value(address)
            case KeychainKey.apiToken: return .value("token-of-a")
            default: return .missing
            }
        })
    }

    @Test("SSO meldet ueber den Ablauf an: Start, Tausch mit dem Cookie des Starts, dann derselbe Schluss wie mit Passwort")
    func ssoSignsInThroughTheFlow() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .refuse, libraries: .accept, singleSignOn: .token("token-sso"))
        defer { server.stop() }
        let auth = signedIn(to: "https://abs.a.example")
        auth.serverURLString = server.address
        await auth.connectWithSSO(window: ReturningWindow())
        let seen = server.requests
        #expect(seen.map(\.path) == ["/auth/openid", "/auth/openid/callback", "/api/libraries", "/api/me"],
                "\(seen.map(\.path)) \(server.diagnosis)")
        #expect(seen.first?.authorization == nil && seen.first?.cookie == nil, "the start carried a token or a cookie")
        #expect(seen.dropFirst().first?.cookie?.contains("connect.sid=flow-") == true, "the exchange lost the cookie of the start")
        #expect(auth.errorMessage == nil, "\(String(describing: auth.errorMessage))")
        #expect(auth.apiClient.baseURL.absoluteString == server.address && auth.apiClient.token == "token-sso")
        #expect(KeychainStore.load(forKey: KeychainKey.apiToken) == "token-sso")
    }

    @Test("Nach dem Ablauf haelt der geteilte Speicher kein Cookie des Servers, und spaetere Anfragen tragen keins")
    func theFlowLeavesNoCookieBehind() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .refuse, libraries: .accept, singleSignOn: .token("token-sso"))
        defer { server.stop() }
        let auth = signedIn(to: "https://abs.a.example")
        auth.serverURLString = server.address
        await auth.connectWithSSO(window: ReturningWindow())
        // The precondition: the server set its cookies and the flow carried them.
        #expect(server.requests.dropFirst().first?.cookie?.contains("connect.sid=") == true, "\(server.diagnosis)")
        let url = try #require(URL(string: server.address))
        let shared = (HTTPCookieStorage.shared.cookies(for: url) ?? []).map(\.name)
        #expect(!shared.contains("connect.sid") && !shared.contains("auth_method"), "the shared store keeps \(shared)")
        let after = server.requests.dropFirst(2)
        #expect(!after.isEmpty && after.allSatisfy { $0.cookie == nil }, "a later request carried \(after.map(\.cookie))")
    }

    @Test("Ohne token meldet SSO nicht an und sagt, dass der Server die Erneuerung braucht")
    func noLongLivedTokenNoSignIn() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .refuse, libraries: .accept, singleSignOn: .expiringOnly)
        defer { server.stop() }
        let auth = signedIn(to: "https://abs.a.example")
        auth.serverURLString = server.address
        await auth.connectWithSSO(window: ReturningWindow())
        #expect(server.requests.map(\.path) == ["/auth/openid", "/auth/openid/callback"], "\(server.diagnosis)")
        #expect(auth.errorMessage == AuthViewModel.sentence(for: .needsRenewal))
        #expect(auth.apiClient.baseURL.absoluteString == "https://abs.a.example" && auth.apiClient.token == "token-of-a")
    }

    @Test("Ein fremder Zustand in der Rueckkehr meldet nicht an und fragt den Tausch nicht")
    func aForeignReturnSignsNobodyIn() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let server = try await ABSLoopback.start(login: .refuse, libraries: .accept, singleSignOn: .token("token-sso"))
        defer { server.stop() }
        let auth = signedIn(to: "https://abs.a.example")
        auth.serverURLString = server.address
        await auth.connectWithSSO(window: ReturningWindow(state: { _ in "another-flow" }))
        #expect(server.requests.map(\.path) == ["/auth/openid"], "\(server.diagnosis)")
        #expect(auth.errorMessage == AuthViewModel.sentence(for: .foreignState))
        #expect(auth.apiClient.token == "token-of-a")
    }

    @Test("Ein Tausch ohne das Cookie des Starts (anderer Ablauf) ergibt den Satz zu No session")
    func anExchangeOfAnotherFlowIsUnknown() async throws {
        let server = try await ABSLoopback.start(login: .refuse, libraries: .accept, singleSignOn: .token("token-sso"))
        defer { server.stop() }
        let started = HTTP.SignInFlow()
        let other = HTTP.SignInFlow()
        defer { started.close(); other.close() }
        let flow = ABSSSOFlow(fetch: { request in
            try await (request.url?.path.hasSuffix("/callback") == true ? other : started).data(for: request)
        }, window: ReturningWindow())
        let url = try #require(URL(string: server.address))
        await #expect(throws: ABSSSO.Failure.flowUnknown) { try await flow.run(server: url) }
        #expect(server.requests.map(\.path) == ["/auth/openid", "/auth/openid/callback"], "\(server.diagnosis)")
        #expect(server.requests.last?.cookie == nil)
        #expect(!AuthViewModel.sentence(for: .flowUnknown).isEmpty)
    }

    @Test("Der Server laesst die Rueckkehr nicht zu: Satz, keine Anmeldung")
    func aRefusedReturnAddressIsSaid() async throws {
        let server = try await ABSLoopback.start(login: .refuse, libraries: .accept, singleSignOn: .token("token-sso"))
        defer { server.stop() }
        let flow = HTTP.SignInFlow()
        defer { flow.close() }
        var request = URLRequest(url: try #require(URL(string: "\(server.address)/auth/openid?redirect_uri=maer://oauth&response_type=code")))
        request.httpMethod = "GET"
        let (body, response) = try await flow.data(for: request)
        #expect(throws: ABSSSO.Failure.returnAddressRefused) {
            try ABSSSO.providerPage(status: response.statusCode, location: response.value(forHTTPHeaderField: "Location"), body: body)
        }
    }

    @Test("Ein SSO-Token eines anderen Nutzers am selben Server ist ein Kontowechsel")
    func anotherUserBySSOIsAnAccountSwitch() async throws {
        let stand = ABSSignInSwitchTests.Stand()
        defer { stand.restore() }
        let snapshotURL = try #require(WidgetSnapshot.snapshotURL)
        let keptSnapshot = try? Data(contentsOf: snapshotURL)
        defer {
            if let keptSnapshot { try? keptSnapshot.write(to: snapshotURL) } else { try? FileManager.default.removeItem(at: snapshotURL) }
        }
        let server = try await ABSLoopback.start(login: .refuse, libraries: .accept, userId: "user-b",
                                                 singleSignOn: .token("token-sso"))
        defer { server.stop() }
        let sameServer = server.address.replacingOccurrences(of: "http://", with: "https://")
        for (storedUser, switches) in [("user-a", true), ("user-b", false)] {
            AppStorageKeys.set(storedUser, for: AppStorageKeys.absSignedInUser)
            WidgetSnapshot(itemId: "li_former", title: "Titel", author: nil, fraction: 0.5, remainingText: nil, isPlaying: false).save()
            #expect(WidgetSnapshot.load() != nil, "the precondition: a title of the account before")
            let auth = signedIn(to: sameServer)
            auth.serverURLString = server.address
            await auth.connectWithSSO(window: ReturningWindow())
            #expect(auth.errorMessage == nil, "\(storedUser): \(String(describing: auth.errorMessage)) \(server.diagnosis)")
            #expect((WidgetSnapshot.load() == nil) == switches, "\(storedUser): the title of the account before")
            #expect(AppStorageKeys.string(AppStorageKeys.absSignedInUser) == "user-b")
        }
    }
}
#endif
