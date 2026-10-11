// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every cloud carrier sends one batch at a time: a write that lands while
/// a `modify` is in flight goes out after it, never before it, so the cloud
/// ends with the newer value. Once the sends have settled, a carrier sends
/// nothing more until something changes.
@MainActor
struct CloudSendChainTests {
    private func suite() -> (UserDefaults, String) {
        let name = "cloud-send-chain-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Long enough for an unchained send to have gone out, without a sleep.
    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test("Wahlen: ein Schrieb waehrend eines laufenden modify landet nach dem aelteren; danach sendet der Traeger nichts mehr")
    func choicesGoOneAfterAnother() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = CloudKitChoiceCarrierTests.FakeZone()
        let carrier = CloudKitChoiceCarrier(database: zone, fallback: KeyValueChoiceCarrier(store: InMemoryCloudStore()),
                                            defaults: defaults)
        carrier.start {}
        await carrier.refresh(by: "witness")
        let older = ["sort.books": UserChoiceEntry(value: .string("title"), t: 1000).plist]
        let newer = ["sort.books": UserChoiceEntry(value: .string("author"), t: 2000).plist]

        zone.hold.holdNext = true
        carrier.storeBlob(older)
        await zone.hold.entered()
        carrier.storeBlob(newer)
        await settle()
        zone.hold.release()
        await settle()

        let stored = zone.record(forKey: "sort.books")?.t
        #expect(stored == 2000, "the older choice landed last and stands in the cloud")
        let order = zone.saves.map { $0.map(\.t) }
        #expect(order == [[1000], [2000]], "the sends went out of order: \(order)")

        // Settled: nothing goes out by itself, nor for the same state again.
        let settled = zone.modifies
        await settle()
        carrier.storeBlob(newer)
        await carrier.refresh(by: "quiet")
        #expect(zone.modifies == settled, "the carrier sends again after settling")
    }

    @Test("Playlisten: ein Schrieb waehrend eines laufenden modify landet nach dem aelteren; danach sendet der Traeger nichts mehr")
    func playlistsGoOneAfterAnother() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = CloudKitPlaylistCarrierTests.FakeZone()
        let carrier = CloudKitPlaylistCarrier(database: zone, fallback: KeyValuePlaylistCarrier(store: InMemoryCloudStore()),
                                              defaults: defaults)
        carrier.start {}
        await carrier.refresh(by: "witness")
        var older = MaerPlaylistMerge.Snapshot()
        older.lists["l1"] = .init(name: "Mix", updatedAt: 1000, itemIds: ["jam:1"], device: "phone")
        var newer = MaerPlaylistMerge.Snapshot()
        newer.lists["l1"] = .init(name: "Mix", updatedAt: 2000, itemIds: ["jam:1", "jam:2"], device: "phone")

        zone.hold.holdNext = true
        carrier.store(older)
        await zone.hold.entered()
        carrier.store(newer)
        await settle()
        zone.hold.release()
        await settle()

        let stored = zone.records["l1"]?.record.t
        #expect(stored == 2000, "the older list landed last and stands in the cloud")
        let order = zone.saves.map { $0.map(\.t) }
        #expect(order == [[1000], [2000]], "the sends went out of order: \(order)")

        let settled = zone.modifies
        await settle()
        carrier.store(newer)
        await carrier.refresh(by: "quiet")
        #expect(zone.modifies == settled, "the carrier sends again after settling")
    }

    @Test("Statistik: ein Topf waehrend eines laufenden modify landet nach dem aelteren; danach sendet der Traeger nichts mehr")
    func statsGoOneAfterAnother() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = CloudKitStatsCarrierTests.FakeZone()
        let carrier = CloudKitStatsCarrier(database: zone, fallback: KeyValueStatsCarrier(store: InMemoryCloudStore()),
                                           defaults: defaults)
        carrier.start {}
        await carrier.refresh(by: "witness")
        let older = ListeningStatsData(secondsPerDay: ["2026-09-10": 600], secondsPerItem: ["radio:a": 600])
        let newer = ListeningStatsData(secondsPerDay: ["2026-09-10": 900], secondsPerItem: ["radio:a": 900])

        zone.hold.holdNext = true
        carrier.publish(older, deviceId: "dev-a", by: "witness")
        await zone.hold.entered()
        carrier.publish(newer, deviceId: "dev-a", by: "witness")
        await settle()
        zone.hold.release()
        await settle()

        let stored = zone.records["dev-a"].flatMap { MaerSyncStatsWire.decode($0.record.payload) }
        #expect(stored?.secondsPerDay["2026-09-10"] == 900, "the older pot landed last and stands in the cloud")
        #expect(zone.modifies.count == 2, "the newer pot did not go out once after the older one: \(zone.modifies.count)")

        let settled = zone.modifies.count
        await settle()
        await carrier.refresh(by: "quiet")
        #expect(zone.modifies.count == settled, "the carrier sends again after settling")
    }

    /// Every carrier that writes to the cloud holds the one chain and sends
    /// through it; no carrier keeps a chain of its own.
    @Test("jeder Wolken-Traeger sendet ueber die eine Kette, keiner baut eine eigene", .needsTheSources)
    func everyCarrierSendsThroughTheChain() throws {
        var writers: [String] = []
        var unchained: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = StockDriftTests.squeezed(SyncContractFenceTests.stripped(text))
            guard code.contains("database.modify(") else { continue }
            writers.append(name)
            let chained = code.components(separatedBy: "letsends=SendChain()").count - 1 == 1
                && code.components(separatedBy: "sends.run{").count - 1 == 1
            if !chained || code.contains("Task<Int,Never>?") { unchained.append(name) }
        }
        #expect(writers.count == 4, "the cloud writers are not the four carriers: \(writers.sorted())")
        #expect(unchained.isEmpty, "a carrier sends beside the one chain: \(unchained.sorted())")
    }
}
#endif
