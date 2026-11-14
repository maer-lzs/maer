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
        var hasDeliveredFirst: Bool { true }
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

    @Test("what the device heard under A stays A's, B starts at zero, each account publishes only its own, also across a restart")
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

    @Test("if the ledger is not readable, nothing is handed over and nothing is published")
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

    @Test("an open replacement of an earlier run and a third account: B's rest carries no listening time of A, A's stays with A")
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

    @Test("a switch without a holder: A's listening time rests under A, B starts at zero")
    func aSwitchWithoutAHolder() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let shelf = rig.shelf
        let stats = ListeningStatsStore(carrier: AccountCarrier(scope: { "account-b" }), database: rig.database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        identity: { "account-b" }, shelf: shelf)
        stats.addSeconds(100, itemId: "rss:a-1")
        stats.followOwner(previous: "account-a")
        let restOfA = try shelf.rest(ListeningStatsData.self, of: "stats", owner: "account-a")
        #expect(restOfA?.secondsPerItem["rss:a-1"] == 100, "A's listening does not rest under A")
        #expect(stats.totalSeconds() == 0, "B starts with A's listening")
        await stats.awaitPendingWrites()
    }

    @Test("an unreadable ledger with the same holder: no foreign number shown or sent, the page says so; once readable everything runs again")
    func anUnreadLedgerShowsNoForeignNumberAndIsReadAgain() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        try await withSyncOn {
            let shelf = rig.shelf
            try shelf.setHolding(.init(owner: "account-a"), of: "stats")
            let ledgerFile = shelf.directory.appendingPathComponent("statsLedger").appendingPathComponent("device.json")
            try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a ledger".utf8).write(to: ledgerFile)
            let carrier = AccountCarrier(scope: { "account-a" })
            let stats = ListeningStatsStore(carrier: carrier, database: rig.database,
                                            history: ListeningStatsSyncTests.RecordingHistory(),
                                            identity: { "account-a" }, shelf: shelf)
            stats.addSeconds(50, itemId: "rss:a-1")
            stats.start()
            stats.flush()
            #expect(stats.ledgerUnread, "the precondition: the ledger is unread")
            #expect(stats.totalSeconds() == 0, "the device's history was shown as the account's")
            #expect(carrier.byAccount["account-a"] == nil, "a pot went up without its ledger")

            try shelf.lay(ListeningStatsStore.Ledger(), of: "statsLedger", owner: "device")
            stats.flush()
            #expect(!stats.ledgerUnread, "the ledger was not read again")
            #expect(stats.totalSeconds() == 50)
            #expect(carrier.byAccount["account-a"]?[device]?.secondsPerItem["rss:a-1"] == 50)
            await stats.awaitPendingWrites()
        }
    }

    @Test("an unreadable ledger at the start over rows with listening time: even the first read before any change shows no second of the device")
    func anUnreadLedgerShowsNothingOfTheDeviceFromTheFirstRead() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let shelf = rig.shelf
        try shelf.setHolding(.init(owner: "account-a"), of: "stats")
        let earlier = ListeningStatsStore(carrier: AccountCarrier(scope: { "account-a" }), database: rig.database,
                                          history: ListeningStatsSyncTests.RecordingHistory(),
                                          identity: { "account-a" }, shelf: shelf)
        earlier.addSeconds(80, itemId: "rss:a-1")
        await earlier.awaitPendingWrites()
        let ledgerFile = shelf.directory.appendingPathComponent("statsLedger").appendingPathComponent("device.json")
        try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a ledger".utf8).write(to: ledgerFile)

        let stats = ListeningStatsStore(carrier: AccountCarrier(scope: { "account-a" }), database: rig.database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        identity: { "account-a" }, shelf: shelf)
        #expect(stats.ledgerUnread, "the precondition: the ledger is unread")
        #expect(stats.ownData.secondsPerItem["rss:a-1"] == 80, "the precondition: the rows hold listening time")
        #expect(stats.totalSeconds() == 0, "the first read showed the device's history")
        #expect(stats.data.secondsPerItem.isEmpty, "the first read showed the device's items")
        await stats.awaitPendingWrites()
    }

    @Test("the own pot image after a reset of the rows comes back in the device's space: no double, no undercount")
    func theOwnPotComesBackInTheDevicesSpace() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        try await withSyncOn {
            let shelf = rig.shelf
            try shelf.setHolding(.init(owner: "account-b"), of: "stats")
            // B took the device over at a:100 and brought b:7; the device
            // then counted a:+30. That is what B's pot says. The rows are new.
            try shelf.lay(ListeningStatsStore.Ledger(
                carried: ListeningStatsData(secondsPerDay: ["d0": 7], secondsPerItem: ["rss:b-1": 7]),
                since: ListeningStatsData(secondsPerDay: ["d1": 100], secondsPerItem: ["rss:a-1": 100])),
                of: "statsLedger", owner: "device")
            let carrier = AccountCarrier(scope: { "account-b" })
            carrier.byAccount["account-b"] = [device: ListeningStatsData(secondsPerDay: ["d0": 7, "d1": 30],
                                                                       secondsPerItem: ["rss:b-1": 7, "rss:a-1": 30])]
            let stats = ListeningStatsStore(carrier: carrier, database: rig.database,
                                            history: ListeningStatsSyncTests.RecordingHistory(),
                                            identity: { "account-b" }, shelf: shelf)
            stats.start()
            #expect(stats.ownData.secondsPerItem == ["rss:a-1": 130], "the device's rows took the account's pot as is")
            #expect(stats.ownerPot.secondsPerItem == ["rss:b-1": 7, "rss:a-1": 30], "the account's totals changed by the way back")
            #expect(stats.ownerPot.secondsPerDay == ["d0": 7, "d1": 30])
            await stats.awaitPendingWrites()
        }
    }

    @Test("the Navidrome move also takes along the resting totals of the other accounts")
    func theRestingTotalsMoveWithTheIds() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let shelf = rig.shelf
        try shelf.lay(ListeningStatsData(secondsPerItem: ["sub:song:old": 10]), of: "stats", owner: "account-a")
        let stats = ListeningStatsStore(carrier: AccountCarrier(scope: { "account-b" }), database: rig.database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        identity: { "account-b" }, shelf: shelf)
        let moved = await stats.rekeyItems { $0 == "sub:song:old" ? "sub:song:new" : $0 }
        #expect(moved != nil)
        let rest = try shelf.rest(ListeningStatsData.self, of: "stats", owner: "account-a")
        #expect(rest?.secondsPerItem == ["sub:song:new": 10], "the resting totals kept the old id")
        await stats.awaitPendingWrites()
    }

    @Test("if the move throws at a resting total, ledger and device totals stay in the same space and nothing of the account before counts for the current one; a second run moves everything")
    func aMoveThatThrowsKeepsTheLedgerWithTheDevice() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        let shelf = rig.shelf
        try shelf.setHolding(.init(owner: "account-b"), of: "stats")
        // B took the device over at old:100 and brought old:5.
        let ledger = ListeningStatsStore.Ledger(carried: ListeningStatsData(secondsPerItem: ["sub:song:old": 5]),
                                                since: ListeningStatsData(secondsPerItem: ["sub:song:old": 100]))
        try shelf.lay(ledger, of: "statsLedger", owner: "device")
        // A's resting totals cannot be read.
        let restOfA = shelf.directory.appendingPathComponent("stats").appendingPathComponent("account-a.json")
        try FileManager.default.createDirectory(at: restOfA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a rest".utf8).write(to: restOfA)
        let stats = ListeningStatsStore(carrier: AccountCarrier(scope: { "account-b" }), database: rig.database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        identity: { "account-b" }, shelf: shelf)
        stats.addSeconds(130, itemId: "sub:song:old")
        #expect(stats.ownerPot.secondsPerItem == ["sub:song:old": 35], "the precondition: B's totals before the move")
        let map: (String) -> String = { $0 == "sub:song:old" ? "sub:song:new" : $0 }

        let held = await stats.rekeyItems(map)
        #expect(held == nil, "a move over an unreadable rest went on")
        let ledgerAfterThrow = try shelf.rest(ListeningStatsStore.Ledger.self, of: "statsLedger", owner: "device")
        #expect(ledgerAfterThrow == ledger, "the ledger moved without the device's totals")
        #expect(stats.ownData.secondsPerItem == ["sub:song:old": 130])
        #expect(stats.ownerPot.secondsPerItem == ["sub:song:old": 35], "A's listening counted for B")

        try shelf.lay(ListeningStatsData(secondsPerItem: ["sub:song:old": 100]), of: "stats", owner: "account-a")
        let moved = await stats.rekeyItems(map)
        #expect(moved != nil, "the second run held")
        let ledgerMoved = try shelf.rest(ListeningStatsStore.Ledger.self, of: "statsLedger", owner: "device")
        #expect(ledgerMoved?.since.secondsPerItem == ["sub:song:new": 100])
        #expect(stats.ownerPot.secondsPerItem == ["sub:song:new": 35], "B's totals changed by the move")
        let restMoved = try shelf.rest(ListeningStatsData.self, of: "stats", owner: "account-a")
        #expect(restMoved?.secondsPerItem == ["sub:song:new": 100])
        await stats.awaitPendingWrites()
    }

    @Test("if the ledger is not readable and no identity exists, no pot goes out, not even an empty one")
    func anUnreadLedgerHoldsThePublishWithoutAnIdentity() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.folder) }
        try await withSyncOn {
            let shelf = rig.shelf
            try shelf.setHolding(.init(owner: "account-a"), of: "stats")
            let ledger = shelf.directory.appendingPathComponent("statsLedger").appendingPathComponent("device.json")
            try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a ledger".utf8).write(to: ledger)
            let carrier = AccountCarrier(scope: { nil })
            let stats = ListeningStatsStore(carrier: carrier, database: rig.database,
                                            history: ListeningStatsSyncTests.RecordingHistory(),
                                            identity: { nil }, shelf: shelf)
            stats.addSeconds(50, itemId: "rss:a-1")
            stats.start()
            stats.flush()
            #expect(stats.ledgerUnread, "the precondition: the ledger is unread")
            #expect(carrier.byAccount.isEmpty, "a pot went up without its ledger")
            await stats.awaitPendingWrites()
        }
    }

    @Test("the way back: from the totals of the account those of the device, so that owned yields the same account again")
    func theWayBackToTheDevice() {
        let carried = ListeningStatsData(secondsPerDay: ["d0": 7], secondsPerItem: ["b": 7])
        let since = ListeningStatsData(secondsPerDay: ["d1": 100], secondsPerItem: ["a": 100])
        let device = ListeningStatsData(secondsPerDay: ["d1": 130, "d2": 5], secondsPerItem: ["a": 130, "c": 5])
        let owned = ListeningStatsSync.owned(device: device, carried: carried, since: since)
        let back = ListeningStatsSync.deviceSpace(pot: owned, carried: carried, since: since)
        #expect(back == device, "the way back is not the way there")
        #expect(ListeningStatsSync.deviceSpace(pot: owned, carried: .init(), since: .init()) == owned,
                "before the first change of account the two spaces are one")
    }

    @Test("the calculation: what was brought along plus what the device counted since the takeover, never below zero")
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
