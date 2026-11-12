// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The window that walks the person through the provider's sign-in and
/// comes back with the address the provider sent them to.
protocol SignInWindow {
    func signIn(at page: URL, returnScheme: String) async throws -> URL
}

/// One run of the server's single sign-on (`ABSSSO`): start at the server,
/// the provider's page in the sign-in window, the code exchanged at the
/// server. The requests go through `fetch` (one flow session, so the
/// exchange carries the cookie of the start); the window and `fetch` are
/// seams, the steps between them are the pure rules.
struct ABSSSOFlow {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let fetch: Fetch
    let window: any SignInWindow
    var randomValue: () -> String = { PKCE.randomValue() }

    /// The long-lived token of the person who signed in.
    func run(server: URL) async throws -> String {
        let verifier = randomValue()
        let state = randomValue()
        guard let start = ABSSSO.startURL(server: server, challenge: PKCE.challenge(for: verifier), state: state) else {
            throw ABSSSO.Failure.startUnanswered(status: -1)
        }
        let (startBody, startResponse) = try await fetch(URLRequest(url: start))
        let page = try ABSSSO.providerPage(status: startResponse.statusCode,
                                           location: startResponse.value(forHTTPHeaderField: "Location"),
                                           body: startBody)
        let back = try await window.signIn(at: page, returnScheme: ABSSSO.callbackScheme)
        let code = try ABSSSO.code(fromReturn: back, state: state)
        guard let exchange = ABSSSO.exchangeURL(server: server, state: state, code: code, verifier: verifier) else {
            throw ABSSSO.Failure.exchangeUnanswered(status: -1)
        }
        let (body, response) = try await fetch(URLRequest(url: exchange))
        return try ABSSSO.token(status: response.statusCode,
                                location: response.value(forHTTPHeaderField: "Location"),
                                body: body)
    }
}
