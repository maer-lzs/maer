// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CloudKit
import Foundation
@testable import Maer

/// The CloudKit carrier over a fake database: the blob folds into records
/// once, writes go out through the queue and survive a refusal, a foreign
/// change comes in by token and wakes the runner, an expired token starts
/// over, no account means the key-value carrier does the whole job, and
/// the blob stays readable for a device on an older build.
@MainActor
struct CloudKitStandCarrierTests {
    /// A database in a dictionary: a version per write is the token.
    @MainActor
    final class FakeDatabase: CloudZoneDatabase {
        typealias Value = CloudStandRecord
        var available = true
        var zoneEnsured = 0
        var records: [String: (record: CloudStandRecord, version: Int)] = [:]
        var deleted: [String: Int] = [:]
        var version = 0
        var failNextModify: CloudStandFailure?
        /// The cloud refuses every write until this is nil (a record type
        /// missing from the production schema looks like this).
        var refuseEveryModify: CloudStandFailure?
        var expireTokenOnce = false
        var modifies: [(save: [CloudStandRecord], delete: [String])] = []

        func accountAvailable() async -> Bool { available }
        func ensureZone() async throws { zoneEnsured += 1 }
        var subscriptions = 0
        var subscriptionFails = false
        func ensureSubscription() async throws {
            if subscriptionFails { throw CloudStandFailure.transport("no push") }
            subscriptions += 1
        }
        func changes(since token: Data?) async throws -> CloudStandChanges {
            if expireTokenOnce, token != nil {
                expireTokenOnce = false
                throw CloudStandFailure.tokenExpired
            }
            let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? -1
            var out = CloudStandChanges()
            out.changed = records.values.filter { $0.version > since }.map(\.record)
            out.deletedRecordNames = deleted.filter { $0.value > since }.map { CloudStandNaming.recordName(for: $0.key) }
            out.token = Data(String(version).utf8)
            return out
        }
        /// The next `modify` SUSPENDS after it was called and before it
        /// stores anything, until the witness lets it go. This is the one
        /// way to open the window in which a second write lands while the
        /// first is in flight; a fake that never suspends can never show
        /// what the carrier does with such a write, and a witness over it
        /// would be a green lid.
        var holdNextModify = false
        private var held: CheckedContinuation<Void, Never>?
        private var waitingForHold: CheckedContinuation<Void, Never>?
        /// Returns once the held `modify` has been entered.
        func modifyHeld() async {
            if held != nil { return }
            await withCheckedContinuation { waitingForHold = $0 }
        }
        func releaseModify() {
            let go = held
            held = nil
            go?.resume()
        }

        func modify(save: [CloudStandRecord], delete itemIds: [String]) async throws {
            if holdNextModify {
                holdNextModify = false
                await withCheckedContinuation { continuation in
                    held = continuation
                    waitingForHold?.resume()
                    waitingForHold = nil
                }
            }
            if let failure = failNextModify {
                failNextModify = nil
                throw failure
            }
            if let failure = refuseEveryModify { throw failure }
            modifies.append((save, itemIds))
            for record in save {
                version += 1
                records[record.itemId] = (record, version)
            }
            for id in itemIds {
                version += 1
                records[id] = nil
                deleted[id] = version
            }
        }
        /// Another device wrote a record.
        func foreignWrite(_ record: CloudStandRecord) {
            version += 1
            records[record.itemId] = (record, version)
        }
    }

    private func suite() -> (UserDefaults, String) {
        let name = "cloud-stand-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func carrier(database: FakeDatabase, defaults: UserDefaults, blob: InMemoryCloudStore = InMemoryCloudStore())
        -> (CloudKitStandCarrier, KeyValueStandCarrier) {
        let keyValue = KeyValueStandCarrier(cloud: blob, spacingSeconds: 0)
        return (CloudKitStandCarrier(database: database, fallback: keyValue, defaults: defaults), keyValue)
    }

    @Test("the blob folds into records once, after that the cloud is the pot and the blob is only read")
    func migratesOnceThenReadsTheBlob() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let blob = InMemoryCloudStore()
        let (carrier, keyValue) = carrier(database: db, defaults: defaults, blob: blob)
        keyValue.write(upserts: ["rss:a": [100, 1_000, 3_600], "rss:b": [0, 900]], removing: [], by: "old build")
        #expect(carrier.name == "cloudkit migrating")

        var changes = 0
        carrier.start { changes += 1 }
        await carrier.refresh(by: "witness")
        #expect(db.zoneEnsured == 1)
        #expect(db.records.count == 2, "the blob folded in")
        #expect(db.records["rss:b"]?.record.tombstone == true)
        #expect(carrier.name == "cloudkit")
        #expect(changes == 1, "the read-back is a change for the runner")
        #expect(carrier.stands()["rss:a"] == [100, 1_000, 3_600])

        // From now on a write goes to the cloud, not into the blob.
        carrier.write(upserts: ["rss:c": [5, 2_000]], removing: [], by: "play")
        await carrier.refresh(by: "witness")
        #expect(db.records["rss:c"] != nil)
        #expect(keyValue.stands()["rss:c"] == nil, "the blob is read only after the fold")

        // An older build still writes the blob: its newer stand is heard.
        keyValue.write(upserts: ["rss:a": [200, 5_000, 3_600]], removing: [], by: "old build")
        #expect(carrier.stands()["rss:a"] == [200, 5_000, 3_600])
        #expect(carrier.stands()["rss:c"] == [5, 2_000])
    }

    /// The way back: an older build reads the token and the blobs under
    /// their old names. After a round of this build neither stands there,
    /// so an older build fetches from the start; the migration mark stands.
    @Test("after a pass the token and the image are not under the old names, the mark of the fold is set")
    func theOldNamesStayEmpty() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let (carrier, _) = carrier(database: db, defaults: defaults)
        carrier.write(upserts: ["rss:a": [5, 1_000]], removing: [], by: "play")
        carrier.start {}
        await carrier.refresh(by: "witness")
        await CarrierStandRows.matching(defaults).awaitPendingWrites()
        #expect(defaults.data(forKey: CloudKitStandCarrier.tokenKey) != nil, "the precondition: the round kept a token")
        #expect(defaults.bool(forKey: CloudKitStandCarrier.migratedKey))
        let old = defaults.dictionaryRepresentation().keys.filter { CarrierStandRows.isLegacyOwner($0) || $0 == CarrierStandRows.legacyToken }
        #expect(old.isEmpty, "an older build finds \(old.sorted())")
        #expect(CarrierStandRows.matching(defaults).rows(CloudKitStandCarrier.mirrorKey)["rss:a"] == [5, 1_000])
        carrier.stop()
    }

    @Test("a foreign change comes in by token and wakes the runner; no change, no event")
    func foreignChangeArrivesByToken() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let (carrier, _) = carrier(database: db, defaults: defaults)
        var changes = 0
        carrier.start { changes += 1 }
        await carrier.refresh(by: "witness")
        #expect(changes == 0, "an empty cloud is no change")
        db.foreignWrite(CloudStandRecord(itemId: "rss:x", entry: [42, 7_000], tombstone: false))
        await carrier.refresh(by: "tick")
        #expect(changes == 1)
        #expect(carrier.stands()["rss:x"] == [42, 7_000])
        await carrier.refresh(by: "tick")
        #expect(changes == 1, "nothing new, no event")
        // A record deleted on the server leaves the mirror.
        try? await db.modify(save: [], delete: ["rss:x"])
        await carrier.refresh(by: "tick")
        #expect(carrier.stands()["rss:x"] == nil)
    }

    @Test("a refused write stays in the queue, survives the restart and goes out on the next pass")
    func queueSurvivesARefusal() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let (first, _) = carrier(database: db, defaults: defaults)
        first.start {}
        await first.refresh(by: "witness")
        // Refused for as long as this process lives: since the flushes form
        // a chain, the write's own flush and the tick's both run before the
        // check below, and a failure that is consumed by the first would let
        // the second land, which is not the case this witness is about.
        db.refuseEveryModify = .transport("timeout")
        first.write(upserts: ["rss:q": [10, 3_000]], removing: ["rss:gone"], by: "play")
        await first.refresh(by: "tick")
        #expect(db.records["rss:q"] == nil, "the cloud refused")
        #expect(first.stands()["rss:q"] == [10, 3_000], "the mirror already holds it")

        // A new process over the same defaults, and the cloud takes writes
        // again: the queue is still there.
        db.refuseEveryModify = nil
        let (second, _) = carrier(database: db, defaults: defaults)
        second.start {}
        await second.refresh(by: "start")
        #expect(db.records["rss:q"]?.record.entry == [10, 3_000])
        #expect(db.modifies.last?.delete == ["rss:gone"])
    }

    /// The window the answer to the position chain named: `write` starts
    /// its flush unchained, the mirror is set before the cloud accepts, and
    /// the flush used to clear the queue by id when `modify` returned. A
    /// write that landed during that `modify` therefore vanished from the
    /// queue while the mirror said "stored", and the runner never re-sent
    /// it. The fake holds `modify` open so the second write demonstrably
    /// lands inside the window.
    @Test("a write that arrives during a running modify is not wiped away with it, but goes out in the next batch")
    func aWriteDuringAFlightIsNotWipedWithIt() async throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let (carrier, _) = carrier(database: db, defaults: defaults)
        carrier.start {}
        await carrier.refresh(by: "witness")

        db.holdNextModify = true
        carrier.write(upserts: ["rss:a": [10, 3_000]], removing: [], by: "play")
        await db.modifyHeld()
        // In flight: the first value is on its way, and a newer one lands.
        carrier.write(upserts: ["rss:a": [20, 4_000]], removing: [], by: "play")
        #expect(carrier.stands()["rss:a"] == [20, 4_000], "the mirror already reports the newer value")
        db.releaseModify()

        // The held flush finishes its batch and, with the queue still holding
        // the newer value, sends it in the next one. Bounded wait, no sleep
        // of a fixed length: the second modify is the signal.
        for _ in 0..<200 where db.modifies.count < 2 { await Task.yield() }
        try #require(db.modifies.count >= 2, "the newer value never went out; it was wiped with the first batch")
        #expect(db.records["rss:a"]?.record.entry == [20, 4_000], "the cloud holds what the mirror says")
        #expect(db.modifies[0].save.map(\.entry) == [[10, 3_000]])
        #expect(db.modifies[1].save.map(\.entry) == [[20, 4_000]])
    }

    @Test("if the cloud refuses every write, the fold stays open and the blob keeps carrying; only acceptance closes it")
    func refusedFoldKeepsTheBlobAsThePot() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        db.refuseEveryModify = .transport("ck 12 Cannot create new type Stand in production schema")
        let blob = InMemoryCloudStore()
        let (first, firstKeyValue) = carrier(database: db, defaults: defaults, blob: blob)
        firstKeyValue.write(upserts: ["rss:a": [100, 1_000, 3_600]], removing: [], by: "old build")
        first.start {}
        await first.refresh(by: "start")
        #expect(db.records.isEmpty, "the cloud took nothing")
        #expect(first.name == "cloudkit migrating", "the fold is not done")
        #expect(!first.fellBack, "a refusal is not a missing account")

        // A write while the fold is open still lands in the blob, so the
        // other device hears it.
        first.write(upserts: ["rss:b": [5, 2_000]], removing: [], by: "play")
        await first.refresh(by: "tick")
        #expect(firstKeyValue.stands()["rss:b"] == [5, 2_000], "the blob is still the pot")
        #expect(first.stands()["rss:b"] == [5, 2_000])
        #expect(first.name == "cloudkit migrating")

        // A new process over the same defaults: still open.
        let (second, secondKeyValue) = carrier(database: db, defaults: defaults, blob: blob)
        second.start {}
        await second.refresh(by: "start")
        #expect(second.name == "cloudkit migrating")

        // The schema arrives: the fold completes, the blob turns read only.
        db.refuseEveryModify = nil
        await second.refresh(by: "tick")
        #expect(db.records["rss:a"]?.record.entry == [100, 1_000, 3_600])
        #expect(db.records["rss:b"]?.record.entry == [5, 2_000])
        #expect(second.name == "cloudkit")
        second.write(upserts: ["rss:c": [7, 3_000]], removing: [], by: "play")
        await second.refresh(by: "tick")
        #expect(secondKeyValue.stands()["rss:c"] == nil, "after the fold the blob is read only")
        #expect(db.records["rss:c"] != nil)
    }

    @Test("the push is an accelerator: ordered once, it survives the restart, and without it everything keeps running")
    func theSilentPushIsAnAccelerator() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let (first, _) = carrier(database: db, defaults: defaults)
        first.start {}
        await first.refresh(by: "start")
        #expect(db.subscriptions == 1, "asked once")
        await first.refresh(by: "tick")
        #expect(db.subscriptions == 1, "not again in the same run")
        // A new process over the same defaults does not ask again either.
        let (second, _) = carrier(database: db, defaults: defaults)
        second.start {}
        await second.refresh(by: "start")
        #expect(db.subscriptions == 1, "the ask survives a restart")

        // And a cloud that refuses the subscription costs speed, not
        // correctness: the round still folds, writes and fetches.
        let (otherDefaults, otherName) = suite()
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let refusing = FakeDatabase()
        refusing.subscriptionFails = true
        let (third, _) = carrier(database: refusing, defaults: otherDefaults)
        third.start {}
        third.write(upserts: ["rss:p": [3, 4]], removing: [], by: "play")
        await third.refresh(by: "start")
        #expect(refusing.records["rss:p"] != nil, "the write went out without a push")
        #expect(!third.fellBack, "a refused push is not a missing account")
    }

    @Test("a push carries nothing: it only wakes the fetch")
    func aPushCarriesNothing() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let (carrier, _) = carrier(database: db, defaults: defaults)
        var changes = 0
        carrier.start { changes += 1 }
        await carrier.refresh(by: "start")
        db.foreignWrite(CloudStandRecord(itemId: "rss:pushed", entry: [7, 8_000], tombstone: false))
        // What a push does: exactly what a poll does, only sooner.
        await carrier.refresh(by: "push")
        #expect(carrier.stands()["rss:pushed"] == [7, 8_000])
        #expect(changes == 1)
    }

    @Test("without an account the key-value store carries, as today")
    func noAccountFallsBack() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        db.available = false
        let (carrier, keyValue) = carrier(database: db, defaults: defaults)
        carrier.start {}
        await carrier.refresh(by: "start")
        #expect(carrier.fellBack)
        #expect(carrier.name == "kvs fallback")
        carrier.write(upserts: ["rss:k": [1, 2]], removing: [], by: "play")
        #expect(keyValue.stands()["rss:k"] == [1, 2])
        #expect(db.modifies.isEmpty)
        #expect(carrier.stands()["rss:k"] == [1, 2])
    }

    @Test("an expired token starts over, nothing is lost")
    func expiredTokenStartsOver() async {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let db = FakeDatabase()
        let (carrier, _) = carrier(database: db, defaults: defaults)
        carrier.start {}
        await carrier.refresh(by: "start")
        db.foreignWrite(CloudStandRecord(itemId: "rss:e", entry: [3, 4], tombstone: false))
        db.expireTokenOnce = true
        await carrier.refresh(by: "tick")
        #expect(carrier.stands()["rss:e"] == [3, 4])
    }

    @Test("the union: per item the newer moment wins, on a tie the cloud")
    func unionPrefersTheNewerMoment() {
        let cloud: [String: [Double]] = ["a": [1, 100], "b": [2, 200], "c": [3, 300]]
        let legacy: [String: [Double]] = ["a": [9, 50], "b": [8, 200], "d": [7, 400]]
        let out = CloudKitStandCarrier.union(cloud: cloud, legacy: legacy)
        #expect(out["a"] == [1, 100], "the cloud is newer")
        #expect(out["b"] == [2, 200], "a tie goes to the cloud")
        #expect(out["c"] == [3, 300])
        #expect(out["d"] == [7, 400], "only the blob knows d")
    }

    @Test("the record: entry there and back, name is a hash")
    func recordRoundTrip() {
        #expect(CloudStandNaming.recordName(for: "rss:x").count == 64)
        #expect(CloudStandNaming.recordName(for: "rss:x") != CloudStandNaming.recordName(for: "rss:y"))
        #expect(CloudZoneFailures.failure(from: CloudStandFailure.transport("x")) == .transport("x"))
    }

    @Test("the error translator: a partial failure names the error of the first record, with the server's sentence; a refused record is an error of the write")
    func failureTranslation() {
        let missingType = CKError(.invalidArguments, userInfo: ["ServerErrorDescription": "Cannot create new type Stand in production schema"])
        #expect(CloudZoneFailures.failure(from: missingType) == .transport("ck 12 Cannot create new type Stand in production schema"))
        let recordID = CKRecord.ID(recordName: "r")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [recordID: missingType]])
        #expect(CloudZoneFailures.failure(from: partial) == .transport("ck 12 Cannot create new type Stand in production schema"))
        #expect(CloudZoneFailures.failure(from: CKError(.notAuthenticated)) == .noAccount)
        #expect(CloudZoneFailures.firstRefusal([.success(()), .failure(missingType)]) != nil)
        #expect(CloudZoneFailures.firstRefusal([.success(()), .success(())]) == nil)
    }
}
#endif
