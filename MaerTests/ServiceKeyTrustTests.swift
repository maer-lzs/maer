// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Security
@testable import Maer

/// Holding on to a service's key: the pure rule at its edges, the holding on
/// this device and nowhere else, and the sign-in as the meeting where the
/// rule is applied. The three promises a key change stands on are each
/// driven here: it is an event and never a silent swap, the person has a way
/// to want it, and the held key does not travel.
@MainActor
struct ServiceKeyTrustTests {
    // MARK: - The rule

    @Test("nichts gehalten ist die erste Begegnung, auch ein leerer Wert")
    func nothingHeldIsAFirstMeeting() {
        #expect(ServiceKeyTrust.standing(held: nil, offered: "AAAA") == .first)
        #expect(ServiceKeyTrust.standing(held: "", offered: "AAAA") == .first)
    }

    @Test("derselbe Abdruck ist unveraendert, ein anderer ist ein Wechsel mit beiden Werten")
    func sameIsUnchangedAndDifferentIsAChangeCarryingBoth() {
        #expect(ServiceKeyTrust.standing(held: "AAAA", offered: "AAAA") == .unchanged)
        #expect(ServiceKeyTrust.standing(held: "AAAA", offered: "BBBB") == .changed(held: "AAAA", offered: "BBBB"))
        // Compared as written: a fingerprint that differs by one letter is
        // a different key, and no normalisation sits in between.
        #expect(ServiceKeyTrust.standing(held: "AAAA", offered: "AAAB") != .unchanged)
    }

    // MARK: - The account

    @Test("das Konto ist Wirt und Port, klein geschrieben, ohne Pfad und ohne Schraegstrich")
    func theAccountIsHostAndPortOnly() throws {
        let plain = try #require(ServiceKeyPin.account(for: URL(string: "https://sync.example.test")!))
        #expect(plain == "serviceKeyPin:sync.example.test")
        // Case, a path, a query, a trailing slash and the scheme: none of
        // them makes it a different service.
        #expect(ServiceKeyPin.account(for: URL(string: "https://Sync.Example.test/")!) == plain)
        #expect(ServiceKeyPin.account(for: URL(string: "https://sync.example.test/v1/")!) == plain)
        #expect(ServiceKeyPin.account(for: URL(string: "https://sync.example.test?x=1")!) == plain)
        #expect(ServiceKeyPin.account(for: URL(string: "http://sync.example.test")!) == plain)
        let withPort = ServiceKeyPin.account(for: URL(string: "https://sync.example.test:8443")!)
        #expect(withPort == "serviceKeyPin:sync.example.test:8443")
        #expect(withPort != ServiceKeyPin.account(for: URL(string: "https://sync.example.test:8444")!),
                "another port is another service")
        #expect(ServiceKeyPin.account(for: URL(fileURLWithPath: "/tmp/nothing")) == nil, "no host, no account")
    }

    // MARK: - The holding

    /// The attributes of the held item as the keychain reports them.
    private func attributes(ofAccount account: String) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    private func freshHost() -> URL {
        URL(string: "https://\(UUID().uuidString.lowercased()).test")!
    }

    @Test("gehalten wird geraete-lokal und nicht in einer Sicherung, und ein Halten ueberschreibt")
    func heldOnThisDeviceOnlyAndHoldingOverwrites() throws {
        let host = freshHost()
        let account = try #require(ServiceKeyPin.account(for: host))
        defer { KeychainStore.delete(forKey: account) }
        #expect(ServiceKeyPin.held(for: host) == nil)

        ServiceKeyPin.hold("AAAA-BBBB", for: host)
        #expect(ServiceKeyPin.held(for: host) == "AAAA-BBBB")
        let attrs = try #require(attributes(ofAccount: account))
        // The two halves of "it does not travel": not in a backup, and not
        // in the iCloud keychain. The device link code is deliberately in a
        // backup (it is a recovery key); this is a memory of a meeting.
        #expect(attrs[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        #expect((attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)

        ServiceKeyPin.hold("CCCC-DDDD", for: host)
        #expect(ServiceKeyPin.held(for: host) == "CCCC-DDDD", "holding is blunt; the guard is the rule, not the store")
        ServiceKeyPin.hold("", for: host)
        #expect(ServiceKeyPin.held(for: host) == "CCCC-DDDD", "an empty fingerprint is not held")
    }

    @Test("zwei Wirte sind zwei Erinnerungen")
    func twoHostsAreTwoMemories() throws {
        let one = freshHost(), two = freshHost()
        defer {
            KeychainStore.delete(forKey: ServiceKeyPin.account(for: one)!)
            KeychainStore.delete(forKey: ServiceKeyPin.account(for: two)!)
        }
        ServiceKeyPin.hold("AAAA", for: one)
        #expect(ServiceKeyPin.held(for: two) == nil)
        ServiceKeyPin.hold("BBBB", for: two)
        #expect(ServiceKeyPin.held(for: one) == "AAAA")
    }

    /// A source fence, because a behaviour case in the simulator cannot see
    /// whether an item would reach the iCloud keychain on a device. Same
    /// construction as the fence over the device link code.
    @Test("die Ablage nennt den Reise-Parameter nie und haelt geraete-lokal")
    func theStoreNeverNamesTheTravelParameterAndHoldsLocally() throws {
        let door = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "ServiceKeyPin.swift" })
        // Without comment lines: the file's own comment says why the word is
        // absent, and a fence that counts the talk about a thing tore at the
        // first run on a correct build.
        let text = SyncContractFenceTests.stripped(try String(contentsOf: door, encoding: .utf8))
        #expect(!text.contains("synchronizable"), "the pin store names the travel parameter")
        #expect(text.contains("ThisDeviceOnly"), "the pin store does not hold on this device only")
        #expect(text.contains("KeychainStore.save("), "it writes to the keychain at all")

        var holders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let body = try String(contentsOf: file, encoding: .utf8)
            if body.contains("serviceKeyPin:") { holders.append(file.lastPathComponent) }
        }
        #expect(holders == ["ServiceKeyPin.swift"], "holders: \(holders.sorted())")
    }

    // MARK: - The sign-in as the meeting

    private func signIn(_ transport: MaerSyncCarrierTests.FakeTransport, at host: URL,
                        secret: String = "s", accepting: String? = nil) async -> MaerSyncSignIn.Outcome {
        await MaerSyncSignIn.perform(address: host.absoluteString, owner: "the-owner", secret: secret,
                                     acceptingKey: accepting, device: "dev-a", transport: transport)
    }

    @Test("die erste Begegnung haelt den Schluessel, und zwar erst nachdem der Dienst ja gesagt hat")
    func theFirstMeetingHoldsTheKeyOnceTheServiceSaidYes() async throws {
        let host = freshHost()
        let account = try #require(ServiceKeyPin.account(for: host))
        defer { KeychainStore.delete(forKey: account) }
        let transport = MaerSyncCarrierTests.FakeTransport()

        transport.refuseToken = true
        #expect(await signIn(transport, at: host, secret: "wrong") == .refused)
        #expect(transport.keyRequests == 1, "the key was met")
        #expect(ServiceKeyPin.held(for: host) == nil, "a refused sign-in holds nothing")

        transport.refuseToken = false
        let outcome = await signIn(transport, at: host)
        #expect(outcome == .signedIn(MaerSyncAccess(baseURL: host, token: "a-token"), account: "the-owner"))
        #expect(ServiceKeyPin.held(for: host) == transport.serviceFingerprint)

        // The ordinary case: the same key, nothing said, nothing rewritten.
        #expect(await signIn(transport, at: host) == .signedIn(MaerSyncAccess(baseURL: host, token: "a-token"), account: "the-owner"))
        #expect(ServiceKeyPin.held(for: host) == transport.serviceFingerprint)
    }

    @Test("ein anderer Schluessel haelt die Anmeldung an, BEVOR das Geheimnis reist")
    func aDifferentKeyStopsTheSignInBeforeTheSecretTravels() async throws {
        let host = freshHost()
        let account = try #require(ServiceKeyPin.account(for: host))
        defer { KeychainStore.delete(forKey: account) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        _ = await signIn(transport, at: host)
        #expect(transport.tokenRequests == 1)

        transport.serviceFingerprint = "ZZZZ-YYYY"
        #expect(await signIn(transport, at: host) == .keyChanged(held: "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF", offered: "ZZZZ-YYYY"))
        // This is the whole point of meeting before trading: the secret
        // did not go to whoever offered the new key.
        #expect(transport.tokenRequests == 1, "no token was asked for over a changed key")
        #expect(ServiceKeyPin.held(for: host) == "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF", "the held key is untouched")
    }

    @Test("die Annahme gilt genau dem angenommenen Schluessel und keinem naechsten")
    func acceptanceIsForTheAcceptedKeyAndNoOther() async throws {
        let host = freshHost()
        let account = try #require(ServiceKeyPin.account(for: host))
        defer { KeychainStore.delete(forKey: account) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        _ = await signIn(transport, at: host)
        transport.serviceFingerprint = "ZZZZ-YYYY"

        // Accepting the offered key signs in and holds it.
        #expect(await signIn(transport, at: host, accepting: "ZZZZ-YYYY")
                == .signedIn(MaerSyncAccess(baseURL: host, token: "a-token"), account: "the-owner"))
        #expect(ServiceKeyPin.held(for: host) == "ZZZZ-YYYY")
        #expect(transport.tokenRequests == 2)

        // A key that moved between the event and the answer is a new event:
        // the person accepted ONE key, not whatever comes next.
        transport.serviceFingerprint = "XXXX-WWWW"
        #expect(await signIn(transport, at: host, accepting: "ZZZZ-YYYY") == .keyChanged(held: "ZZZZ-YYYY", offered: "XXXX-WWWW"))
        #expect(transport.tokenRequests == 2, "and the secret stayed here")
        #expect(ServiceKeyPin.held(for: host) == "ZZZZ-YYYY")
    }

    @Test("ohne Schluessel gibt es keine Anmeldung, und die zwei Gruende tragen zwei Namen")
    func withoutAKeyThereIsNoSignInAndTheTwoReasonsHaveTwoNames() async throws {
        let host = freshHost()
        let account = try #require(ServiceKeyPin.account(for: host))
        defer { KeychainStore.delete(forKey: account) }
        let transport = MaerSyncCarrierTests.FakeTransport()

        transport.keyNotMade = true
        #expect(await signIn(transport, at: host) == .serviceHasNoKey)
        transport.keyNotMade = false
        transport.keyPathAbsent = true
        #expect(await signIn(transport, at: host) == .serviceIsOlder)
        transport.keyPathAbsent = false
        transport.offline = true
        #expect(await signIn(transport, at: host) == .unreachable("status(503)"))
        transport.offline = false

        #expect(transport.tokenRequests == 0, "the secret never left for a service without a key")
        #expect(ServiceKeyPin.held(for: host) == nil)
        #expect(MaerSyncSignIn.heldKey(forAddress: host.absoluteString) == nil)
        _ = await signIn(transport, at: host)
        #expect(MaerSyncSignIn.heldKey(forAddress: host.absoluteString) == transport.serviceFingerprint,
                "the page reads what the sign-in held")
    }
}
#endif
