// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Adresse des Mär Sync reist zum Zweitgeraet als Vorschlag unter dem
/// Feld, statt dort von Hand getippt zu werden. Nur die Adresse: das Token
/// und das Passwort betreten das Register nie, und das Zweitgeraet
/// verbindet sich nicht von selbst.
@MainActor
struct MaerSyncAddressTravelTests {

    private func device(_ cloud: UserChoiceFakeCloud, now: Double)
        -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "maer-sync-address-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud,
                                       syncEnabled: { true },
                                       now: { clock += 1; return clock })
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

    @Test("A meldet sich an, B bekommt die Adresse als Vorschlag, kein Zugangswert reist, B verbindet nichts")
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
        // Kein Zugangswert: weder im Register noch irgendwo in der Wolke.
        let data = b.defaults.data(forKey: KnownServers.storeKey) ?? Data()
        #expect(!String(decoding: data, as: UTF8.self).contains(token))
        let wolke = blob(cloud)
        #expect(wolke.keys.contains("knownServer.maerSync|https://sync.example.net"))
        for (key, value) in wolke {
            #expect(!key.contains(token) && !"\(value)".contains(token), "Token in der Wolke: \(key)")
        }

        // Eingeschwungen: B schreibt nichts zurueck, A auch nicht.
        let vorher = blob(cloud)
        b.sync.noteKnownServers()
        b.sync.reconcile()
        a.sync.reconcile()
        #expect(NSDictionary(dictionary: vorher).isEqual(to: blob(cloud)))
    }

    /// So liest ein Geraet mit Build 47 den neuen Dienst: als unbekannten.
    /// Der Eintrag reist einzeln, also bleibt er dort liegen, ohne Stempel
    /// und ohne die bekannten Eintraege mitzureissen; das Register des
    /// alten Geraets bleibt lesbar.
    @Test("Ein unbekannter Dienst im Register der Wolke nimmt einem aelteren Geraet nichts")
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

    @Test("Die Anmeldung merkt die Adresse, das Feld bietet sie an")
    func wiring() throws {
        let anmeldung = try sourceText("Sources/Networking/MaerSyncSignIn.swift")
        let store = try #require(anmeldung.range(of: "static func store(_ access: MaerSyncAccess"))
        let body = String(anmeldung[store.upperBound...].prefix(600))
        #expect(body.contains("rememberAddress(access)"), "store merkt die Adresse nicht")
        #expect(anmeldung.contains("KnownServers.remember(access.baseURL.absoluteString, service: .maerSync"))
        let seite = try sourceText("Sources/Views/MaerSyncSettingsView.swift")
        #expect(seite.contains("id: \"maer-sync-url\",\n                                          service: .maerSync)"))
    }
}
#endif
