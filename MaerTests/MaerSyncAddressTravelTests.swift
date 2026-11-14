// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The address of Mär Sync travels to the second device as a suggestion under
/// the field, instead of being typed there by hand. Only the address: the token
/// and the password never enter the register, and the second device
/// does not connect by itself.
@MainActor
struct MaerSyncAddressTravelTests {

    private func device(_ cloud: UserChoiceFakeCloud, now: Double)
        -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "maer-sync-address-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud,
                                       syncEnabled: { true },
                                       now: { clock += 1; return clock }, idFormSettled: { true })
        return (sync, defaults, suite)
    }

    private func cleanup(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private var blob: (UserChoiceFakeCloud) -> [String: Any] {
        { $0.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:] }
    }

    @Test("A signs in, B gets the address as a suggestion, no credential travels, B connects nothing")
    func addressTravelsToTheSecondDevice() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 2000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        let token = "tok-GEHEIM-4711"
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.net")!, token: token)

        MaerSyncSignIn.rememberAddress(access, defaults: a.defaults)
        a.sync.noteKnownServers()
        b.sync.reconcile()

        let offered = KnownServers.suggestions(for: .maerSync, defaults: b.defaults)
        #expect(offered.first?.url == "https://sync.example.net")
        #expect(offered.first?.service == .maerSync)
        #expect(b.defaults.string(forKey: AppStorageKeys.maerSyncURL) == nil,
                "die Adresse wird angeboten, nicht eingerichtet")
        // No credential: neither in the register nor anywhere in the cloud.
        let data = b.defaults.data(forKey: KnownServers.storeKey) ?? Data()
        #expect(!String(decoding: data, as: UTF8.self).contains(token))
        let wolke = blob(cloud)
        #expect(wolke.keys.contains("knownServer.maerSync|https://sync.example.net"))
        for (key, value) in wolke {
            #expect(!key.contains(token) && !"\(value)".contains(token), "Token in der Wolke: \(key)")
        }

        // Settled: B writes nothing back, and neither does A.
        let vorher = blob(cloud)
        b.sync.noteKnownServers()
        b.sync.reconcile()
        a.sync.reconcile()
        #expect(NSDictionary(dictionary: vorher).isEqual(to: blob(cloud)))
    }

    /// This is how a device with Build 47 reads the new service: as unknown.
    /// The entry travels alone, so it stays there, without a stamp
    /// and without dragging the known entries along; the register of the
    /// old device stays readable.
    @Test("An unknown service in the cloud register takes nothing from an older device")
    func unknownServiceIsSkippedNotFatal() {
        let cloud = UserChoiceFakeCloud()
        let b = device(cloud, now: 2000)
        defer { cleanup(b.suite) }
        cloud.storage[UserChoiceCloudSync.blobKey] = [
            "knownServer.dienstVonMorgen|https://neu.example": UserChoiceEntry(value: .double(1_700_000_000), t: 1500).plist,
            "knownServer.subsonic|https://music.example": UserChoiceEntry(value: .double(1_700_000_000), t: 1500).plist,
        ]
        b.sync.reconcile()
        #expect(KnownServers.all(defaults: b.defaults).map(\.url) == ["https://music.example"])
        #expect(blob(cloud).keys.contains("knownServer.dienstVonMorgen|https://neu.example"),
                "der Eintrag bleibt fuer Geraete liegen, die ihn kennen")
    }

    @Test("The sign-in remembers the address, the field offers it", .needsTheSources)
    func wiring() throws {
        let anmeldung = try sourceText("Sources/Networking/MaerSyncSignIn.swift")
        let store = try #require(anmeldung.range(of: "static func store(_ access: MaerSyncAccess"))
        let body = String(anmeldung[store.upperBound...].prefix(900))
        #expect(body.contains("rememberAddress(access)"), "store merkt die Adresse nicht")
        // After the runners followed, so a change of account puts the
        // address into the new account's register, not into the resting one.
        let followed = try #require(body.range(of: "AccessFollowers.followAll(by: \"sign-in\")"))
        #expect(body[followed.upperBound...].contains("rememberAddress(access)"),
                "store merkt die Adresse, bevor die Laeufer folgen")
        #expect(anmeldung.contains("KnownServers.remember(access.baseURL.absoluteString, service: .maerSync"))
        let seite = try sourceText("Sources/Views/MaerSyncSettingsView.swift")
        #expect(seite.contains("id: \"maer-sync-url\",\n                                          service: .maerSync)"))
    }
}
#endif
