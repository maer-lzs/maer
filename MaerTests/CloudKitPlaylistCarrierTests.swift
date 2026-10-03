// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CloudKit
import Foundation
@testable import Maer

/// The CloudKit carrier for the playlists over a fake zone: the blob is
/// folded into records once and then only read; `held()` unites the cloud
/// with the blob through the ONE rule; `store()` writes the diff, a
/// deletion travels as a tombstone record; a foreign device's record
/// arrives by token and wakes the runner; no account means the key-value
/// carrier does the whole job; a refused write stays queued and survives
/// the restart.
@MainActor
struct CloudKitPlaylistCarrierTests {
    @MainActor
    final class FakeZone: CloudZoneDatabase {
        typealias Value = CloudPlaylistRecord
        var available = true
        var records: [String: (record: CloudPlaylistRecord, version: Int)] = [:]
        var deleted: [String: Int] = [:]
        var version = 0
        var refuseEveryModify: CloudStandFailure?
        var modifies = 0

        func accountAvailable() async -> Bool { available }
        func ensureZone() async throws {}
        func ensureSubscription() async throws {}
        func changes(since token: Data?) async throws -> CloudZoneChanges<CloudPlaylistRecord> {
            let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? -1
            var out = CloudZoneChanges<CloudPlaylistRecord>()
            out.changed = records.values.filter { $0.version > since }.map(\.record)
            out.deletedRecordNames = deleted.filter { $0.value > since }.map(\.key)
            out.token = Data(String(version).utf8)
            return out
        }
        func modify(save: [CloudPlaylistRecord], delete recordNames: [String]) async throws {
            if let failure = refuseEveryModify { throw failure }
            modifies += 1
            for record in save {
                version += 1
                records[record.listId] = (record, version)
            }
            for name in recordNames {
                version += 1
                records[name] = nil
                deleted[name] = version
            }
        }
        func foreignWrite(_ record: CloudPlaylistRecord) {
            version += 1
            records[record.listId] = (record, version)
        }
    }

    private func suite() -> (UserDefaults, String) {
        let name = "cloud-playlist-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func entry(_ name: String, _ t: Double, _ items: [String]) -> MaerPlaylistMerge.Entry {
        .init(name: name, updatedAt: t, itemIds: items, device: "phone")
    }

    private func carrier(_ zone: FakeZone, _ defaults: UserDefaults, store: InMemoryCloudStore = InMemoryCloudStore())
        -> (CloudKitPlaylistCarrier, KeyValuePlaylistCarrier) {
        let keyValue = KeyValuePlaylistCarrier(store: store)
        return (CloudKitPlaylistCarrier(database: zone, fallback: keyValue, defaults: defaults), keyValue)
    }

    @Test("der Blob wird einmal in Datensaetze gefaltet, danach nur gelesen; der Spiegel traegt Liste und Grabstein")
    func theBlobIsFoldedOnce() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let store = InMemoryCloudStore()
        let (carrier, keyValue) = carrier(zone, defaults, store: store)
        // The key-value blob already holds a list and a deleted one.
        var seed = MaerPlaylistMerge.Snapshot()
        seed.lists["l1"] = entry("Mix", 1_700_000_000, ["jam:1", "lva:x"])
        seed.tombstones["gone"] = 1_699_000_000
        keyValue.store(seed)
        #expect(carrier.name == "cloudkit migrating")

        carrier.start { }
        await carrier.refresh(by: "witness")
        #expect(carrier.name == "cloudkit", "the fold is done, the cloud carries")
        #expect(zone.records["l1"]?.record.tombstone == false)
        #expect(zone.records["gone"]?.record.tombstone == true, "a deletion travels as a tombstone record")
        let held = carrier.held()
        #expect(held.lists["l1"]?.itemIds == ["jam:1", "lva:x"])
        #expect(held.tombstones["gone"] == 1_699_000_000)
    }

    @Test("store schreibt nur den Unterschied; eine Loeschung reist als Grabstein; eine fremde Liste weckt den Laeufer")
    func storeWritesTheDiffAndForeignWakes() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let (carrier, _) = carrier(zone, defaults)
        var woken = 0
        carrier.start { woken += 1 }
        await carrier.refresh(by: "start")

        var snap = MaerPlaylistMerge.Snapshot()
        snap.lists["l1"] = entry("Mix", 1_700_000_000, ["jam:1"])
        carrier.store(snap)
        await carrier.refresh(by: "witness")
        #expect(zone.records["l1"]?.record.tombstone == false)

        // Delete l1: it leaves `lists` and enters `tombstones`.
        var deletedSnap = MaerPlaylistMerge.Snapshot()
        deletedSnap.tombstones["l1"] = 1_700_000_500
        carrier.store(deletedSnap)
        await carrier.refresh(by: "delete")
        #expect(zone.records["l1"]?.record.tombstone == true, "the same record turned into a tombstone")
        #expect(carrier.held().lists["l1"] == nil)
        #expect(carrier.held().tombstones["l1"] == 1_700_000_500)

        // Another device writes a list record; the token brings it and wakes.
        let before = woken
        zone.foreignWrite(CloudPlaylistRecord(listId: "l2", payload: MaerPlaylistEntryWire.encode(entry("Other", 1_700_000_900, ["sub:song:9"])),
                                              t: 1_700_000_900, tombstone: false))
        await carrier.refresh(by: "tick")
        #expect(carrier.held().lists["l2"]?.itemIds == ["sub:song:9"])
        #expect(woken > before, "the foreign write woke the runner")
    }

    /// The runner stamps its own device name on every list it hands over.
    /// A change to one list writes one record, not every list whose name
    /// stamp changed.
    @Test("eine Aenderung an einer Liste schreibt einen Datensatz, auch wenn jede Liste einen anderen Geraetenamen traegt")
    func oneChangedListWritesOneRecord() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let (carrier, _) = carrier(zone, defaults)
        carrier.start { }
        await carrier.refresh(by: "start")

        func stamped(_ entry: MaerPlaylistMerge.Entry, _ device: String) -> MaerPlaylistMerge.Entry {
            var named = entry
            named.device = device
            return named
        }
        let lists = ["l1": entry("Mix", 1_700_000_000, ["jam:1"]),
                     "l2": entry("Morgens", 1_700_000_100, ["rss:f:e"]),
                     "l3": entry("Abends", 1_700_000_200, ["sub:song:3"])]
        carrier.store(MaerPlaylistMerge.Snapshot(lists: lists.mapValues { stamped($0, "iPhone") }))
        await carrier.refresh(by: "first")
        #expect(zone.records.count == 3, "the precondition: three records in the zone")
        let before = zone.version

        var next = lists.mapValues { stamped($0, "iPad") }
        next["l2"]?.itemIds.append("rss:f:e2")
        next["l2"]?.updatedAt += 60
        carrier.store(MaerPlaylistMerge.Snapshot(lists: next))
        await carrier.refresh(by: "second")
        #expect(zone.version - before == 1, "one changed list is one record, a device name is none")
        let written = try #require(zone.records["l2"]).record
        #expect(MaerPlaylistEntryWire.decode(written.payload)?.itemIds == ["rss:f:e", "rss:f:e2"])
    }

    @Test("ein Datensatz ist nur dann zu schreiben, wenn sein Eintrag sich ausser im Namen unterscheidet")
    func theRecordComparison() {
        func record(_ entry: MaerPlaylistMerge.Entry) -> CloudPlaylistRecord {
            CloudPlaylistRecord(listId: "l", payload: MaerPlaylistEntryWire.encode(entry), t: entry.updatedAt, tombstone: false)
        }
        var mine = entry("Mix", 1_700_000_000, ["jam:1"])
        var theirs = mine
        theirs.device = "iPad"
        #expect(!CloudKitPlaylistCarrier.needsWrite(record(mine), over: record(theirs)))
        #expect(CloudKitPlaylistCarrier.needsWrite(record(mine), over: nil), "a record the mirror does not hold is written")
        let tombstone = CloudPlaylistRecord(listId: "l", payload: Data(), t: 1_700_000_500, tombstone: true)
        #expect(CloudKitPlaylistCarrier.needsWrite(tombstone, over: record(mine)), "a deletion is written")
        #expect(!CloudKitPlaylistCarrier.needsWrite(tombstone, over: tombstone))
        mine.itemIds.append("jam:2")
        #expect(CloudKitPlaylistCarrier.needsWrite(record(mine), over: record(theirs)), "a real change is written")
    }

    @Test("ohne Konto traegt der Schluessel-Speicher das Ganze")
    func noAccountFallsBack() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        zone.available = false
        let store = InMemoryCloudStore()
        let (carrier, keyValue) = carrier(zone, defaults, store: store)
        carrier.start { }
        await carrier.refresh(by: "witness")
        #expect(carrier.fellBack)
        #expect(carrier.name == "kvs fallback")
        var snap = MaerPlaylistMerge.Snapshot()
        snap.lists["l1"] = entry("Mix", 1_700_000_000, ["jam:1"])
        carrier.store(snap)
        #expect(keyValue.held().lists["l1"]?.itemIds == ["jam:1"], "the write went to the key-value store")
        #expect(carrier.held().lists["l1"] != nil)
    }

    @Test("ein abgewiesener Schrieb bleibt in der Warteschlange und ueberlebt den Neustart, die Faltung bleibt offen")
    func aRefusedWriteStaysQueued() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        zone.refuseEveryModify = .transport("ck 12 Cannot create new type Playlist in production schema")
        let store = InMemoryCloudStore()
        let (carrier, _) = carrier(zone, defaults, store: store)
        var snap = MaerPlaylistMerge.Snapshot()
        snap.lists["l1"] = entry("Mix", 1_700_000_000, ["jam:1"])
        carrier.store(snap)
        await carrier.refresh(by: "witness")
        #expect(carrier.name == "cloudkit migrating", "refused: the fold is not done")

        // A fresh carrier on the same defaults reloads the queue.
        let again = CloudKitPlaylistCarrier(database: FakeZone(), fallback: KeyValuePlaylistCarrier(store: store), defaults: defaults)
        #expect(!defaults.bool(forKey: CloudKitPlaylistCarrier.migratedKey), "the fold stayed open across the restart")
        // Its held still answers from the key-value store the write reached.
        #expect(again.held().lists["l1"]?.itemIds == ["jam:1"])
    }

    @Test("die Datensaetze und der Snapshot gehen verlustfrei hin und zurueck")
    func recordsAndSnapshotRoundTrip() {
        var snap = MaerPlaylistMerge.Snapshot()
        snap.lists["l1"] = entry("Mix", 1_700_000_000, ["jam:1", "lva:x"])
        snap.tombstones["gone"] = 1_699_000_000
        let records = CloudKitPlaylistCarrier.records(for: snap)
        #expect(records["l1"]?.tombstone == false)
        #expect(records["gone"]?.tombstone == true && records["gone"]?.payload.isEmpty == true)
        let back = CloudKitPlaylistCarrier.snapshot(of: records)
        #expect(sameSnapshot(back, snap))
        // And the door rows round-trip too.
        #expect(CloudKitPlaylistCarrier.records(of: CloudKitPlaylistCarrier.rows(of: records)) == records)
    }
}
#endif
