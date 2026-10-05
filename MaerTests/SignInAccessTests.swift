// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Security
import Testing
@testable import Maer

/// A stored access that could not be read at start (before the first unlock
/// after a restart) is unknown, not a sign-out, and is read again on return.
@MainActor
struct SignInAccessTests {
    /// The keychain as the witness sets it, per key.
    final class Keychain {
        var answers: [String: KeychainRead] = [:]
        func read(_ key: String) -> KeychainRead { answers[key] ?? .missing }
    }

    @Test("die Tuer trennt fehlend, unlesbar und Wert")
    func theDoorTellsMissingFromUnreadable() {
        #expect(KeychainRead.of(status: errSecItemNotFound, data: nil) == .missing)
        #expect(KeychainRead.of(status: errSecInteractionNotAllowed, data: nil) == .unreadable,
                "a locked device is no missing access")
        #expect(KeychainRead.of(status: errSecSuccess, data: Data("token".utf8)) == .value("token"))
        #expect(KeychainRead.of(status: errSecSuccess, data: Data([0xFF, 0xFE])) == .missing,
                "bytes that do not decode stay no access")
    }

    /// The rule's answer as one text, so a witness compares both halves.
    private func state(url: KeychainRead, token: KeychainRead) -> String {
        let answer = SignInState.of(url: url, token: token)
        return "\(answer.signedIn),\(answer.unknown)"
    }

    @Test("unlesbar haelt die Anmeldung, fehlend meldet ab")
    func unreadableKeepsTheSignIn() {
        #expect(state(url: .value("https://abs.example"), token: .value("t")) == "true,false")
        #expect(state(url: .value("https://abs.example"), token: .unreadable) == "true,true")
        #expect(state(url: .unreadable, token: .value("t")) == "true,true")
        #expect(state(url: .value("https://abs.example"), token: .missing) == "false,false")
        #expect(state(url: .missing, token: .missing) == "false,false")
    }

    @Test("unlesbar beim Start, dann lesbar: angemeldet und die Bibliothek laedt ohne Neustart")
    func anUnreadableAccessIsReadAgainOnReturn() async {
        let keychain = Keychain()
        keychain.answers = [KeychainKey.serverURL: .unreadable, KeychainKey.apiToken: .unreadable]
        let auth = AuthViewModel(read: keychain.read)
        #expect(auth.isLoggedIn, "an unreadable access signed out")
        #expect(auth.accessUnknown && auth.apiClient.accessUnknown)
        #expect(auth.apiClient.token == nil, "the precondition: the client has no token")

        final class Loads { var count = 0 }
        let loads = Loads()
        // Still locked at a return: nothing changes, nothing loads.
        AppHousekeeping.rereadUnknownAccess(auth: auth) { loads.count += 1 }
        #expect(auth.accessUnknown)

        keychain.answers = [KeychainKey.serverURL: .value("https://abs.example"), KeychainKey.apiToken: .value("t")]
        AppHousekeeping.rereadUnknownAccess(auth: auth) { loads.count += 1 }
        for _ in 0..<100 where loads.count == 0 { await Task.yield() }
        #expect(auth.isLoggedIn && !auth.accessUnknown && !auth.apiClient.accessUnknown)
        #expect(auth.apiClient.token == "t" && auth.apiClient.baseURL.absoluteString == "https://abs.example")
        #expect(loads.count == 1, "the library loads once the access reads")
        #expect(!auth.rereadIfUnknown(), "a known access is not read again")
    }

    @Test("ein fehlender Zugang bleibt abgemeldet, auch nach dem Nachlesen")
    func aMissingAccessStaysSignedOut() {
        let keychain = Keychain()
        let auth = AuthViewModel(read: keychain.read)
        #expect(!auth.isLoggedIn && !auth.accessUnknown)
        #expect(!auth.rereadIfUnknown())

        keychain.answers = [KeychainKey.serverURL: .value("https://abs.example"), KeychainKey.apiToken: .unreadable]
        let doubted = AuthViewModel(read: keychain.read)
        keychain.answers[KeychainKey.apiToken] = .missing
        #expect(!doubted.rereadIfUnknown())
        #expect(!doubted.isLoggedIn && !doubted.accessUnknown, "a token that turns out missing signs out")
    }
}
