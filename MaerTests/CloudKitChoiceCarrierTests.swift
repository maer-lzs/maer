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
        let hold = ModifyHold()
        var saves: [[CloudChoiceRecord]] = []
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
            await hold.enter()
            if let failure = refuseEveryModify { throw failure }
            saves.append(save)
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

    @Test("the blob is folded into records once, then only read; the mirror carries value and tombstone")
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

    @Test("store writes only the difference; a dropped key leaves the cloud; a foreign record wakes the runner")
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

    /// An entry of an unknown kind that came from the key-value blob (or the
    /// service) has no record payload, so the store makes no record for it.
    /// Read as "the runner dropped it", its record would leave the cloud,
    /// and that record is a newer device's statement.
    @Test("an entry of an unknown kind without a record payload does not delete the record")
    func anUnknownEntryWithoutAPayloadDeletesNoRecord() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let carrier = carrier(zone, defaults)
        await carrier.refresh(by: "witness")
        let held = CloudChoiceRecord(key: "sort.books", payload: CloudChoicePayload.encode(.string("title")),
                                     t: 1000, tombstone: false)
        zone.foreignWrite(held)
        await carrier.refresh(by: "fetch")
        #expect(entries(carrier.loadBlob())["sort.books"]?.value == .string("title"), "the precondition: the mirror holds the record")

        // The blob as the runner hands it back: the key carries a newer
        // entry of an unknown kind in the key-value form, and a second key
        // the runner really dropped is gone.
        let unknown: [String: Any] = ["sort.books": ["t": 9000.0, "v": Date()]]
        #expect(CloudKitChoiceCarrier.records(for: unknown).isEmpty, "the precondition: no record is made for it")
        carrier.storeBlob(unknown)
        await carrier.refresh(by: "settle")
        #expect(zone.record(forKey: "sort.books") == held, "the record stays as the other device wrote it")
        #expect(zone.deleted[CloudStandNaming.recordName(for: "sort.books")] == nil, "no removal went out")

        // The rule, pure: a held key is neither saved nor removed, a dropped
        // key still leaves.
        let dropped = CloudChoiceRecord(key: "playbackRate.a", payload: CloudChoicePayload.encode(.double(1.5)),
                                        t: 500, tombstone: false)
        let changes = CloudKitChoiceCarrier.changes(desired: [:], mirror: ["sort.books": held, "playbackRate.a": dropped],
                                                    held: CloudKitChoiceCarrier.heldAsTheyAre(in: unknown),
                                                    known: ["sort.books", "playbackRate.a"])
        #expect(changes.save.isEmpty)
        #expect(changes.remove == ["playbackRate.a"], "\(changes.remove)")
    }

    /// A fetch over several pages puts each page into the mirror at once.
    /// When it does not finish, or the person changes something while it
    /// runs, the runner stores a state that never held those keys: they
    /// are not its to remove.
    @Test("what an unfinished fetch put into the mirror never becomes a deletion; a key the runner held does")
    func whatAnUnfinishedFetchBroughtIsNeverARemoval() {
        func record(_ key: String) -> CloudChoiceRecord {
            CloudChoiceRecord(key: key, payload: CloudChoicePayload.encode(.double(1.5)), t: 500, tombstone: false)
        }
        // The first page of a fetch stands in the mirror; the runner holds
        // one key of its own and stores it.
        let mirror = ["playbackRate.a": record("playbackRate.a"), "playbackRate.b": record("playbackRate.b"),
                      "own": record("own")]
        let unfinished = CloudKitChoiceCarrier.changes(desired: ["own": record("own")], mirror: mirror,
                                                       held: [], known: ["own"])
        #expect(unfinished.remove.isEmpty, "keys the runner never held go out as removals: \(unfinished.remove.sorted())")
        #expect(unfinished.save.isEmpty)
        // After the fetch ran to its end the runner knows them: a key it
        // then drops leaves the cloud as before.
        let settled = CloudKitChoiceCarrier.changes(desired: ["own": record("own"), "playbackRate.a": record("playbackRate.a")],
                                                    mirror: mirror, held: [],
                                                    known: ["own", "playbackRate.a", "playbackRate.b"])
        #expect(settled.remove == ["playbackRate.b"], "\(settled.remove.sorted())")
    }

    @Test("the carrier knows a key only after a whole fetch or a write of its own", .needsTheSources)
    func theCarrierKnowsAKeyOnlyAfterAWholeFetch() throws {
        let carrier = try FetchAnswerTests.squeezedSource("Sources/Networking/CloudKitChoiceCarrier.swift")
        #expect(carrier.contains("let changes = Self.changes(desired: desired, mirror: mirror, held: held, known: known) known.formUnion(desired.keys)"),
                "the removals are not asked against what the runner has held")
        // Known only below the loop over the pages, never inside it.
        let fetch = try #require(carrier.range(of: "private func fetch(by caller: String) async {"))
        let body = String(carrier[fetch.upperBound...])
        let pages = try #require(body.range(of: "more = page.moreComing }"))
        let learned = try #require(body.range(of: "known.formUnion(mirror.keys)"))
        #expect(pages.upperBound <= learned.lowerBound, "a page teaches the carrier its keys before the fetch ran to its end")
        #expect(carrier.components(separatedBy: "known.formUnion(").count - 1 == 2, "the carrier learns keys in another place")
    }

    /// The same entry in the service's form: after a switch from the Mär
    /// sync service to iCloud the blob carries an unknown value as the
    /// service's tag (`rawWire`), not as an unknown "v". It is held too.
    @Test("an entry of an unknown kind in the service's form does not delete the record either")
    func anUnknownEntryInTheServiceFormDeletesNoRecord() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let zone = FakeZone()
        let carrier = carrier(zone, defaults)
        await carrier.refresh(by: "witness")
        let held = CloudChoiceRecord(key: "sort.books", payload: CloudChoicePayload.encode(.string("title")),
                                     t: 1000, tombstone: false)
        zone.foreignWrite(held)
        await carrier.refresh(by: "fetch")
        #expect(entries(carrier.loadBlob())["sort.books"]?.value == .string("title"), "the precondition: the mirror holds the record")

        let fromService: [String: Any] = ["sort.books": ["t": 9000.0, UserChoiceEntry.rawWireKey: ["z": "neu"]]]
        #expect(UserChoiceEntry.from(plist: fromService["sort.books"])?.unknownKind == true,
                "the precondition: the service's tag reads as an unknown kind")
        #expect(CloudKitChoiceCarrier.records(for: fromService).isEmpty, "the precondition: no record is made for it")
        #expect(CloudKitChoiceCarrier.heldAsTheyAre(in: fromService) == ["sort.books"], "the service form is held")
        carrier.storeBlob(fromService)
        await carrier.refresh(by: "settle")
        #expect(zone.record(forKey: "sort.books") == held, "the record stays as the other device wrote it")
        #expect(zone.deleted[CloudStandNaming.recordName(for: "sort.books")] == nil, "no removal went out")
    }

    @Test("a capped key does not come back from the frozen blob; what an older build writes afterwards arrives")
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

    @Test("without an account the key-value store carries the whole")
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

    @Test("a refused write stays in the queue and survives the restart, the fold stays open")
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

    @Test("records, blob and door rows go there and back without loss, every value type exactly")
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

    @Test("the union: per key the younger event time wins, a tie goes to the cloud") @MainActor
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
