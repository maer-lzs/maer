// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CloudKit
import Foundation
@testable import Maer

/// The CloudKit carrier for the statistics over a fake zone: the own pot
/// goes to the key-value store until the cloud took its record once, then
/// the cloud alone carries it and the ceiling is gone; a foreign device's
/// record arrives by token and wakes the store; a device on an older
/// build is still read from the key-value pot; no account means the
/// key-value carrier does the whole job; a refused write stays queued and
/// survives the restart.
@MainActor
struct CloudKitStatsCarrierTests {
    @MainActor
    final class FakeZone: CloudZoneDatabase {
        typealias Value = CloudStatsRecord
        var available = true
        var records: [String: (record: CloudStatsRecord, version: Int)] = [:]
        var deleted: [String: Int] = [:]
        var version = 0
        var refuseEveryModify: CloudStandFailure?
        let hold = ModifyHold()
        var modifies: [[CloudStatsRecord]] = []

        func accountAvailable() async -> Bool { available }
        func ensureZone() async throws {}
        func ensureSubscription() async throws {}
        func changes(since token: Data?) async throws -> CloudZoneChanges<CloudStatsRecord> {
            let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? -1
            var out = CloudZoneChanges<CloudStatsRecord>()
            out.changed = records.values.filter { $0.version > since }.map(\.record)
            out.deletedRecordNames = deleted.filter { $0.value > since }.map(\.key)
            out.token = Data(String(version).utf8)
            return out
        }
        func modify(save: [CloudStatsRecord], delete recordNames: [String]) async throws {
            await hold.enter()
            if let failure = refuseEveryModify { throw failure }
            modifies.append(save)
            for record in save {
                version += 1
                records[record.deviceId] = (record, version)
            }
            for name in recordNames {
                version += 1
                records[name] = nil
                deleted[name] = version
            }
        }
        func foreignWrite(_ record: CloudStatsRecord) {
            version += 1
            records[record.deviceId] = (record, version)
        }
    }

    private let pot = ListeningStatsData(secondsPerDay: ["2026-09-10": 600], secondsPerItem: ["radio:a": 500, "rss:s:e": 100])

    private func suite() -> (UserDefaults, String) {
        let name = "cloud-stats-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func carrier(zone: FakeZone, defaults: UserDefaults, store: InMemoryCloudStore = InMemoryCloudStore())
        -> (CloudKitStatsCarrier, KeyValueStatsCarrier) {
        let keyValue = KeyValueStatsCarrier(store: store)
        return (CloudKitStatsCarrier(database: zone, fallback: keyValue, defaults: defaults), keyValue)
    }

    @Test("bis die Wolke den eigenen Datensatz nimmt, traegt der Schluessel-Topf mit Deckel; danach die Wolke ohne")
    func theCeilingGoesWithTheFirstAcceptedRecord() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let store = InMemoryCloudStore()
        let (carrier, keyValue) = carrier(zone: zone, defaults: defaults, store: store)
        #expect(carrier.name == "cloudkit migrating")
        #expect(carrier.hasRoomLimit, "the key-value pot still carries")

        zone.refuseEveryModify = .transport("ck 12 Cannot create new type Stats in production schema")
        carrier.publish(pot, deviceId: "dev-a", by: "witness")
        await carrier.refresh(by: "witness")
        #expect(keyValue.pots()["dev-a"] == pot, "the key-value pot got the write")
        #expect(carrier.hasRoomLimit, "refused: the ceiling stays")
        #expect(carrier.pots()["dev-a"] == pot, "the queued own pot answers at once")

        zone.refuseEveryModify = nil
        await carrier.refresh(by: "tick")
        #expect(zone.records["dev-a"] != nil, "the queue went out on the next round")
        #expect(!carrier.hasRoomLimit, "the cloud carries, the ceiling is gone")
        #expect(carrier.name == "cloudkit")

        // From here the key-value pot is read only: a second publish does
        // not touch it.
        let bigger = ListeningStatsData(secondsPerDay: ["2026-09-10": 700], secondsPerItem: ["radio:a": 600])
        carrier.publish(bigger, deviceId: "dev-a", by: "witness")
        await carrier.refresh(by: "tick")
        #expect(keyValue.pots()["dev-a"] == pot, "the key-value pot kept the old write")
        #expect(MaerSyncStatsWire.decode(zone.records["dev-a"]!.record.payload) == bigger)
    }

    @Test("ein fremder Datensatz kommt per Token und weckt; ein Geraet auf einem aelteren Bau wird aus dem Schluessel-Topf gelesen; die Wolke gewinnt je Geraet")
    func foreignRecordsAndLegacyPots() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let store = InMemoryCloudStore()
        let (carrier, _) = carrier(zone: zone, defaults: defaults, store: store)
        var woken = 0
        carrier.start { woken += 1 }
        await carrier.refresh(by: "witness")

        let old = ListeningStatsData(secondsPerDay: ["2026-09-01": 10], secondsPerItem: [:])
        store.set(try JSONEncoder().encode(old), forKey: ListeningStatsSync.key(forDeviceId: "dev-old"))
        let cloudPot = ListeningStatsData(secondsPerDay: ["2026-09-09": 60], secondsPerItem: ["radio:b": 9])
        zone.foreignWrite(CloudStatsRecord(deviceId: "dev-b", payload: try MaerSyncStatsWire.encode(cloudPot), t: 1))
        // dev-b also left an older key-value pot: the cloud's record wins.
        store.set(try JSONEncoder().encode(old), forKey: ListeningStatsSync.key(forDeviceId: "dev-b"))
        await carrier.refresh(by: "tick")
        let pots = carrier.pots()
        #expect(pots["dev-b"] == cloudPot)
        #expect(pots["dev-old"] == old)
        #expect(woken == 1, "the foreign record woke the store once")

        await carrier.refresh(by: "tick")
        #expect(woken == 1, "nothing new, no event")
    }

    @Test("ohne Konto traegt der Schluessel-Speicher die ganze Arbeit")
    func noAccountMeansTheKeyValueCarrier() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        zone.available = false
        let (carrier, keyValue) = carrier(zone: zone, defaults: defaults)
        await carrier.refresh(by: "witness")
        #expect(carrier.fellBack)
        #expect(carrier.name == "kvs fallback")
        #expect(carrier.hasRoomLimit)
        carrier.publish(pot, deviceId: "dev-a", by: "witness")
        #expect(keyValue.pots()["dev-a"] == pot)
        #expect(zone.modifies.isEmpty, "nothing reaches a cloud without an account")
    }

    @Test("ein abgewiesener Schrieb bleibt in der Warteschlange und ueberlebt den Neustart")
    func aRefusedWriteSurvivesTheRestart() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        zone.refuseEveryModify = .transport("quota")
        var (carrier, _) = carrier(zone: zone, defaults: defaults)
        carrier.publish(pot, deviceId: "dev-a", by: "witness")
        await carrier.refresh(by: "witness")
        #expect(zone.records.isEmpty)

        zone.refuseEveryModify = nil
        (carrier, _) = self.carrier(zone: zone, defaults: defaults)
        #expect(carrier.pots()["dev-a"] == pot, "the queued pot survives the restart")
        await carrier.refresh(by: "witness")
        #expect(MaerSyncStatsWire.decode(zone.records["dev-a"]!.record.payload) == pot)
    }

    @Test("der Codec: Datensatz hin und zurueck, Name ist die Geraete-Kennung")
    func codecRoundTrip() throws {
        let record = CloudStatsRecord(deviceId: "dev-a", payload: try MaerSyncStatsWire.encode(pot), t: 42)
        #expect(CloudStatsCodec.recordName(for: record) == "dev-a")
        let ck = CKRecord(recordType: CloudStatsCodec.recordType, recordID: CKRecord.ID(recordName: "dev-a"))
        CloudStatsCodec.fill(ck, with: record)
        #expect(CloudStatsCodec.value(from: ck) == record)
        #expect(CloudStatsCodec.value(from: CKRecord(recordType: CloudStatsCodec.recordType)) == nil)
        // The stand codec still speaks its record too.
        let stand = CloudStandRecord(itemId: "rss:x", entry: [1, 2, 3, 4], tombstone: false)
        let standRecord = CKRecord(recordType: CloudStandCodec.recordType, recordID: CKRecord.ID(recordName: CloudStandCodec.recordName(for: stand)))
        CloudStandCodec.fill(standRecord, with: stand)
        #expect(CloudStandCodec.value(from: standRecord) == stand)
    }
}
#endif
