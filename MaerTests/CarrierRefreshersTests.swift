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
struct CarrierRefreshersTests {
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
    func aZoneWakesItsCarrierAloneAndNoZoneWakesAll() async throws {
        try #require(CarrierRefreshers.zones.isEmpty,
                     "ein frueherer Fall hat seine Probe stehen lassen: \(CarrierRefreshers.zones)")
        let stats = Probe(), lists = Probe(), choices = Probe()
        // Das Register lebt ueber die Faelle hinweg. Eine Probe, die stehen
        // bleibt, zaehlt im naechsten Fall mit, und genau das hat die Zusage
        // „fragt niemanden" zu einer geliehenen Zahl gemacht.
        defer { for probe in [stats, lists, choices] { CarrierRefreshers.unregister(probe) } }
        CarrierRefreshers.register(stats, zone: "probe-stats", gate: { true }) { stats.calls.append($0) }
        CarrierRefreshers.register(lists, zone: "probe-playlists", gate: { true }) { lists.calls.append($0) }
        CarrierRefreshers.register(choices, zone: "probe-choices", gate: { true }) { choices.calls.append($0) }
        await withSwitchOn {
            let one = await CarrierRefreshers.refresh(zone: "probe-playlists", by: "push")
            #expect(one == 1, "a named zone asks exactly its carrier")
            #expect(lists.calls == ["push"])
            #expect(stats.calls.isEmpty && choices.calls.isEmpty, "the other zones stay quiet")

            let all = await CarrierRefreshers.refreshAll(by: "scene active")
            #expect(all == 3, "genau die drei Proben werden gefragt, keine fremde daneben")
            #expect(stats.calls == ["scene active"])
            #expect(lists.calls == ["push", "scene active"])
            #expect(choices.calls == ["scene active"])

            let alien = await CarrierRefreshers.refresh(zone: "probe-nobody", by: "push")
            #expect(alien == 3, "eine Zone, die niemand angemeldet hat, weckt genau alle drei")
            #expect(stats.calls.last == "push" && choices.calls.last == "push")
        }
        // The probes stay alive until here on purpose: the entries are weak.
        withExtendedLifetime((stats, lists, choices)) {}
    }

    @Test("ein verschwundener Traeger faellt aus dem Register; der ausgeschaltete iCloud-Schalter fragt keinen CloudKit-Traeger")
    func aGoneCarrierIsSkippedAndTheSwitchOffAsksNoCloudKitCarrier() async throws {
        // Voraussetzung, zugesichert statt angenommen: das Register ist leer.
        // Sonst zaehlt die Rueckgabezahl unten fremde Proben mit und die
        // Zusage waere wieder geliehen.
        try #require(CarrierRefreshers.zones.isEmpty,
                     "ein frueherer Fall hat seine Probe stehen lassen: \(CarrierRefreshers.zones)")
        do {
            let gone = Probe()
            // Weak like the carriers' own closures: a strong capture here
            // would keep the probe alive and prove nothing about the register.
            CarrierRefreshers.register(gone, zone: "probe-gone", gate: { true }) { [weak gone] in gone?.calls.append($0) }
            #expect(CarrierRefreshers.zones.contains("probe-gone"))
        }
        #expect(!CarrierRefreshers.zones.contains("probe-gone"), "a released carrier leaves the register")

        // Der iCloud-Schalter ist nicht mehr die Frage des Registers, sondern
        // das Tor der CloudKit-Traeger; ein Traeger mit diesem Tor schweigt
        // also weiter, wenn der Schalter aus ist. Die Zusage „fragt niemanden"
        // waere nach dem Dienst-Eintrag falsch, denn der haengt nicht daran.
        let stays = Probe()
        defer { CarrierRefreshers.unregister(stays) }
        CarrierRefreshers.register(stays, zone: "probe-stays",
                                   gate: { AppStorageKeys.podcastICloudSyncEnabled }) { stays.calls.append($0) }
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        // Restored on every way out, not only the straight one: a process
        // wide default that stays flipped poisons every case after this one.
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        UserDefaults.standard.set(false, forKey: AppStorageKeys.podcastICloudSync)
        let asked = await CarrierRefreshers.refreshAll(by: "push")
        // Jetzt traegt die Zahl wieder: das Register war zu Beginn leer und
        // diese Probe ist die einzige darin. Der Traeger haengt am
        // iCloud-Schalter, also fragt der ausgeschaltete Schalter niemanden.
        // Ein Traeger mit eigenem Tor, etwa der Dienst, bliebe davon
        // unberuehrt; das steht als eigener Fall daneben.
        #expect(asked == 0, "mit ausgeschaltetem Schalter wurde jemand gefragt")
        #expect(stays.calls.isEmpty, "der ausgeschaltete iCloud-Schalter haelt seinen Traeger zurueck")
        withExtendedLifetime(stays) {}
    }

    /// The fence: the next carrier cannot be forgotten by the push and the
    /// scene, because both ask the register, and every carrier signs in.
    @Test("jeder Traeger meldet sich an, auch der Dienst; Push und Szene fragen das Register")
    func everyCarrierRegistersAndBothOccasionsAskTheRegister() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let networking = root.appendingPathComponent("Sources/Networking")
        let carriers = try FileManager.default.contentsOfDirectory(at: networking, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("CloudKit") && $0.lastPathComponent.hasSuffix("Carrier.swift") }
        try #require(carriers.count >= 4, "the finder must still find the four carriers")
        for file in carriers {
            let code = try String(contentsOf: file, encoding: .utf8)
            #expect(code.contains("CarrierRefreshers.register("),
                    "\(file.lastPathComponent) does not sign in: push and scene would miss it")
        }
        let app = try String(contentsOf: root.appendingPathComponent("Sources/MaerApp.swift"), encoding: .utf8)
        #expect(app.contains("CarrierRefreshers.refresh(zone:"), "the push handler asks the register")
        #expect(!app.contains("PodcastCloudSync.shared.pull(by: \"push\")"), "the push handler names the pot alone")
        let housekeeping = try String(contentsOf: root.appendingPathComponent("Sources/ViewModels/AppHousekeeping.swift"),
                                      encoding: .utf8)
        #expect(housekeeping.contains("CarrierRefreshers.refreshAll(by: \"scene active\")"),
                "the scene coming back asks the register")

        // The service is a carrier too. It reached the other device only at
        // its next cold start while it stood outside this register (T39), so
        // the fence now covers the class and not the CloudKit half of it.
        let service = try String(contentsOf: networking.appendingPathComponent("MaerSyncCarriers.swift"),
                                 encoding: .utf8)
        #expect(service.contains("CarrierRefreshers.register(self, zone: Self.serviceZone"),
                "the service session does not sign in: the scene coming back would miss it")
    }

    /// Every entry brings its own gate, because the switches differ. The
    /// register asked the iCloud switch for everyone while it served CloudKit
    /// alone; the service carrier behind that gate would fall silent exactly
    /// when it is the only transport left.
    @Test("ein Traeger mit geschlossenem Tor wird nicht gefragt, die anderen schon")
    func aClosedGateSilencesOnlyItsOwnCarrier() async {
        let open = Probe(), closed = Probe()
        defer { for probe in [open, closed] { CarrierRefreshers.unregister(probe) } }
        CarrierRefreshers.register(open, zone: "probe-open", gate: { true }) { open.calls.append($0) }
        CarrierRefreshers.register(closed, zone: "probe-closed", gate: { false }) { closed.calls.append($0) }
        let asked = await CarrierRefreshers.refreshAll(by: "scene active")
        #expect(open.calls == ["scene active"])
        #expect(closed.calls.isEmpty, "ein geschlossenes Tor haelt seinen eigenen Traeger zurueck")
        #expect(asked >= 1)
        withExtendedLifetime((open, closed)) {}
    }

    /// The iCloud switch is one of those gates, no longer the register's own
    /// question: a CloudKit carrier stays quiet with the switch off, and the
    /// service carrier beside it does not care about that switch at all.
    @Test("der iCloud-Schalter schweigt die CloudKit-Traeger, nicht den Dienst")
    func theICloudSwitchSilencesTheCloudKitHalfOnly() async {
        let cloudKit = Probe(), service = Probe()
        defer { for probe in [cloudKit, service] { CarrierRefreshers.unregister(probe) } }
        CarrierRefreshers.register(cloudKit, zone: "probe-cloudkit",
                                   gate: { AppStorageKeys.podcastICloudSyncEnabled }) { cloudKit.calls.append($0) }
        CarrierRefreshers.register(service, zone: "probe-service", gate: { true }) { service.calls.append($0) }
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(false, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        await CarrierRefreshers.refreshAll(by: "scene active")
        #expect(cloudKit.calls.isEmpty, "mit ausgeschaltetem iCloud holt der CloudKit-Traeger nicht")
        #expect(service.calls == ["scene active"], "der Dienst haengt nicht am iCloud-Schalter")
        withExtendedLifetime((cloudKit, service)) {}
    }
}
#endif
