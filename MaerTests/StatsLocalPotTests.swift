// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The carrier's ceiling decides what TRAVELS, never what stays. Before:
/// `save()` cut the local item pot to the cap as soon as the carrier said
/// it had a ceiling, and the cloud carrier says that whenever it falls
/// back mid-session (the account went away); a migrated pot above the cap
/// was cut for good on the next fallback, and no channel holds those
/// seconds but the file.
@MainActor
struct StatsLocalPotTests {
    private final class FlippingCarrier: StatsCarrier {
        let name = "flip-fake"
        var hasRoomLimit = false
        let hasDeliveredFirst = true
        var published: [ListeningStatsData] = []
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) { published.append(pot) }
        func pots() -> [String: ListeningStatsData] { [:] }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    @Test("die Decke des Traegers kappt nie den LOKALEN Topf: mehr Eintraege als die Kappe, der Traeger kippt, nach dem Schreiben sind alle noch da")
    func theCeilingNeverCutsTheLocalPot() {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        #expect(AppStorageKeys.syncAcrossDevicesEnabled, "ohne den Schalter reist nichts")
        let carrier = FlippingCarrier()
        let stats = ListeningStatsStore(carrier: carrier)
        // More entries than the cap, one second each: under a cut they are
        // the first to go, whatever else the rows hold from earlier runs.
        let run = UUID().uuidString
        let ids = (0..<(ListeningStatsSync.itemPotCap + 100)).map { "cap:probe:\(run):\($0)" }
        for id in ids { stats.addSeconds(1, itemId: id) }
        let before = ids.filter { stats.ownData.secondsPerItem[$0] == 1 }.count
        #expect(before == ids.count, "the precondition: every entry is in the pot")

        // The account goes away: the carrier now has a ceiling.
        carrier.hasRoomLimit = true
        stats.flush()
        let after = ids.filter { stats.ownData.secondsPerItem[$0] == 1 }.count
        #expect(after == ids.count, "the local pot keeps every entry; the ceiling shapes only what travels")
        // What travelled: the days, and none of these items (none of them is
        // live). Asked of its own entries only: a live item another suite
        // played lies in the same rows and may travel.
        let travelled = Set(carrier.published.last?.secondsPerItem.keys.map { $0 } ?? [])
        #expect(travelled.isDisjoint(with: ids), "an entry of this case travelled")
        #expect(carrier.published.last?.secondsPerDay.isEmpty == false)
    }
}
#endif
