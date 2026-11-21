// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// iOS refused Mär the local network: a server at home answers "offline"
/// while the device is online. The app says so in its own sentence, and the
/// server forms offer the way to the settings.
struct LocalNetworkAccessTests {
    @Test("a local address: private ranges, link-local, .local names; a public one and loopback are none")
    func whatIsLocal() {
        for host in ["192.168.1.5", "10.0.0.2", "172.16.3.4", "172.31.255.1", "169.254.1.1", "nas.local", "NAS.LOCAL", "fe80::1", "fd12::3"] {
            #expect(LocalNetworkAccess.isLocal(host: host), "\(host)")
        }
        for host in ["172.32.0.1", "8.8.8.8", "example.org", "127.0.0.1", "localhost", "local.example.org", "", nil] as [String?] {
            #expect(!LocalNetworkAccess.isLocal(host: host), "\(host ?? "nil")")
        }
    }

    @Test("refused: a local server answers offline while the device is online; nothing else counts")
    func whatIsRefused() {
        #expect(LocalNetworkAccess.isDenied(host: "192.168.1.5", code: .notConnectedToInternet, deviceOnline: true))
        #expect(!LocalNetworkAccess.isDenied(host: "192.168.1.5", code: .notConnectedToInternet, deviceOnline: false), "the device is offline")
        #expect(!LocalNetworkAccess.isDenied(host: "example.org", code: .notConnectedToInternet, deviceOnline: true), "not local")
        #expect(!LocalNetworkAccess.isDenied(host: "192.168.1.5", code: .timedOut, deviceOnline: true), "a server that is off")
        #expect(!LocalNetworkAccess.isDenied(host: "192.168.1.5", code: .cannotConnectToHost, deviceOnline: true), "a server that refuses")
    }

    @Test("the sentence has its words in English and German, and every server form takes it", .needsTheSources)
    func theSentenceStands() throws {
        let english = "Mär may not reach devices on your local network. Allow it in Settings under Mär, Local Network."
        #expect(LocalNetworkAccess.sentence == String(localized: String.LocalizationValue(english)))
        let catalog = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"), encoding: .utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        let entry = try #require(strings[english] as? [String: Any])
        let german = ((entry["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(german?["value"] as? String
                == "Mär darf keine Geräte im lokalen Netzwerk erreichen. Erlaube es in den Einstellungen unter Mär, Lokales Netzwerk.")
        let guardCode = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/AccessGuard.swift"), encoding: .utf8))
        #expect(guardCode.contains("LocalNetworkAccess.isDenied("), "the forms' one sentence does not ask the rule")
        for form in ["Sources/Views/SetupView.swift", "Sources/Views/SubsonicSourceView.swift", "Sources/Views/JellyfinSourceView.swift"] {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(form), encoding: .utf8))
            #expect(code.contains("LocalNetworkSettingsButton("), "\(form) offers no way to the settings")
        }
    }
}
#endif
