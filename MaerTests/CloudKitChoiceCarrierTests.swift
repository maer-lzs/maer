// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CloudKit
import Foundation
@testable import Maer

/// The CloudKit carrier for the choices over a fake zone: the blob is
/// folded into records once and then only read; `loadBlob()` presents the
/// cloud with the blob beside it, per key the newer moment; `storeBlob()`
/// writes the difference, a dropped key leaves the cloud, a clear travels
/// as a tombstone record; a foreign device's record arrives by token and
/// wakes the runner; no account means the key-value carrier does the whole
/// job; a refused write stays queued and survives the restart.
@MainActor
struct CloudKitChoiceCarrierTests {
    @MainActor
    final class FakeZone: CloudZoneDatabase {
        typealias Value = CloudChoiceRecord
        var available = true
        var records: [String: (record: CloudChoiceRecord, version: Int)] = [:]
        var deleted: [String: Int] = [:]
        var version = 0
        var refuseEveryModify: CloudStandFailure?
        var modifies = 0

        func accountAvailable() async -> Bool { available }
        func ensureZone() async throws {}
        func ensureSubscription() async throws {}
        func changes(since token: Data?) async throws -> CloudZoneChanges<CloudChoiceRecord> {
            let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? -1
            var out = CloudZoneChanges<CloudChoiceRecord>()
            out.changed = records.values.filter { $0.version > since }.map(\.record)
            out.deletedRecordNames = deleted.filter { $0.value > since }.map(\.key)
            out.token = Data(String(version).utf8)
            return out
        }
        func modify(save: [CloudChoiceRecord], delete recordNames: [String]) async throws {
            if let failure = refuseEveryModify { throw failure }
            modifies += 1
            for record in save {
                version += 1
                records[CloudStandNaming.recordName(for: record.key)] = (record, version)
            }
            for name in recordNames {
                version += 1
                records[name] = nil
                deleted[name] = version
            }
        }
        func foreignWrite(_ record: CloudChoiceRecord) {
            version += 1
            records[CloudStandNaming.recordName(for: record.key)] = (record, version)
        }
        func record(forKey key: String) -> CloudChoiceRecord? {
            records[CloudStandNaming.recordName(for: key)]?.record
        }
    }

    private func suite() -> (UserDefaults, String) {
        let name = "cloud-choice-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func carrier(_ zone: FakeZone, _ defaults: UserDefaults,
                         store: InMemoryCloudStore = InMemoryCloudStore()) -> CloudKitChoiceCarrier {
        CloudKitChoiceCarrier(database: zone, fallback: KeyValueChoiceCarrier(store: store), defaults: defaults)
    }

    private func entries(_ blob: [String: Any]) -> [String: UserChoiceEntry] {
        var out: [String: UserChoiceEntry] = [:]
        for (key, raw) in blob { if let entry = UserChoiceEntry.from(plist: raw) { out[key] = entry } }
        return out
    }

    private var sample: [String: Any] {
        ["sort.books": UserChoiceEntry(value: .string("title"), t: 1000).plist,
         "playbackRate.a": UserChoiceEntry(value: .double(1.25), t: 2000).plist,
         "cleared": UserChoiceEntry(value: nil, t: 3000).plist]
    }

    @Test("der Blob wird einmal in Datensaetze gefaltet, danach nur gelesen; der Spiegel traegt Wert und Grabstein")
    func theBlobIsFoldedOnce() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let store = InMemoryCloudStore()
        store.set(sample, forKey: KeyValueChoiceCarrier.blobKey)
        let carrier = carrier(zone, defaults, store: store)
        #expect(carrier.name == "cloudkit migrating")

        await carrier.refresh(by: "witness")
        #expect(zone.records.count == 3, "a value, a rate and a tombstone became records")
        #expect(zone.record(forKey: "cleared")?.tombstone == true)
        #expect(zone.record(forKey: "sort.books")?.tombstone == false)
        #expect(entries(carrier.loadBlob()) == entries(sample))
        #expect(carrier.name == "cloudkit")

        // A second round writes nothing: the mirror already holds the fold.
        let before = zone.modifies
        await carrier.refresh(by: "again")
        #expect(zone.modifies == before)
    }

    @Test("store schreibt nur den Unterschied; ein gefallener Schluessel verlaesst die Wolke; ein fremder Datensatz weckt den Laeufer")
    func storeWritesTheDifference() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let carrier = carrier(zone, defaults)
        var woken = 0
        carrier.start { woken += 1 }
        await carrier.refresh(by: "witness")

        carrier.storeBlob(sample)
        await carrier.refresh(by: "settle")
        #expect(zone.records.count == 3)
        let modifiesAfterFirst = zone.modifies

        // The same blob again: nothing differs, nothing is written.
        carrier.storeBlob(sample)
        await carrier.refresh(by: "same")
        #expect(zone.modifies == modifiesAfterFirst)

        // A changed value, a cleared key, and a rate the cap dropped.
        var next = sample
        next["sort.books"] = UserChoiceEntry(value: .string("author"), t: 4000).plist
        next["radio.fav"] = UserChoiceEntry(value: nil, t: 4500).plist
        next["playbackRate.a"] = nil
        carrier.storeBlob(next)
        await carrier.refresh(by: "settle")
        #expect(zone.record(forKey: "sort.books")?.t == 4000)
        #expect(zone.record(forKey: "radio.fav")?.tombstone == true)
        #expect(zone.record(forKey: "playbackRate.a") == nil, "the dropped rate left the cloud")
        #expect(zone.deleted[CloudStandNaming.recordName(for: "playbackRate.a")] != nil)
        #expect(entries(carrier.loadBlob())["playbackRate.a"] == nil, "and the mirror does not bring it back")

        // Another device writes a key; the next round takes it and wakes.
        let wokenBefore = woken
        zone.foreignWrite(CloudChoiceRecord(key: "sort.podcasts", payload: CloudChoicePayload.encode(.string("newest")),
                                            t: 5000, tombstone: false))
        await carrier.refresh(by: "tick")
        #expect(entries(carrier.loadBlob())["sort.podcasts"]?.value == .string("newest"))
        #expect(woken > wokenBefore)
    }

    @Test("ein gekappter Schluessel kommt nicht aus dem eingefrorenen Blob zurueck; was ein aelterer Bau danach schreibt, kommt an")
    func aPrunedKeyDoesNotReturnFromTheFrozenBlob() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let store = InMemoryCloudStore()
        // The premise: the blob holds three rates BEFORE the first round, so
        // the fold has them and the blob stays frozen with them.
        let rates: [String: Any] = ["playbackRate.a": UserChoiceEntry(value: .double(1.0), t: 100).plist,
                                    "playbackRate.b": UserChoiceEntry(value: .double(1.25), t: 200).plist,
                                    "playbackRate.c": UserChoiceEntry(value: .double(1.5), t: 300).plist]
        store.set(rates, forKey: KeyValueChoiceCarrier.blobKey)
        let carrier = carrier(zone, defaults, store: store)
        await carrier.refresh(by: "fold")
        #expect(zone.records.count == 3)
        #expect(carrier.name == "cloudkit")

        // The runner's cap drops one: it leaves the cloud, and the blob is
        // frozen (never written again), so it still holds the key.
        var desired = rates
        desired["playbackRate.a"] = nil
        carrier.storeBlob(desired)
        await carrier.refresh(by: "settle")
        #expect(zone.record(forKey: "playbackRate.a") == nil)
        #expect((store.dictionary(forKey: KeyValueChoiceCarrier.blobKey) ?? [:])["playbackRate.a"] != nil,
                "the blob is frozen after the fold")
        #expect(entries(carrier.loadBlob())["playbackRate.a"] == nil, "and does not bring the key back")

        // A device on an older build writes into the blob after the fold: a
        // new key, and a folded key with a newer time. Both arrive.
        var older = store.dictionary(forKey: KeyValueChoiceCarrier.blobKey) ?? [:]
        older["sort.books"] = UserChoiceEntry(value: .string("title"), t: 900).plist
        older["playbackRate.b"] = UserChoiceEntry(value: .double(2.0), t: 950).plist
        store.set(older, forKey: KeyValueChoiceCarrier.blobKey)
        let read = entries(carrier.loadBlob())
        #expect(read["sort.books"]?.value == .string("title"))
        #expect(read["playbackRate.b"]?.value == .double(2.0))
        #expect(read["playbackRate.a"] == nil, "still gone: unchanged since the fold")

        // The stamps survive a restart with the rest of the door.
        let again = self.carrier(zone, defaults, store: store)
        #expect(entries(again.loadBlob())["playbackRate.a"] == nil)
    }

    @Test("ohne Konto traegt der Schluessel-Speicher das Ganze")
    func withoutAnAccountTheKeyValueStoreCarries() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        zone.available = false
        let store = InMemoryCloudStore()
        let carrier = carrier(zone, defaults, store: store)
        await carrier.refresh(by: "witness")
        #expect(carrier.fellBack)
        #expect(carrier.name == "kvs fallback")
        carrier.storeBlob(sample)
        #expect(entries(store.dictionary(forKey: KeyValueChoiceCarrier.blobKey) ?? [:]) == entries(sample))
        #expect(entries(carrier.loadBlob()) == entries(sample))
        #expect(zone.records.isEmpty)
    }

    @Test("ein abgewiesener Schrieb bleibt in der Warteschlange und ueberlebt den Neustart, die Faltung bleibt offen")
    func aRefusedWriteStaysQueued() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        zone.refuseEveryModify = .transport("refused")
        let store = InMemoryCloudStore()
        // Something to fold, which the zone then refuses: the fold stays open.
        store.set(sample, forKey: KeyValueChoiceCarrier.blobKey)
        let first = carrier(zone, defaults, store: store)
        await first.refresh(by: "witness")
        #expect(zone.records.isEmpty)
        #expect(first.name == "cloudkit migrating")

        // Before the fold is done the blob still carries for every device: a
        // newer state written now reaches the blob, and the queue keeps it.
        var next = sample
        next["sort.books"] = UserChoiceEntry(value: .string("author"), t: 4000).plist
        first.storeBlob(next)
        await first.refresh(by: "settle")
        #expect(entries(store.dictionary(forKey: KeyValueChoiceCarrier.blobKey) ?? [:]) == entries(next))
        #expect(zone.records.isEmpty)

        // A new carrier over the same door finds the queue and sends it once the zone takes writes.
        zone.refuseEveryModify = nil
        let second = carrier(zone, defaults, store: store)
        await second.refresh(by: "restart")
        #expect(zone.records.count == 3)
        #expect(zone.record(forKey: "sort.books")?.t == 4000)
        #expect(second.name == "cloudkit")
    }

    @Test("Datensaetze, Blob und Tuer-Zeilen gehen verlustfrei hin und zurueck, jeder Werttyp exakt")
    func recordsAndBlobRoundTrip() {
        let every: [String: Any] = [
            "s": UserChoiceEntry(value: .string("x"), t: 1).plist,
            "b": UserChoiceEntry(value: .bool(true), t: 2).plist,
            "i": UserChoiceEntry(value: .int(1), t: 3).plist,
            "d": UserChoiceEntry(value: .double(1), t: 4).plist,
            "l": UserChoiceEntry(value: .stringList(["a", "b"]), t: 5).plist,
            "x": UserChoiceEntry(value: .data(Data([0, 255])), t: 6).plist,
            "gone": UserChoiceEntry(value: nil, t: 7).plist,
        ]
        let records = CloudKitChoiceCarrier.records(for: every)
        #expect(records.count == 7)
        #expect(records["gone"]?.tombstone == true && records["gone"]?.payload.isEmpty == true)
        let back = CloudKitChoiceCarrier.blob(of: records)
        #expect(entries(back) == entries(every))
        #expect(entries(back)["i"]?.value == .int(1))
        #expect(entries(back)["d"]?.value == .double(1))
        let rows = CloudKitChoiceCarrier.rows(of: records)
        #expect(CloudKitChoiceCarrier.records(of: rows) == records)
        // An unreadable payload is a value of an unknown kind: kept as it
        // came, not turned into a tombstone and not dropped.
        let broken = ["k": CloudChoiceRecord(key: "k", payload: Data("nonsense".utf8), t: 9, tombstone: false)]
        let kept = CloudKitChoiceCarrier.blob(of: broken)
        #expect(entries(kept)["k"]?.unknownKind == true)
        #expect(CloudKitChoiceCarrier.records(for: kept) == broken)
        // A long key still names a record under the cap.
        let long = String(repeating: "feed/", count: 80)
        #expect(CloudChoiceCodec.recordName(for: CloudChoiceRecord(key: long, payload: Data(), t: 1, tombstone: false)).count == 64)
    }

    @Test("die Vereinigung: je Schluessel gewinnt die juengere Ereigniszeit, Gleichstand die Wolke") @MainActor
    func unionAndLegacy() {
        let cloud: [String: Any] = ["k": UserChoiceEntry(value: .string("cloud"), t: 10).plist,
                                    "only.cloud": UserChoiceEntry(value: .bool(true), t: 1).plist,
                                    "tie": UserChoiceEntry(value: .string("cloud"), t: 5).plist]
        let blob: [String: Any] = ["k": UserChoiceEntry(value: .string("blob"), t: 20).plist,
                                   "only.blob": UserChoiceEntry(value: nil, t: 2).plist,
                                   "tie": UserChoiceEntry(value: .string("blob"), t: 5).plist]
        let united = entries(CloudKitChoiceCarrier.united(cloud: cloud, blob: blob))
        #expect(united["k"]?.value == .string("blob"), "the older build's newer statement wins")
        #expect(united["tie"]?.value == .string("cloud"), "a tie goes to the cloud")
        #expect(united["only.cloud"]?.value == .bool(true))
        #expect(united["only.blob"]?.value == nil && united["only.blob"]?.t == 2)
    }
}
#endif
