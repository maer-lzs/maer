// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636) with the SHA-256 method: the app
/// keeps a random verifier and sends only its hash, the challenge; the code
/// the provider hands out is worth nothing without the verifier.
nonisolated enum PKCE {
    /// URL-safe base64 without padding (RFC 7636, appendix A).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A random value of `byteCount` bytes as URL-safe text. The system
    /// generator is the cryptographic one on Apple platforms.
    static func randomValue(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    /// The challenge of a verifier: the SHA-256 of its ASCII bytes.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// The single sign-on of an Audiobookshelf server for apps, as the server
/// runs it (`/auth/openid`, `/auth/openid/mobile-redirect`,
/// `/auth/openid/callback`): the app starts the flow at its server, the
/// system's sign-in window walks the provider and comes back to the app's
/// return address with a code, and the app exchanges the code at its
/// server for the same answer a password sign-in gets.
nonisolated enum ABSSSO {
    /// The return address the server admits without any setting, and the
    /// scheme the sign-in window catches inside its own session.
    static let callbackScheme = "audiobookshelf"
    static let callbackURL = "audiobookshelf://oauth"

    enum Failure: Error, Equatable {
        /// The server does not admit the app's return address.
        case returnAddressRefused
        /// The provider's sign-in page is not on https.
        case providerNotSecure
        /// The start was answered with something else than a way to the provider.
        case startUnanswered(status: Int)
        /// The system's sign-in window did not open.
        case windowUnavailable
        /// The provider or the server sent the person back with an error.
        case refusedBySignIn(String)
        /// The return carries another flow's state: nobody is signed in by it.
        case foreignState
        /// The return carries no code.
        case noCode
        /// The server does not know the flow any more (its cookie is gone).
        case flowUnknown
        /// The answer carries only a token that expires, which this app cannot renew yet.
        case needsRenewal
        /// The exchange was answered with something unreadable.
        case exchangeUnanswered(status: Int)
    }

    /// The address that starts the flow at the server.
    static func startURL(server: URL, challenge: String, state: String) -> URL? {
        guard var components = URLComponents(url: server.appendingPathComponent("auth/openid"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.setQuery([
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: callbackURL),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
        ])
        return components.url
    }

    /// The provider's sign-in page from the server's answer to the start: a
    /// redirect to an https address. The server refuses a return address it
    /// does not admit with 400 and the text `Invalid redirect_uri`.
    static func providerPage(status: Int, location: String?, body: Data) throws(Failure) -> URL {
        if (300...399).contains(status) {
            guard let location, let page = URL(string: location), let scheme = page.scheme?.lowercased(),
                  page.host != nil else {
                throw .startUnanswered(status: status)
            }
            guard scheme == "https" else { throw .providerNotSecure }
            return page
        }
        if status == 400, String(decoding: body, as: UTF8.self).contains("Invalid redirect_uri") {
            throw .returnAddressRefused
        }
        throw .startUnanswered(status: status)
    }

    /// The provider's sign-in page from the server's answer to the start.
    static func providerPage(_ response: HTTPURLResponse, body: Data) throws(Failure) -> URL {
        try providerPage(status: response.statusCode, location: response.value(forHTTPHeaderField: "Location"), body: body)
    }

    /// The code from the address the sign-in window came back with. Only
    /// the app's return address with this flow's state carries one.
    static func code(fromReturn url: URL, state: String) throws(Failure) -> String {
        guard url.scheme?.lowercased() == callbackScheme, url.host?.lowercased() == "oauth" else {
            throw .noCode
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let error = value("error") {
            throw .refusedBySignIn(value("error_description") ?? error)
        }
        guard value("state") == state else { throw .foreignState }
        guard let code = value("code") else { throw .noCode }
        return code
    }

    /// The address that exchanges the code at the server.
    static func exchangeURL(server: URL, state: String, code: String, verifier: String) -> URL? {
        guard var components = URLComponents(url: server.appendingPathComponent("auth/openid/callback"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.setQuery([
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
        ])
        return components.url
    }

    /// The token from the server's answer to the exchange.
    static func token(_ response: HTTPURLResponse, body: Data) throws(Failure) -> String {
        try token(status: response.statusCode, location: response.value(forHTTPHeaderField: "Location"), body: body)
    }

    /// The token from the server's answer to the exchange. A success is the
    /// answer of a password sign-in; the long-lived `token` is taken, as
    /// there. An answer with only the expiring `accessToken` signs nobody
    /// in. The server answers a flow it does not know with 400 `No session`;
    /// a failure further on comes back as a redirect to its own sign-in page
    /// with the reason in `error`.
    static func token(status: Int, location: String?, body: Data) throws(Failure) -> String {
        if (200...299).contains(status) {
            let answer: LoginResponse
            do {
                answer = try JSONDecoder().decode(LoginResponse.self, from: body)
            } catch {
                throw .exchangeUnanswered(status: status)
            }
            if let token = answer.user.token, !token.isEmpty { return token }
            if let access = answer.user.accessToken, !access.isEmpty { throw .needsRenewal }
            throw .exchangeUnanswered(status: status)
        }
        if status == 400, String(decoding: body, as: UTF8.self).contains("No session") {
            throw .flowUnknown
        }
        if (300...399).contains(status), let location,
           let reason = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "error" })?.value,
           !reason.isEmpty {
            throw .refusedBySignIn(reason)
        }
        throw .exchangeUnanswered(status: status)
    }
}
