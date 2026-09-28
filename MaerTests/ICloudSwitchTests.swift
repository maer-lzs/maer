// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Der sichtbare iCloud-Schalter: mit eingerichtetem Mär Sync sichtbar aus
/// und gesperrt, mit Satz und Weg zur Mär-Sync-Seite; ohne Mär Sync ist er
/// der eine Schalter. Nie tragen beide.
@MainActor
struct ICloudSwitchTests {
    @Test("Die Zustaende: frei ohne Dienst, gesperrt mit Dienst, ab dem naechsten Start nach einer Anmeldung im Lauf")
    func theStates() {
        #expect(ICloudSwitch.state(serviceConfigured: false, allTravelTheService: false) == .free)
        #expect(ICloudSwitch.state(serviceConfigured: true, allTravelTheService: true) == .lockedServiceCarries)
        #expect(ICloudSwitch.state(serviceConfigured: true, allTravelTheService: false) == .lockedFromNextStart)
        #expect(ICloudSwitch.state(serviceConfigured: false, allTravelTheService: true) == .free,
                "signed out: iCloud is the way again, the service page names the stall until the restart")
    }

    @Test("Mär Sync eingerichtet: kein Traeger schreibt nach iCloud, und der Schalter steht aus und gesperrt")
    func theServiceCarriesEverything() throws {
        let access = MaerSyncAccess(baseURL: try #require(URL(string: "https://sync.example.test")), token: "a-token")
        #expect(StandCarriers.make(access: access) is MaerSyncStandCarrier)
        #expect(ClaimCarriers.make(access: access) is MaerSyncClaimCarrier)
        #expect(StatsCarriers.make(access: access) is MaerSyncStatsCarrier)
        #expect(ChoiceCarriers.make(access: access) is MaerSyncChoiceCarrier)
        #expect(PlaylistCarriers.make(access: access) is MaerSyncPlaylistCarrier)
        #expect(ICloudSwitch.state(serviceConfigured: true, allTravelTheService: true) == .lockedServiceCarries)
    }

    @Test("Die Einstellungen fragen die Regel, sperren die Zeile und fuehren zur Mär-Sync-Seite; der Schalter zeigt die Sperre selbst", .needsTheSources)
    func theWiring() throws {
        func flat(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let settings = try flat("Sources/Views/SettingsView.swift")
        #expect(settings.contains("ICloudSwitch.state(serviceConfigured:maerSyncConfigured,allTravelTheService:CarrierChoices.allTravelTheService)"))
        #expect(settings.contains("AppSwitch(isOn:.constant(false))"))
        #expect(settings.contains(".disabled(true).accessibilityIdentifier(\"icloud-switch\")"))
        #expect(settings.contains("NavigationLink{MaerSyncSettingsView()}label:{Text(iCloud==.lockedServiceCarries"))
        let component = try flat("Sources/Views/AppSwitch.swift")
        #expect(component.contains("@Environment(\\.isEnabled)"))
        #expect(component.contains(".opacity(isEnabled?1:AppSwitch.lockedOpacity)"))
    }
}
#endif
