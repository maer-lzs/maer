// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The status answers below are rebuilt from the server's source
/// (Audiobookshelf 2.37.2, `server/Server.js` `GET /status` and
/// `ServerSettings.authFormData`), not recorded from a running server.
struct ABSSignInMethodsTests {
    private func methods(_ json: String) throws -> ABSSignInMethods {
        try ABSSignInMethods.from(statusBody: Data(json.utf8))
    }

    @Test("Password only: no button for SSO")
    func passwordOnly() throws {
        let read = try methods(#"{"app":"audiobookshelf","serverVersion":"2.37.2","isInit":true,"authMethods":["local"],"authFormData":{"authLoginCustomMessage":null}}"#)
        #expect(read == ABSSignInMethods(offersPassword: true, offersSSO: false, ssoButtonText: nil))
    }

    @Test("Password and SSO: the text of the server comes along")
    func passwordAndSSO() throws {
        let read = try methods(#"{"app":"audiobookshelf","isInit":true,"authMethods":["local","openid"],"authFormData":{"authLoginCustomMessage":null,"authOpenIDButtonText":"Login with Authentik","authOpenIDAutoLaunch":false}}"#)
        #expect(read == ABSSignInMethods(offersPassword: true, offersSSO: true, ssoButtonText: "Login with Authentik"))
    }

    @Test("SSO only: no password")
    func ssoOnly() throws {
        let read = try methods(#"{"app":"audiobookshelf","authMethods":["openid"],"authFormData":{"authOpenIDButtonText":"  "}}"#)
        #expect(read == ABSSignInMethods(offersPassword: false, offersSSO: true, ssoButtonText: nil))
    }

    @Test("An empty or missing list means password, as the server reads it")
    func emptyMeansPassword() throws {
        #expect(try methods(#"{"app":"audiobookshelf","authMethods":[]}"#).offersPassword)
        #expect(try methods(#"{"app":"audiobookshelf"}"#) == ABSSignInMethods(offersPassword: true, offersSSO: false, ssoButtonText: nil))
    }

    @Test("A text without openid stays out")
    func textWithoutSSOIsDropped() throws {
        let read = try methods(#"{"app":"audiobookshelf","authMethods":["local"],"authFormData":{"authOpenIDButtonText":"Login"}}"#)
        #expect(read.ssoButtonText == nil)
    }

    @Test("A page that is not a status of Audiobookshelf throws")
    func foreignAnswerThrows() {
        #expect(throws: ABSSignInMethods.Unreadable.self) { try methods("<html><body>Sign in</body></html>") }
        #expect(throws: ABSSignInMethods.Unreadable.self) { try methods(#"{"authMethods":["openid"]}"#) }
        #expect(throws: ABSSignInMethods.Unreadable.self) { try methods(#"{"app":"jellyfin","authMethods":["openid"]}"#) }
    }
}
#endif
