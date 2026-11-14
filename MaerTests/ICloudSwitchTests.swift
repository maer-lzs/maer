// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The visible iCloud switch: with Mär Sync set up it is visibly off
/// and locked, with a sentence and a way to the Mär Sync page; without Mär Sync it is
/// the one switch. Never do both carry.
@MainActor
struct ICloudSwitchTests {
    @Test("The states: free without the service, locked with the service")
    func theStates() {
        #expect(ICloudSwitch.state(serviceConfigured: false) == .free)
        #expect(ICloudSwitch.state(serviceConfigured: true) == .lockedServiceCarries)
    }

    @Test("Mär Sync set up: no carrier writes to iCloud, and the switch stands off and locked")
    func theServiceCarriesEverything() throws {
        let access = MaerSyncAccess(baseURL: try #require(URL(string: "https://sync.example.test")), token: "a-token")
        #expect(StandCarriers.make(access: access) is MaerSyncStandCarrier)
        #expect(ClaimCarriers.make(access: access) is MaerSyncClaimCarrier)
        #expect(StatsCarriers.make(access: access) is MaerSyncStatsCarrier)
        #expect(ChoiceCarriers.make(access: access) is MaerSyncChoiceCarrier)
        #expect(PlaylistCarriers.make(access: access) is MaerSyncPlaylistCarrier)
        #expect(ICloudSwitch.state(serviceConfigured: true) == .lockedServiceCarries)
    }

    @Test("The settings ask the rule, lock the row and lead to the Mär Sync page; the switch shows the lock itself", .needsTheSources)
    func theWiring() throws {
        func flat(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let settings = try flat("Sources/Views/SettingsView.swift")
        #expect(settings.contains("ICloudSwitch.state(serviceConfigured:maerSyncConfigured)"))
        #expect(settings.contains("AppSwitch(isOn:.constant(false))"))
        #expect(settings.contains(".disabled(true).accessibilityIdentifier(\"icloud-switch\")"))
        #expect(settings.contains("NavigationLink{MaerSyncSettingsView()}label:{Text(\"iCloudisoffbecauseMärSynccarriesyourdata."))
        let component = try flat("Sources/Views/AppSwitch.swift")
        #expect(component.contains("@Environment(\\.isEnabled)"))
        #expect(component.contains(".opacity(isEnabled?1:AppSwitch.lockedOpacity)"))
    }
}
#endif
