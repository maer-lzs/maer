// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How a Subsonic server is signed in to, as a pure rule.
///
/// Most servers take the token (`u`, `t`, `s`). Nextcloud Music refuses it
/// with error 41 and offers the OpenSubsonic key sign-in instead: `apiKey`
/// ALONE, with the key from its music settings, which is also what a person
/// types into the password field for that server. The key never becomes a
/// second stored secret; it is the password, read from the keychain. It
/// travels only over https, because in the query it is clear text.
nonisolated enum SubsonicSignIn {
    enum Mode: String, Equatable, Sendable {
        case token
        case apiKey
    }

    /// Every query name `items` writes, in any mode. They sign a request in
    /// and name no picture, so no cover file name carries them
    /// (`ImageCache.signInQueryNames`).
    static let queryNames: Set<String> = ["u", "t", "s", "apiKey"]

    /// The sign-in parts of one request, in the order the client sets them.
    /// With the key nothing else travels: a user name beside it is a second,
    /// conflicting mechanism (error 43), and a token beside it is refused as
    /// a token (error 41), both measured against Nextcloud Music.
    static func items(_ mode: Mode, username: String, secret: String,
                      token: String, salt: String) -> [URLQueryItem] {
        switch mode {
        case .token:
            return [URLQueryItem(name: "u", value: username),
                    URLQueryItem(name: "t", value: token),
                    URLQueryItem(name: "s", value: salt)]
        case .apiKey:
            return [URLQueryItem(name: "apiKey", value: secret)]
        }
    }

    /// Whether the key may travel to this address. The key rides in the
    /// query in clear text (the OpenSubsonic form, and the only one a
    /// player's stream address can carry), so only an encrypted connection
    /// keeps it off the way. Over plain http the token stays: it sends a
    /// salted hash, never the password.
    static func keyTransportIsSafe(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    /// What follows an error answer.
    enum Decision: Equatable {
        /// Retry once with this mode.
        case retry(Mode)
        /// The server wants the key, but the address is not encrypted.
        case needsEncryption
        /// The error stands.
        case stand
    }

    /// A refused token (41) moves to the key only when the server offers
    /// key sign-in AND the key may travel there, so a server that never
    /// offered it keeps its sentence and a plain address never carries the
    /// password in clear text. A key refused as a mechanism (42) goes back
    /// to the token.
    static func decision(afterCode code: Int, current: Mode, offersKeySignIn: Bool,
                         transportIsSafe: Bool) -> Decision {
        switch (code, current) {
        case (41, .token):
            guard offersKeySignIn else { return .stand }
            return transportIsSafe ? .retry(.apiKey) : .needsEncryption
        case (42, .apiKey):
            return .retry(.token)
        default:
            return .stand
        }
    }

    /// One entry of a `getOpenSubsonicExtensions` answer.
    struct Extension: Decodable, Equatable, Sendable {
        let name: String
        let versions: [Int]
    }

    /// Whether a server's extensions include key sign-in in the version
    /// this client speaks.
    static func offersKeySignIn(_ extensions: [Extension]) -> Bool {
        extensions.contains { $0.name == "apiKeyAuthentication" && $0.versions.contains(1) }
    }

    /// What a sign-in error code says to the person, by the measured codes.
    /// 41 and 43 share one meaning: a mix of mechanisms comes back as 41 or
    /// as 43 depending on which check a server runs first.
    enum Refusal: Equatable {
        case wrongCredentials
        case wrongKey
        case mechanismMismatch
        case noSignIn
    }

    static func refusal(forCode code: Int) -> Refusal? {
        switch code {
        case 40: return .wrongCredentials
        case 44: return .wrongKey
        case 41, 43: return .mechanismMismatch
        case 10: return .noSignIn
        default: return nil
        }
    }
}
