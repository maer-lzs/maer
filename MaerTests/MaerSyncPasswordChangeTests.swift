// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Security
@testable import Maer

/// The move and the change of contract version 6, and where `feed` lives.
@MainActor
struct MaerSyncPasswordChangeTests {
    private let address = "https://v6change.example.test"
    private var base: URL { URL(string: address)! }
    /// The salt the attrappe's `/v1/salt` answers with.
    private let serviceSalt = Data(repeating: 1, count: 16)
    /// The salt this device picks for the new password in the witnesses.
    private let pickedSalt = Data(repeating: 9, count: 16)

    private func clean(_ body: () async throws -> Void) async rethrows {
        KeychainStore.delete(forKey: ServiceKeyPin.account(for: base)!)
        FeedKeyStore.forget(for: base)
        defer {
            KeychainStore.delete(forKey: ServiceKeyPin.account(for: base)!)
            FeedKeyStore.forget(for: base)
        }
        try await body()
    }

    private func change(_ transport: MaerSyncCarrierTests.FakeTransport, current: String = "das alte passwort",
                        new: String = "ein ganz neues passwort", repeated: String? = nil,
                        salt: Data? = Data(repeating: 9, count: 16)) async -> MaerSyncSignIn.Outcome {
        await MaerSyncSignIn.changePassword(address: address, owner: "owner-a", current: current, new: new,
                                            repeated: repeated ?? new,
                                            device: "dev-a", transport: transport, freshSalt: { salt })
    }

    @Test("Umzug (Form secret): das alte Passwort reist einmal als current.secret, das neue nur als Beweis, feed nur aus dem neuen")
    func theMoveSendsTheOldOnceAndKeepsFeedOfTheNew() async throws {
        try await clean {
            let transport = MaerSyncCarrierTests.FakeTransport()
            transport.saltForm = .secret
            let outcome = await change(transport)
            #expect(outcome == .signedIn(MaerSyncAccess(baseURL: base, token: "a-token"), account: "owner-a"))
            try #require(transport.passwordChanges.count == 1)
            let sent = transport.passwordChanges[0]
            #expect(sent.current == .secret("das alte passwort"), "the move is the one time the old password travels")
            let fresh = try SignInDerivation.derive(password: "ein ganz neues passwort", salt: pickedSalt, rounds: 600_000)
            #expect(sent.new == MaerSyncNewPassword(proof: fresh.proofBase64, salt: pickedSalt, rounds: 600_000))
            #expect(transport.tokenRequests == 0, "no sign-in way at all")
            // Invariant 3: feed comes from the NEW password only.
            #expect(FeedKeyStore.held(for: base) == fresh.feed)
            let old = try SignInDerivation.derive(password: "das alte passwort", salt: serviceSalt, rounds: 600_000)
            #expect(FeedKeyStore.held(for: base) != old.feed, "never from the password that reached the service")
        }
    }

    @Test("Wechsel (Form proof): auch das geltende Passwort reist nur als Beweis")
    func anOrdinaryChangeSendsOnlyProofs() async throws {
        try await clean {
            let transport = MaerSyncCarrierTests.FakeTransport()
            let outcome = await change(transport)
            #expect(outcome == .signedIn(MaerSyncAccess(baseURL: base, token: "a-token"), account: "owner-a"))
            let current = try SignInDerivation.derive(password: "das alte passwort", salt: serviceSalt, rounds: 600_000)
            #expect(transport.passwordChanges.first?.current == .proof(current.proofBase64))
        }
    }

    @Test("Wechsel: die Passwort-Regel gilt, bevor irgendetwas gefragt wird, und ohne Zufall wird nichts gesendet")
    func theRuleComesFirstAndNoRandomnessSendsNothing() async {
        await clean {
            let transport = MaerSyncCarrierTests.FakeTransport()
            #expect(await change(transport, new: "zu kurz") == .newPasswordTooShort(missing: 5))
            #expect(await change(transport, current: "das alte passwort", new: "das alte passwort") == .newPasswordSameAsCurrent)
            #expect(await change(transport, repeated: "ein ganz neues passwort!") == .newPasswordRepeatDiffers)
            #expect(transport.keyRequests == 0 && transport.saltRequests == 0, "nothing was asked")
            #expect(await change(transport, salt: nil) == .localFailure)
            #expect(await change(transport, salt: Data(count: 15)) == .localFailure, "a salt of the wrong size is no salt")
            #expect(transport.passwordChanges.isEmpty)
            #expect(FeedKeyStore.held(for: base) == nil)
        }
    }

    @Test("Anmeldung: feed aus dem Passwort, das nur als Beweis reiste, bleibt auf diesem Geraet")
    func theSignInKeepsFeed() async throws {
        try await clean {
            let transport = MaerSyncCarrierTests.FakeTransport()
            _ = await MaerSyncSignIn.perform(address: address, owner: "owner-a", password: "ein langes passwort",
                                             device: "dev-a", transport: transport)
            let keys = try SignInDerivation.derive(password: "ein langes passwort", salt: serviceSalt, rounds: 600_000)
            #expect(FeedKeyStore.held(for: base) == keys.feed)
            transport.refuseToken = true
            FeedKeyStore.forget(for: base)
            _ = await MaerSyncSignIn.perform(address: address, owner: "owner-a", password: "ein langes passwort",
                                             device: "dev-a", transport: transport)
            #expect(FeedKeyStore.held(for: base) == nil, "a refused sign-in keeps nothing")
        }
    }

    private func attributes(ofAccount account: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    @Test("feed liegt nur auf diesem Geraet: nicht in einer Sicherung, nicht im iCloud-Schluesselbund; Abmelden vergisst ihn")
    func feedStaysOnThisDevice() async throws {
        try await clean {
            let feed = Data(repeating: 5, count: 32)
            FeedKeyStore.keep(feed, for: base)
            #expect(FeedKeyStore.held(for: base) == feed)
            let account = try #require(FeedKeyStore.account(for: base))
            let attrs = try #require(attributes(ofAccount: account))
            #expect(attrs[kSecAttrAccessible as String] as? String == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
            #expect((attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
            FeedKeyStore.keep(Data(repeating: 5, count: 31), for: base)
            #expect(FeedKeyStore.held(for: base) == feed, "31 bytes are no feed key and overwrite nothing")
            FeedKeyStore.forget(for: base)
            #expect(FeedKeyStore.held(for: base) == nil)
        }
        // The sign-out forgets it: a source fence, because running the real
        // sign-out would clear this process's own sync state.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let signIn = SyncContractFenceTests.stripped(try String(
            contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncSignIn.swift"), encoding: .utf8))
        let out = try #require(signIn.range(of: "static func signOut()"))
        #expect(signIn[out.upperBound...].prefix(400).contains("FeedKeyStore.forget("))
        var holders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if text.contains("maerSyncFeed:") { holders.append(file.lastPathComponent) }
            if file.lastPathComponent == "FeedKeyStore.swift" {
                #expect(!text.contains("synchronizable"), "the feed store names the travel parameter")
                #expect(text.contains("ThisDeviceOnly"))
            }
        }
        #expect(holders == ["FeedKeyStore.swift"], "one place writes the feed key")
    }
}
#endif
