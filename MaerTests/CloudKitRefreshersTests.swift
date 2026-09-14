// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The register of the running CloudKit carriers: a push that names a zone
/// wakes that zone's carrier alone, a push without a zone (or with one
/// nobody registered) wakes every carrier, a carrier that is gone is a
/// skipped entry. And the fence: every CloudKit carrier signs in, and the
/// two occasions that are not the start (push, scene active) ask the
/// register instead of naming the pot.
@MainActor
struct CloudKitRefreshersTests {
    private final class Probe {
        var calls: [String] = []
    }

    private func withSwitchOn(_ body: () async throws -> Void) async rethrows {
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        try await body()
    }

    @Test("eine Zone weckt nur ihren Traeger; ohne Zone oder mit fremder Zone holen alle")
    func aZoneWakesItsCarrierAloneAndNoZoneWakesAll() async {
        let stats = Probe(), lists = Probe(), choices = Probe()
        CloudKitRefreshers.register(stats, zone: "probe-stats") { stats.calls.append($0) }
        CloudKitRefreshers.register(lists, zone: "probe-playlists") { lists.calls.append($0) }
        CloudKitRefreshers.register(choices, zone: "probe-choices") { choices.calls.append($0) }
        await withSwitchOn {
            let one = await CloudKitRefreshers.refresh(zone: "probe-playlists", by: "push")
            #expect(one == 1, "a named zone asks exactly its carrier")
            #expect(lists.calls == ["push"])
            #expect(stats.calls.isEmpty && choices.calls.isEmpty, "the other zones stay quiet")

            let all = await CloudKitRefreshers.refreshAll(by: "scene active")
            #expect(all >= 3, "every living carrier is asked")
            #expect(stats.calls == ["scene active"])
            #expect(lists.calls == ["push", "scene active"])
            #expect(choices.calls == ["scene active"])

            let alien = await CloudKitRefreshers.refresh(zone: "probe-nobody", by: "push")
            #expect(alien >= 3, "a zone nobody registered wakes every carrier")
            #expect(stats.calls.last == "push" && choices.calls.last == "push")
        }
        // The probes stay alive until here on purpose: the entries are weak.
        withExtendedLifetime((stats, lists, choices)) {}
    }

    @Test("ein verschwundener Traeger faellt aus dem Register; der Schalter aus fragt niemanden")
    func aGoneCarrierIsSkippedAndTheSwitchOffAsksNobody() async {
        do {
            let gone = Probe()
            // Weak like the carriers' own closures: a strong capture here
            // would keep the probe alive and prove nothing about the register.
            CloudKitRefreshers.register(gone, zone: "probe-gone") { [weak gone] in gone?.calls.append($0) }
            #expect(CloudKitRefreshers.zones.contains("probe-gone"))
        }
        #expect(!CloudKitRefreshers.zones.contains("probe-gone"), "a released carrier leaves the register")

        let stays = Probe()
        CloudKitRefreshers.register(stays, zone: "probe-stays") { stays.calls.append($0) }
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.podcastICloudSync)
        let asked = await CloudKitRefreshers.refreshAll(by: "push")
        if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
        else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        #expect(asked == 0 && stays.calls.isEmpty, "the one iCloud switch is honoured here once")
        withExtendedLifetime(stays) {}
    }

    /// The fence: the next carrier cannot be forgotten by the push and the
    /// scene, because both ask the register, and every carrier signs in.
    @Test("jeder CloudKit-Traeger meldet sich an; Push und Szene fragen das Register")
    func everyCarrierRegistersAndBothOccasionsAskTheRegister() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let networking = root.appendingPathComponent("Sources/Networking")
        let carriers = try FileManager.default.contentsOfDirectory(at: networking, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("CloudKit") && $0.lastPathComponent.hasSuffix("Carrier.swift") }
        try #require(carriers.count >= 4, "the finder must still find the four carriers")
        for file in carriers {
            let code = try String(contentsOf: file, encoding: .utf8)
            #expect(code.contains("CloudKitRefreshers.register("),
                    "\(file.lastPathComponent) does not sign in: push and scene would miss it")
        }
        let app = try String(contentsOf: root.appendingPathComponent("Sources/MaerApp.swift"), encoding: .utf8)
        #expect(app.contains("CloudKitRefreshers.refresh(zone:"), "the push handler asks the register")
        #expect(!app.contains("PodcastCloudSync.shared.pull(by: \"push\")"), "the push handler names the pot alone")
        let housekeeping = try String(contentsOf: root.appendingPathComponent("Sources/ViewModels/AppHousekeeping.swift"),
                                      encoding: .utf8)
        #expect(housekeeping.contains("CloudKitRefreshers.refreshAll(by: \"scene active\")"),
                "the scene coming back asks the register")
    }
}
#endif
