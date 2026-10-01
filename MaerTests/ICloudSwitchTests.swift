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
        #expect(ICloudSwitch.state(serviceConfigured: false, anyCarrierHoldsICloud: true) == .free)
        #expect(ICloudSwitch.state(serviceConfigured: true, anyCarrierHoldsICloud: false) == .lockedServiceCarries)
        #expect(ICloudSwitch.state(serviceConfigured: true, anyCarrierHoldsICloud: true) == .lockedFromNextStart)
        #expect(ICloudSwitch.state(serviceConfigured: false, anyCarrierHoldsICloud: false) == .free,
                "signed out: iCloud is the way again, the service page names the stall until the restart")
    }

    @Test("Mär Sync eingerichtet und noch kein Traeger gebaut: der Schalter sagt 'Mär Sync traegt', nicht 'ab dem naechsten Start'")
    func nothingBuiltYetReadsAsTheServiceCarrying() {
        CarrierChoices.forgetForTesting()
        defer { CarrierChoices.forgetForTesting() }
        #expect(!CarrierChoices.anyHoldsICloud, "nothing built holds iCloud")
        #expect(ICloudSwitch.state(serviceConfigured: true, anyCarrierHoldsICloud: CarrierChoices.anyHoldsICloud)
                == .lockedServiceCarries)
        CarrierChoices.note(service: true)
        #expect(ICloudSwitch.state(serviceConfigured: true, anyCarrierHoldsICloud: CarrierChoices.anyHoldsICloud)
                == .lockedServiceCarries)
        CarrierChoices.note(service: false)
        #expect(ICloudSwitch.state(serviceConfigured: true, anyCarrierHoldsICloud: CarrierChoices.anyHoldsICloud)
                == .lockedFromNextStart, "one runner built before the sign-in still holds iCloud")
    }

    @Test("Mär Sync eingerichtet: kein Traeger schreibt nach iCloud, und der Schalter steht aus und gesperrt")
    func theServiceCarriesEverything() throws {
        let access = MaerSyncAccess(baseURL: try #require(URL(string: "https://sync.example.test")), token: "a-token")
        #expect(StandCarriers.make(access: access) is MaerSyncStandCarrier)
        #expect(ClaimCarriers.make(access: access) is MaerSyncClaimCarrier)
        #expect(StatsCarriers.make(access: access) is MaerSyncStatsCarrier)
        #expect(ChoiceCarriers.make(access: access) is MaerSyncChoiceCarrier)
        #expect(PlaylistCarriers.make(access: access) is MaerSyncPlaylistCarrier)
        #expect(ICloudSwitch.state(serviceConfigured: true, anyCarrierHoldsICloud: false) == .lockedServiceCarries)
    }

    @Test("Die Einstellungen fragen die Regel, sperren die Zeile und fuehren zur Mär-Sync-Seite; der Schalter zeigt die Sperre selbst", .needsTheSources)
    func theWiring() throws {
        func flat(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let settings = try flat("Sources/Views/SettingsView.swift")
        #expect(settings.contains("ICloudSwitch.state(serviceConfigured:maerSyncConfigured,anyCarrierHoldsICloud:CarrierChoices.anyHoldsICloud)"))
        #expect(settings.contains("AppSwitch(isOn:.constant(false))"))
        #expect(settings.contains(".disabled(true).accessibilityIdentifier(\"icloud-switch\")"))
        #expect(settings.contains("NavigationLink{MaerSyncSettingsView()}label:{Text(iCloud==.lockedServiceCarries"))
        let component = try flat("Sources/Views/AppSwitch.swift")
        #expect(component.contains("@Environment(\\.isEnabled)"))
        #expect(component.contains(".opacity(isEnabled?1:AppSwitch.lockedOpacity)"))
    }
}
#endif
