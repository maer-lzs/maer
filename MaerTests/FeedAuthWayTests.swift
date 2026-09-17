// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Security
@testable import Maer

/// The feed credentials travel over exactly one way. Before: `write` asked
/// only the switch, so with a service set up every credential went to the
/// service AND to Apple's iCloud keychain. Now the way is the carrier
/// factories' question (a service access, else the switch), and the sign-in
/// and the sign-out rewrite what is held so no twin stays on the way that
/// is no longer taken. Measured on the real keychain of the test host.
struct FeedAuthWayTests {
    /// Whether the keychain item travels (the `synchronizable` attribute),
    /// read across both worlds; nil when there is no such item.
    private func travels(feedKey: String) -> Bool? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: "feedAuth.\(feedKey)",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any] else { return nil }
        if let flag = attrs[kSecAttrSynchronizable as String] as? Bool { return flag }
        return (attrs[kSecAttrSynchronizable as String] as? Int) == 1
    }

    @Test("die Wegewahl: Apple nur ohne Dienst-Zugang und mit Schalter")
    func theWayIsTheFactoriesQuestion() {
        #expect(PodcastFeedAuth.travelsOverApple(syncEnabled: true, serviceAccess: false), "ohne Dienst und mit Schalter: Apple")
        #expect(!PodcastFeedAuth.travelsOverApple(syncEnabled: true, serviceAccess: true), "mit Dienst nie Apple, auch mit Schalter")
        #expect(!PodcastFeedAuth.travelsOverApple(syncEnabled: false, serviceAccess: false), "ohne Schalter nirgends")
        #expect(!PodcastFeedAuth.travelsOverApple(syncEnabled: false, serviceAccess: true))
    }

    @Test("das Umschreiben schreibt jeden Eintrag mit dem Weg der Gegenwart, zaehlt Fehlschlaege und tut ohne Auflistung nichts")
    func rewriteWritesEveryEntryAndDoesNothingWithoutAListing() {
        var written: [(String, String, String)] = []
        let outcome = PodcastFeedAuth.rewriteAll(by: "witness",
                                                 entries: ["feedAuth.a": "ua\npa", "feedAuth.b": "ub\npb", "feedAuth.broken": "no separator"],
                                                 writing: { written.append(($0, $1, $2)); return $0 != "b" })
        #expect(outcome.rewritten == 1 && outcome.failed == 1, "one landed, one failed, the broken one is skipped")
        #expect(Set(written.map(\.0)) == ["a", "b"], "the prefix is stripped, the feed key is what is written")
        #expect(written.first { $0.0 == "a" }.map { ($0.1, $0.2) } ?? ("", "") == ("ua", "pa"))
        var calls = 0
        let none = PodcastFeedAuth.rewriteAll(by: "witness", entries: nil, writing: { _, _, _ in calls += 1; return true })
        #expect(none == (0, 0) && calls == 0, "a keychain that could not be listed is left alone")
    }

    /// The whole way on the real keychain: with the switch on and no
    /// service a credential travels; the sign-in rewrites it as local and
    /// writes new ones local; the sign-out brings them back to Apple. The
    /// moments are never touched.
    @Test("Anmeldung schreibt die Zugaenge lokal um, Abmeldung zurueck zu Apple; kein Moment geht verloren") @MainActor
    func signInAndSignOutRewriteTheCredentials() throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        #expect(AppStorageKeys.syncAcrossDevicesEnabled, "ohne den Schalter misst der Fall nichts")
        // The host's own service access, if any, is put back afterwards.
        let heldURL = AppStorageKeys.maerSyncURLValue, heldOwner = AppStorageKeys.maerSyncOwnerValue
        let heldToken = AppStorageKeys.maerSyncTokenValue
        try #require(MaerSyncAccess.stored() == nil, "der Test-Wirt traegt einen Dienst-Zugang; der Fall braucht keinen als Ausgang")
        let suiteName = "feed-auth-way-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let run = UUID().uuidString.prefix(8)
        let first = "way-\(run)-first", second = "way-\(run)-second"
        defer {
            PodcastFeedAuth.remove(feedKey: first)
            PodcastFeedAuth.remove(feedKey: second)
            AppStorageKeys.maerSyncURLValue = heldURL
            AppStorageKeys.maerSyncOwnerValue = heldOwner
            AppStorageKeys.setMaerSyncToken(heldToken)
            MaerSyncCarriers.session.reloadAccess()
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Without a service: the credential travels over Apple.
        PodcastFeedAuth.set(feedKey: first, user: "u1", password: "p1", now: Date(timeIntervalSince1970: 1_700_000_000), defaults: defaults)
        try #require(travels(feedKey: first) == true, "the precondition: with the switch on and no service the item is synchronizable")
        let stampsBefore = defaults.dictionary(forKey: PodcastFeedAuth.stampsKey) as? [String: Double]

        // The sign-in stores the access and rewrites: the twin at Apple is gone.
        MaerSyncSignIn.store(MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "probe-token"), owner: "probe")
        #expect(MaerSyncAccess.stored() != nil)
        #expect(travels(feedKey: first) == false, "after the sign-in the credential is a local item")
        #expect(PodcastFeedAuth.credentials(feedKey: first).map { $0.user + $0.password } == "u1p1", "the secret is the same")
        #expect(defaults.dictionary(forKey: PodcastFeedAuth.stampsKey) as? [String: Double] == stampsBefore, "no moment moved")
        // A credential written WITH the service stays local (a).
        PodcastFeedAuth.set(feedKey: second, user: "u2", password: "p2", defaults: defaults)
        #expect(travels(feedKey: second) == false, "with a service nothing of this class travels over Apple")

        // The sign-out is the way back: the switch is on, so both go to Apple (c).
        MaerSyncSignIn.signOut()
        #expect(MaerSyncAccess.stored() == nil)
        #expect(travels(feedKey: first) == true && travels(feedKey: second) == true, "after the sign-out the credentials travel over Apple again")
        #expect(PodcastFeedAuth.credentials(feedKey: second).map { $0.user + $0.password } == "u2p2")
    }

    /// The two occasions call the rewrite, named: a fence over the file,
    /// so a sign-in or sign-out that forgets the rewrite is red here and
    /// not only on a device with old twins.
    @Test("die Anmeldung und die Abmeldung rufen das Umschreiben, je beim Namen")
    func bothOccasionsCallTheRewrite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncSignIn.swift"), encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(code.contains("PodcastFeedAuth.rewriteAll(by: \"sign-in\")"), "the sign-in does not rewrite")
        #expect(code.contains("PodcastFeedAuth.rewriteAll(by: \"sign-out\")"), "the sign-out does not rewrite")
    }
}
#endif
