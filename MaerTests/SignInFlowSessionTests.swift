// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The session of one sign-in flow keeps the server's cookies to itself,
/// and its requests follow no redirect.
struct SignInFlowSessionTests {

    @Test("A cookie from the sign-in flow does not reach the shared store")
    func flowCookiesStayApart() throws {
        let flow = HTTP.SignInFlow()
        defer { flow.close() }
        #expect(flow.cookieStorage !== HTTPCookieStorage.shared)
        let host = "sso-flow-\(UUID().uuidString.lowercased()).example"
        let url = try #require(URL(string: "https://\(host)/auth/openid"))
        let cookie = try #require(HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "connect.sid", .value: "flow", .secure: "TRUE",
        ]))
        let own = try #require(flow.cookieStorage, "the flow keeps no cookies, so the exchange would lose the start")
        own.setCookie(cookie)
        // The precondition: the flow's store took the cookie.
        #expect(own.cookies(for: url)?.map(\.name) == ["connect.sid"])
        #expect((HTTPCookieStorage.shared.cookies(for: url) ?? []).isEmpty)
    }

    @Test("A request of the flow follows no redirect")
    func flowFollowsNoRedirect() async throws {
        let from = try #require(URL(string: "https://abs.example/auth/openid"))
        let to = try #require(URL(string: "https://id.example/authorize"))
        let response = try #require(HTTPURLResponse(url: from, statusCode: 302, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Location": to.absoluteString]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: from)
        func next(_ guardian: RedirectGuard) async -> URLRequest? {
            await withCheckedContinuation { done in
                guardian.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                    newRequest: URLRequest(url: to)) { done.resume(returning: $0) }
            }
        }
        let refusing = RedirectGuard.followingNone()
        #expect(await next(refusing) == nil)
        #expect(refusing.refused)
        // The instrument sees the difference: the guard of every other
        // request follows the same redirect.
        #expect(await next(RedirectGuard.following())?.url == to)
    }
}
#endif
