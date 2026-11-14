// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Synchronization
@testable import Maer

/// Under an id for this process nothing lasts: no statistics pot, no claim,
/// no document of the service. Once the keychain gives the lasting id, the
/// same process works under it, and bytes nothing reads are replaced by a
/// fresh id instead of waiting for ever.
@MainActor
struct DeviceIdHolderTests {
    /// A keychain whose answers the witness sets, one item.
    nonisolated final class FakeKeychain: Sendable {
        private let state = Mutex<(answer: KeychainRead, saved: [String], saves: Bool)>((.unreadable, [], true))
        func answer(_ read: KeychainRead) { state.withLock { $0.answer = read } }
        func refuseSaves() { state.withLock { $0.saves = false } }
        var saved: [String] { state.withLock { $0.saved } }
        func read(_ account: String) -> KeychainRead { state.withLock { $0.answer } }
        func save(_ account: String, _ id: String) -> Bool {
            state.withLock { held in
                guard held.saves else { return false }
                held.saved.append(id)
                held.answer = .value(id)
                return true
            }
        }
    }

    private func holder(_ keychain: FakeKeychain) -> DeviceIdHolder {
        DeviceIdHolder(account: "witness", reading: { keychain.read($0) }, saving: { keychain.save($0, $1) })
    }

    @Test("unreadable, then readable: first no lasting id and one of the process, then the fixed one in the same process")
    func theLastingIdArrivesInTheSameProcess() {
        let keychain = FakeKeychain()
        let held = holder(keychain)
        #expect(held.lasting == nil, "nothing lasting while the keychain is unreadable")
        let process = held.current
        #expect(!process.isEmpty)
        #expect(!held.reread(), "still unreadable: nothing arrived")
        #expect(held.current == process, "the id for this process stays the same")
        keychain.answer(.value("fixed-id"))
        #expect(held.reread(), "the lasting id arrived")
        #expect(held.lasting == "fixed-id" && held.current == "fixed-id")
        #expect(!held.reread(), "a held id is not read again")
        #expect(keychain.saved.isEmpty, "an id that is there is never written over")
    }

    @Test("unreadable bytes do not wait: a new id is stored and applies")
    func undecodableBytesAreReplaced() {
        let keychain = FakeKeychain()
        keychain.answer(.undecodable)
        let held = holder(keychain)
        #expect(held.lasting != nil, "an id that no read can give is replaced, not waited for")
        #expect(keychain.saved == [held.current], "the fresh id is saved over the bytes")
        #expect(DeviceIdOrigin.of(.undecodable, fresh: { "f" }) == .minted("f"))
        #expect(DeviceIdOrigin.of(.unreadable, fresh: { "f" }) == .forThisProcess("f"))
    }

    @Test("a new id that cannot be stored applies only to this process")
    func aFreshIdThatIsNotSavedDoesNotLast() {
        let keychain = FakeKeychain()
        keychain.answer(.missing)
        keychain.refuseSaves()
        #expect(holder(keychain).lasting == nil, "the next process would not find it")
    }

    @Test("the real keychain: an entry of unreadable bytes is replaced, not doubled")
    func theRealKeychainReplacesUnreadableBytes() throws {
        let account = "deviceIdWitness.\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: account) }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: Data([0xFF, 0xFE, 0xFD]),
        ]
        try #require(SecItemAdd(item as CFDictionary, nil) == errSecSuccess, "the precondition: the bytes stand")
        try #require(KeychainStore.read(forKey: account) == .undecodable, "the precondition: nothing reads them")
        let held = DeviceIdHolder(account: account)
        let lasting = try #require(held.lasting, "the save over the bytes landed")
        #expect(KeychainStore.read(forKey: account) == .value(lasting), "the keychain gives the new id back")
    }

    /// A statistics carrier that records under which id it was written.
    private final class RecordingStats: StatsCarrier {
        let name = "id-fake"
        let hasRoomLimit = false
        let hasDeliveredFirst = true
        var held: [String: ListeningStatsData] = [:]
        var publishedUnder: [String] = []
        func publish(_ pot: ListeningStatsData, deviceId: String, by caller: String) {
            publishedUnder.append(deviceId)
            held[deviceId] = pot
        }
        func pots() -> [String: ListeningStatsData] { held }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    @MainActor final class Box { var id: String? }

    @Test("the statistics: without a fixed id no pot; with it the own pot from before no longer counts twice")
    func theStatisticsWaitForTheLastingId() async throws {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let directory = try NavidromeRekeyTests.temporaryDirectory("device-id-stats")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path)
        let carrier = RecordingStats()
        let before = ListeningStatsData(secondsPerDay: ["2026-01-02": 900], secondsPerItem: [:])
        carrier.held["fixed-id"] = before
        let box = Box()
        let stats = ListeningStatsStore(carrier: carrier, database: database,
                                        history: ListeningStatsSyncTests.RecordingHistory(),
                                        deviceIds: StatsDeviceIds(lasting: { box.id }, leave: { false }))
        stats.start()
        stats.addSeconds(30, itemId: "rss:device-id:new")
        stats.flush()
        await stats.awaitPendingWrites()
        #expect(carrier.publishedUnder.isEmpty, "nothing is published under an id for this process")
        #expect(stats.data.secondsPerDay["2026-01-02"] == 900, "the precondition: the own pot from before counts as foreign")

        box.id = "fixed-id"
        stats.cloudChanged()
        await stats.awaitPendingWrites()
        #expect(carrier.publishedUnder == ["fixed-id"], "published under the lasting id: \(carrier.publishedUnder)")
        #expect(stats.ownData.secondsPerDay["2026-01-02"] == 900, "the own pot from before is taken back")
        #expect(stats.data.secondsPerDay["2026-01-02"] == 900, "and counted once, not as foreign beside it")
    }

    @Test("the claim: without a fixed id none is written, with it one is written under it")
    func theClaimWaitsForTheLastingId() {
        let restoreSwitch = SyncSwitchProbe.armOn()
        defer { restoreSwitch() }
        let carrier = ClaimCarrierTests.RecordingCarrier()
        let box = Box()
        let sync = PlaybackClaimSync(carrier: carrier, deviceId: { box.id }, deviceName: { "iPhone" }, now: { 1_000_000 })
        sync.claim(itemId: "rss:f:ep", position: 12)
        sync.release(itemId: "rss:f:ep", position: 12)
        #expect(carrier.written.isEmpty, "no claim under an id for this process")
        box.id = "fixed-id"
        sync.claim(itemId: "rss:f:ep", position: 13)
        #expect(carrier.written.map(\.deviceId) == ["fixed-id"])
    }

    @Test("Mär Sync: without a fixed id no area written or listed, afterwards everything under it")
    func theServiceWaitsForTheLastingId() async throws {
        let name = "device-id-service-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = MaerSyncCarrierTests.FakeTransport()
        let access = MaerSyncAccess(baseURL: URL(string: "https://sync.example.test")!, token: "a-token")
        let box = Box()
        let session = MaerSyncSession(transport: transport, announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { access }, deviceId: { box.id }, defaults: defaults)
        let carrier = MaerSyncStatsCarrier(session: session)
        carrier.start {}
        carrier.publish(ListeningStatsData(secondsPerDay: ["d": 1], secondsPerItem: [:]), deviceId: "unused", by: "witness")
        await session.refresh(by: "witness")
        #expect(transport.writes.filter { $0.kind == MaerSyncSession.statsKind }.isEmpty, "no document under an id for this process")
        #expect(!carrier.hasDeliveredFirst, "no listing without the own id")
        box.id = "fixed-id"
        await session.refresh(by: "witness")
        #expect(transport.writes.filter { $0.kind == MaerSyncSession.statsKind }.map(\.scope) == ["fixed-id"],
                "the waiting document goes under the lasting id")
        #expect(carrier.hasDeliveredFirst)
    }

    @Test("every lasting writer takes the lasting id, the id of the process only whoever compares", .needsTheSources)
    func everyLastingWriterTakesTheLastingId() throws {
        // The files that read `SyncHistoryStore.deviceId` to tell own from
        // foreign, and the store itself; nothing else may.
        let comparers: Set = ["PlayerCoordinator.swift", "PlayerViewModel.swift", "PlayingNow.swift",
                              "PlaybackClaimSync.swift", "ListeningStats.swift", "SyncHistoryStore.swift"]
        var readers: Set<String> = []
        var seen = false
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let code = SyncContractFenceTests.stripped(text)
            if file.hasSuffix("SyncQueue.swift") { seen = code.contains("SyncHistoryStore.entryDeviceId") }
            if code.contains(#/SyncHistoryStore\.deviceId(?![A-Za-z0-9_])/#) {
                readers.insert(URL(fileURLWithPath: file).lastPathComponent)
            }
        }
        #expect(seen, "the fence read the writers")
        #expect(readers.subtracting(comparers).isEmpty, "a lasting writer takes the id for this process: \(readers.subtracting(comparers).sorted())")
        let session = try FetchAnswerTests.squeezedSource("Sources/Networking/MaerSyncCarriers.swift")
        #expect(session.contains("deviceId: { SyncHistoryStore.lastingDeviceId }"), "the service's scope is the lasting id")
    }
}
#endif
