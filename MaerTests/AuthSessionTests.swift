// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// 🔴 **Credentials are deleted by the user, never by a server answer.**
/// A homeserver coming back up answers 401 for minutes; the old path logged
/// out and dropped the keychain token, which no restart could undo.
@MainActor
struct AuthSessionTests {
    @Test("a 401 downpour leaves the key untouched")
    func unauthorizedNeverDeletesTheToken() async {
        let key = "test-token-\(UUID().uuidString)"
        KeychainStore.save("SECRET-TOKEN", forKey: key)
        defer { KeychainStore.delete(forKey: key) }

        let auth = AppSession.shared.authViewModel
        // This test changes a SINGLETON. It restores
        // the initial state afterwards, otherwise the next
        // test in the same suite carries the doubt on.
        defer { auth.logout() }   // no real access is set in the test run
        // The downpour: many 401s in a row, as the start-up
        // of the reverse proxy delivers them.
        for _ in 0..<25 { auth.markSessionSuspect() }

        // The state is DOUBT, not sign-out …
        #expect(auth.sessionSuspect)
        // … and the stored key lies unchanged in the keychain.
        #expect(KeychainStore.load(forKey: key) == "SECRET-TOKEN")
    }

    @Test("the probe separates 'server not there' from 'server says no'")
    func probeSeparatesUnreachableFromRejected() async {
        // Without a token the question is answered without asking the network.
        let client = APIClient(baseURL: URL(string: "https://example.invalid")!, token: nil)
        #expect(await client.probeAuthorization() == .rejected)
        // With a token but an unreachable host: UNREACHABLE. Exactly the
        // restart window in which nothing may be touched.
        let offline = APIClient(baseURL: URL(string: "https://127.0.0.1:9")!, token: "T")
        #expect(await offline.probeAuthorization() == .unreachable)
    }

    @Test("a successful re-sign-in clears the doubt", .needsTheSources)
    func successfulSignInClearsTheDoubt() {
        // The fourth case: reject → re-sign-in → state gone.
        // Checked at the SOURCE, because the success path needs a real server:
        // the connect() success branch must clear both flags.
        // The probe loop no longer does it after `needsReauth`.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/ViewModels/AuthViewModel.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard let range = text.range(of: "isLoggedIn = true") else {
            Issue.record("der Erfolgspfad wurde umgebaut — Zaun pruefen")
            return
        }
        let success = text[range.lowerBound...].prefix(500)
        #expect(success.contains("sessionSuspect = false"))
        #expect(success.contains("needsReauth = false"))
    }

    @Test("only the user sign-out path clears the key", .needsTheSources)
    func onlyTheUserPathDeletes() {
        // The fence in text form: the 401 callback points to markSessionSuspect,
        // never to logout(). Measured at the source, so that a later
        // rework does not silently withdraw the rule.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/ViewModels/AuthViewModel.swift")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard let range = text.range(of: "onUnauthorized = {") else {
            Issue.record("der 401-Rueckruf wurde umbenannt — Zaun pruefen")
            return
        }
        let handler = text[range.lowerBound...].prefix(400)
        #expect(handler.contains("markSessionSuspect"))
        #expect(!handler.contains("logout()"))
    }
}
#endif
