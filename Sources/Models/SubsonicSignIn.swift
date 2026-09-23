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
/// second stored secret; it is the password, read from the keychain.
nonisolated enum SubsonicSignIn {
    enum Mode: String, Equatable, Sendable {
        case token
        case apiKey
    }

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

    /// The mode to retry with after an error answer, or nil when the error
    /// stands. A refused token (41) moves to the key only when the server
    /// offers key sign-in, so a server that never offered it keeps its
    /// sentence. A key refused as a mechanism (42) goes back to the token.
    static func retryMode(afterCode code: Int, current: Mode, offersKeySignIn: Bool) -> Mode? {
        switch (code, current) {
        case (41, .token): return offersKeySignIn ? .apiKey : nil
        case (42, .apiKey): return .token
        default: return nil
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
