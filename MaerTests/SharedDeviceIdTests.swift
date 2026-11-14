// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Two devices under one id: the one that sees the other's pot grow under
/// its id takes a fresh id from its next start and writes nothing more
/// under the shared one. A third device then counts each device once.
@MainActor
struct SharedDeviceIdTests {
    /// The far side every device sees, one pot per id.
    @MainActor final class Shared { var pots: [String: ListeningStatsData] = [:] }

    /// One device's view of the far side.
    private final class View: StatsCarrier {
        let name = "shared-fake"
        let hasRoomLimit = false
        let hasDeliveredFirst = true
        let shared: Shared
        init(_ shared: Shared) { self.shared = shared }
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) { shared.pots[deviceId] = pot }
        func pots() -> [String: ListeningStatsData] { shared.pots }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    /// A device: its own rows, its id, and whether it left the id.
    @MainActor final class Device {
        var id: String?
        var left = false
        let directory: URL
        let store: ListeningStatsStore
        init(_ shared: Shared, id: String, name: String) throws {
            directory = try NavidromeRekeyTests.temporaryDirectory(name)
            self.id = id
            let ids = DeviceBox()
            store = ListeningStatsStore(carrier: View(shared),
                                        database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path),
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        deviceIds: StatsDeviceIds(lasting: { ids.device?.id }, leave: {
                                            ids.device?.left = true
                                            ids.device?.id = nil
                                            return true
                                        }))
            ids.device = self
            store.start()
        }
        /// The same device's next start: its rows, a fresh id.
        func restarted(_ shared: Shared, id: String) throws -> ListeningStatsStore {
            let next = ListeningStatsStore(carrier: View(shared),
                                           database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path),
                                           history: ListeningStatsSyncTests.RecordingHistory(),
                                           deviceIds: StatsDeviceIds(lasting: { id }, leave: { false }))
            next.start()
            return next
        }
        func listen(_ seconds: Int, _ title: String) async {
            store.addSeconds(seconds, itemId: title)
            store.flush()
            await store.awaitPendingWrites()
        }
    }

    @MainActor final class DeviceBox { weak var device: Device? }

    @Test("the reporter: only growth under the own id beyond the own reports a second device")
    func whenAnotherDeviceWrites() {
        let mine = ListeningStatsData(secondsPerDay: ["d": 100], secondsPerItem: ["a": 100])
        let other = ListeningStatsData(secondsPerDay: ["d": 50], secondsPerItem: ["b": 50])
        let older = ListeningStatsData(secondsPerDay: ["d": 60], secondsPerItem: ["a": 60])
        #expect(!ListeningStatsSync.anotherDeviceWrites(observed: other, previous: nil, own: mine),
                "a first reading has nothing to grow from (a pot from before a reinstall)")
        #expect(!ListeningStatsSync.anotherDeviceWrites(observed: other, previous: other, own: mine),
                "a pot nobody writes does not grow")
        #expect(ListeningStatsSync.anotherDeviceWrites(observed: other, previous: mine, own: mine),
                "a title this device never heard grew under its id")
        #expect(!ListeningStatsSync.anotherDeviceWrites(observed: older, previous: mine, own: mine),
                "an echo of an older own pot holds no more than the device")
    }

    private func sum(_ store: ListeningStatsStore) -> ListeningStatsData {
        store.cloudChanged()
        return store.data
    }

    /// Two devices under one id listen in turn and read the far side in
    /// turn: exactly one sees the other's pot grow and leaves the id. Which
    /// one is the order of the readings, not a rule: each start publishes
    /// its pot, so either can be the first to see the other's grow.
    private func sharedPair(_ shared: Shared, _ names: (String, String))
        async throws -> (leaver: Device, stayer: Device) {
        let a = try Device(shared, id: "shared", name: names.0)
        let b = try Device(shared, id: "shared", name: names.1)
        await a.listen(100, "rss:share:a")
        a.store.cloudChanged()
        b.store.cloudChanged()
        await b.listen(50, "rss:share:b")
        a.store.cloudChanged()
        b.store.cloudChanged()
        try #require([a.left, b.left].filter { $0 }.count == 1, "exactly one device leaves: a=\(a.left) b=\(b.left)")
        return a.left ? (a, b) : (b, a)
    }

    @Test("(a) one leaves the id, the other keeps writing: the third device counts each once")
    func oneLeavesTheOtherWritesOn() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let shared = Shared()
        let c = try Device(shared, id: "third", name: "share-c")
        let (leaver, stayer) = try await sharedPair(shared, ("share-a", "share-b"))
        defer { for d in [leaver, stayer, c] { try? FileManager.default.removeItem(at: d.directory) } }
        let next = try leaver.restarted(shared, id: "fresh")
        await next.awaitPendingWrites()
        await stayer.listen(10, "rss:share:more")
        stayer.store.cloudChanged()
        #expect(!stayer.left, "the device that stays sees only its own pot")
        let third = sum(c.store)
        let each = next.ownData.secondsPerItem.merging(stayer.store.ownData.secondsPerItem, uniquingKeysWith: +)
        #expect(third.secondsPerItem == each, "each device counted once: \(third.secondsPerItem) against \(each)")
        #expect(third.secondsPerItem.values.reduce(0, +) == 160)
    }

    @Test("(b) and (c): with immediate delivery the second device no longer sees a foreign pot; if it never writes again, its pot stays")
    func theOtherOneStaysOrStops() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let shared = Shared()
        let c = try Device(shared, id: "third", name: "share-c2")
        let (leaver, stayer) = try await sharedPair(shared, ("share-a2", "share-b2"))
        defer { for d in [leaver, stayer, c] { try? FileManager.default.removeItem(at: d.directory) } }
        let next = try leaver.restarted(shared, id: "fresh")
        await next.awaitPendingWrites()
        stayer.store.cloudChanged()
        #expect(!stayer.left, "(b) the second device sees only its own pot and keeps the id")
        // (c) the second device never writes again: its pot stays under the
        // old id, the other's under its new one.
        let third = sum(c.store)
        let each = next.ownData.secondsPerItem.merging(stayer.store.ownData.secondsPerItem, uniquingKeysWith: +)
        #expect(third.secondsPerItem == each, "\(third.secondsPerItem) against \(each)")
        #expect(third.secondsPerItem.values.reduce(0, +) == 150)
    }

    @Test("a sharing device is reinstalled and takes the other's pot; the third counts its seconds twice")
    func aSharingDeviceReinstalled() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let shared = Shared()
        let a = try Device(shared, id: "shared", name: "share-a3")
        let c = try Device(shared, id: "third", name: "share-c3")
        defer { for d in [a, c] { try? FileManager.default.removeItem(at: d.directory) } }

        await a.listen(100, "rss:share:a")
        a.store.cloudChanged()
        // The other device comes back from a reinstall: no rows, and the
        // pot under the shared id is the first device's.
        let b = try Device(shared, id: "shared", name: "share-b3")
        defer { try? FileManager.default.removeItem(at: b.directory) }
        #expect(b.store.ownData.secondsPerItem["rss:share:a"] == 100, "the reinstalled device took the pot as its own")
        await b.listen(20, "rss:share:b")
        a.store.cloudChanged()
        #expect(a.left, "the first device sees the other's pot grow")
        let aNext = try a.restarted(shared, id: "fresh-a")
        await aNext.awaitPendingWrites()
        let third = sum(c.store)
        #expect(third.secondsPerItem["rss:share:a"] == 200,
                "what the third device counts: the first device's seconds twice, under its new id and in the other's pot")
    }

    @Test("only the day grows: the other device listens to a title that this one listened to for longer, on a day beyond the own")
    func onlyTheDayGrows() {
        let own = ListeningStatsData(secondsPerDay: ["d": 100], secondsPerItem: ["t": 200])
        let other = ListeningStatsData(secondsPerDay: ["d": 150], secondsPerItem: ["t": 150])
        #expect(ListeningStatsSync.anotherDeviceWrites(observed: other, previous: own, own: own),
                "the day grew beyond this device's, the title did not")
    }

    /// A carrier that holds a pot from earlier under the id and has not
    /// taken this device's write yet: a far side still delivering.
    private final class LaggingView: StatsCarrier {
        let name = "lagging-fake"
        let hasRoomLimit = false
        let hasDeliveredFirst = true
        var held: [String: ListeningStatsData]
        init(_ held: [String: ListeningStatsData]) { self.held = held }
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {}
        func pots() -> [String: ListeningStatsData] { held }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    private static let earlier = ListeningStatsData(secondsPerDay: ["2026-01-02": 500],
                                                    secondsPerItem: ["rss:share:earlier": 500])

    @Test("a new carrier: its first reading under the own id does not grow against the old one's")
    func aNewCarrierStartsFresh() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let shared = Shared()
        let device = try Device(shared, id: "shared", name: "share-carrier")
        defer { try? FileManager.default.removeItem(at: device.directory) }
        await device.listen(100, "rss:share:a")
        device.store.cloudChanged()
        device.store.follow(LaggingView(["shared": Self.earlier]), signedIn: true, by: "witness")
        device.store.cloudChanged()
        #expect(!device.left, "the pot the new carrier held from earlier is no other device writing")
    }

    /// One set of pots per account, as the service keeps them.
    private final class AccountView: StatsCarrier {
        let name = "account-fake"
        let hasRoomLimit = false
        let hasDeliveredFirst = true
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
    }

    @Test("a new owner: the first reading under his account does not grow against the old one's")
    func aNewOwnerStartsFresh() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let folder = try NavidromeRekeyTests.temporaryDirectory("share-owner")
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path)
        var scope: String? = "account-a"
        var left = false
        let carrier = AccountView(scope: { scope })
        carrier.byAccount["account-b"] = ["shared": Self.earlier]
        let stats = ListeningStatsStore(carrier: carrier, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        identity: { scope }, shelf: database.restingShelf,
                                        deviceIds: StatsDeviceIds(lasting: { "shared" }, leave: { left = true; return true }))
        stats.start()
        stats.addSeconds(100, itemId: "rss:share:a")
        stats.flush()
        stats.cloudChanged()
        // The account changes; the service delivers the other account's
        // pots before this device writes under it.
        scope = "account-b"
        stats.cloudChanged()
        #expect(!left, "the pot of another owner is no other device writing")
    }

    @Test("the holder hands in the id: a new one for the next start, no lasting one in this process")
    func theHolderLeavesTheSharedId() {
        let keychain = DeviceIdHolderTests.FakeKeychain()
        keychain.answer(.value("shared"))
        let holder = DeviceIdHolder(account: "witness", reading: { keychain.read($0) }, saving: { keychain.save($0, $1) })
        #expect(holder.lasting == "shared", "the precondition: the shared id is held")
        #expect(holder.leave())
        #expect(holder.lasting == nil, "nothing lasting is written under the shared id any more")
        #expect(holder.current != "shared", "its pots and claims count as foreign")
        let fresh = keychain.saved.last
        #expect(fresh != nil && fresh != "shared", "a fresh id waits in the keychain")
        #expect(!holder.reread(), "the fresh id holds from the next start, not in this process")
    }

    @Test("Mär Sync: a 412 on the own area reads the pot there and reports it to the statistics")
    func theServiceReadsTheOwnPotOnAStaleWrite() async throws {
        let name = "share-service-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { access }, deviceId: { "shared" }, defaults: defaults)
        let carrier = MaerSyncStatsCarrier(session: session)
        carrier.start {}
        let mine = ListeningStatsData(secondsPerDay: ["d": 100], secondsPerItem: ["a": 100])
        carrier.publish(mine, deviceId: "shared", by: "witness")
        await session.refresh(by: "witness")
        let other = ListeningStatsData(secondsPerDay: ["d": 50], secondsPerItem: ["b": 50])
        _ = transport.foreignWrite(kind: MaerSyncSession.statsKind, scope: "shared", body: try MaerSyncStatsWire.encode(other))
        var seen: ListeningStatsData?
        carrier.start { seen = carrier.pots()["shared"] }
        carrier.publish(ListeningStatsData(secondsPerDay: ["d": 110], secondsPerItem: ["a": 110]), deviceId: "shared", by: "witness")
        await session.refresh(by: "witness")
        #expect(seen == other, "the store saw the other device's pot under the own scope: \(String(describing: seen))")
    }
}
#endif
