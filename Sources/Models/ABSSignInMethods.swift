// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ways of signing in an Audiobookshelf server offers, read from its
/// `GET /status` (asked without a sign-in). `authMethods` names `local`
/// (username and password) and `openid` (single sign-on); the server drops
/// `openid` from the list while its settings for it are incomplete, and an
/// empty or missing list means `local` alone, as the server itself reads it.
/// The text of the server's own sign-on button travels in
/// `authFormData.authOpenIDButtonText`, only while `openid` is on.
nonisolated struct ABSSignInMethods: Equatable, Sendable {
    let offersPassword: Bool
    let offersSSO: Bool
    /// The server's text for its sign-on button; nil when it gives none.
    let ssoButtonText: String?

    private struct Status: Decodable {
        let app: String?
        let authMethods: [String]?
        let authFormData: FormData?
    }

    private struct FormData: Decodable {
        let authOpenIDButtonText: String?
    }

    /// Thrown for an answer that is no Audiobookshelf status: a proxy page
    /// or a login wall must not read as "password only".
    struct Unreadable: Error, Equatable {}

    /// The methods in a status answer. An answer that is not JSON, or that
    /// does not name itself `audiobookshelf`, throws.
    static func from(statusBody data: Data) throws -> ABSSignInMethods {
        let status: Status
        do {
            status = try JSONDecoder().decode(Status.self, from: data)
        } catch {
            throw Unreadable()
        }
        guard status.app == "audiobookshelf" else { throw Unreadable() }
        let methods = status.authMethods ?? []
        let sso = methods.contains("openid")
        let password = methods.isEmpty || methods.contains("local")
        let text = status.authFormData?.authOpenIDButtonText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ABSSignInMethods(offersPassword: password, offersSSO: sso,
                                ssoButtonText: sso && !(text ?? "").isEmpty ? text : nil)
    }
}
