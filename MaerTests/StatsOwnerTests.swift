// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The listening totals follow the account (decision of 03.10.2026, a new
/// beginning): what the device heard under A stays A's, B starts at zero,
/// each account publishes only its own, and the device's rows lose nothing.
@MainActor
struct StatsOwnerTests {
    /// One set of pots per account.
    private final class AccountCarrier: StatsCarrier {
        var name: String { "accounts" }
        let scope: () -> String?
        var byAccount: [String: [String: ListeningStatsData]] = [:]
        init(scope: @escaping () -> String?) { self.scope = scope }
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {
            byAccount[scope() ?? "-", default: [:]][deviceId] = pot
        }
        func pots() -> [String: ListeningStatsData] { byAccount[scope() ?? "-"] ?? [:] }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
        var hasRoomLimit: Bool { false }
    }

    private struct Rig {
        let folder: URL
        var database: MaerDatabase { MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path) }
        var shelf: RestingShelf { database.restingShelf! }
    }

    private func rig() throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stats-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Rig(folder: folder)
    }

    private func withSyncOn(_ body: () async throws -> Void) async rethrows {
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        try await body()
    }

    private var device: String { SyncHistoryStore.deviceId }

    @Test("was das Geraet unter A hoerte, bleibt A's, B beginnt bei null, jedes Konto veroeffentlicht nur seins, auch ueber einen Neustart")
    func theTotalsFollowTheAccount() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        try await withSyncOn {
            var scope: String? = "account-a"
            let carrier = AccountCarrier(scope: { scope })
            let stats = ListeningStatsStore(carrier: carrier, database: rig.database,
                                            history: ListeningStatsSyncTests.RecordingHistory(),
                                            identity: { scope }, shelf: rig.shelf)
            stats.start()
            stats.addSeconds(100, itemId: "rss:a-1")
            stats.flush()
            #expect(carrier.byAccount["account-a"]?[device]?.secondsPerItem["rss:a-1"] == 100)

            scope = "account-b"
            stats.flush()
            #expect(stats.totalSeconds() == 0, "B starts with A's listening")
            #expect(stats.seconds(forItemId: "rss:a-1") == 0)
            #expect(carrier.byAccount["account-b"]?[device]?.secondsPerItem["rss:a-1"] == nil, "A's title went to B")
            #expect((carrier.byAccount["account-b"]?[device]?.secondsPerDay.values.reduce(0, +) ?? 0) == 0, "A's days went to B")
            #expect(carrier.byAccount["account-a"]?[device]?.secondsPerItem["rss:a-1"] == 100, "A's pot changed")

            stats.addSeconds(30, itemId: "rss:b-1")
            stats.flush()
            #expect(stats.totalSeconds() == 30)
            #expect(carrier.byAccount["account-b"]?[device]?.secondsPerItem["rss:b-1"] == 30)

            scope = "account-a"
            stats.flush()
            #expect(stats.totalSeconds() == 100, "A's totals did not come back as they were")
            #expect(stats.seconds(forItemId: "rss:a-1") == 100 && stats.seconds(forItemId: "rss:b-1") == 0)
            #expect(carrier.byAccount["account-a"]?[device]?.secondsPerItem["rss:b-1"] == nil, "B's title went to A")

            // The device's rows lose nothing; a new start on them and the
            // ledger shows A's totals again.
            await stats.awaitPendingWrites()
            let again = ListeningStatsStore(carrier: carrier, database: rig.database,
                                            history: ListeningStatsSyncTests.RecordingHistory(),
                                            identity: { scope }, shelf: rig.shelf)
            #expect(again.ownData.secondsPerItem == ["rss:a-1": 100, "rss:b-1": 30], "the device's rows changed")
            #expect(again.totalSeconds() == 100)
        }
    }

    @Test("ist das Hauptbuch nicht lesbar, wird nichts uebergeben und nichts veroeffentlicht")
    func anUnreadLedgerHoldsThePublish() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        try await withSyncOn {
            let shelf = rig.shelf
            try shelf.setHolding(.init(owner: "account-a"), of: "stats")
            let ledger = shelf.directory.appendingPathComponent("statsLedger").appendingPathComponent("device.json")
            try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a ledger".utf8).write(to: ledger)
            var scope: String? = "account-b"
            let carrier = AccountCarrier(scope: { scope })
            let stats = ListeningStatsStore(carrier: carrier, database: rig.database,
                                            history: ListeningStatsSyncTests.RecordingHistory(),
                                            identity: { scope }, shelf: shelf)
            stats.addSeconds(50, itemId: "rss:a-1")
            stats.start()
            stats.flush()
            #expect(carrier.byAccount["account-b"] == nil, "a pot went up without its ledger")
            let holding = try shelf.holding(of: "stats")
            #expect(holding == .init(owner: "account-a"))
            scope = nil
        }
    }

    @Test("ein offenes Ersetzen eines frueheren Laufs und ein drittes Konto: B's Ruhe traegt keine Hoerzeit von A, A's bleibt bei A")
    func aThirdAccountAfterAnOpenReplacement() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        try await withSyncOn {
            let shelf = rig.shelf
            let restOfA = ListeningStatsData(secondsPerDay: ["d1": 100], secondsPerItem: ["rss:a-1": 100])
            let restOfB = ListeningStatsData(secondsPerDay: ["d0": 7], secondsPerItem: ["rss:b-1": 7])
            try shelf.lay(restOfA, of: "stats", owner: "account-a")
            try shelf.lay(restOfB, of: "stats", owner: "account-b")
            try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "open"), of: "stats")
            let carrier = AccountCarrier(scope: { "account-c" })
            let stats = ListeningStatsStore(carrier: carrier, database: rig.database,
                                            history: ListeningStatsSyncTests.RecordingHistory(),
                                            identity: { "account-c" }, shelf: shelf)
            // The device holds A's listening from before the switch.
            stats.addSeconds(100, itemId: "rss:a-1")
            stats.start()
            stats.flush()
            #expect(try shelf.rest(ListeningStatsData.self, of: "stats", owner: "account-b") == restOfB,
                    "A's listening was laid as B's")
            #expect(try shelf.rest(ListeningStatsData.self, of: "stats", owner: "account-a") == restOfA)
            #expect(carrier.byAccount["account-c"]?[device]?.secondsPerItem["rss:a-1"] == nil, "C published A's listening")
            await stats.awaitPendingWrites()
        }
    }

    @Test("die Rechnung: Mitgebrachtes plus was das Geraet seit der Uebernahme zaehlte, nie unter null")
    func theOwnedTotals() {
        let device = ListeningStatsData(secondsPerDay: ["d1": 130, "d2": 10], secondsPerItem: ["a": 100, "b": 30])
        let since = ListeningStatsData(secondsPerDay: ["d1": 100], secondsPerItem: ["a": 100])
        let carried = ListeningStatsData(secondsPerDay: ["d0": 7], secondsPerItem: ["c": 5])
        let owned = ListeningStatsSync.owned(device: device, carried: carried, since: since)
        #expect(owned.secondsPerDay == ["d0": 7, "d1": 30, "d2": 10])
        #expect(owned.secondsPerItem == ["c": 5, "b": 30])
        #expect(ListeningStatsSync.owned(device: device, carried: .init(), since: .init()) == device,
                "before the first change of account the device's totals are the account's")
        let shrunk = ListeningStatsSync.owned(device: ListeningStatsData(secondsPerDay: ["d1": 5]), carried: .init(), since: since)
        #expect(shrunk.secondsPerDay.isEmpty, "a key below its base counts as none, never negative")
    }
}
#endif
