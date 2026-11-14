// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The mirrors and queues of the choice, playlist and stats carriers live
/// in rows like the stands: the blobs move once with the three tokens, the
/// migration marks stay, and a start that cannot read the rows is an
/// unknown mirror, not an empty one.
@MainActor
struct CarrierRecordRowsTests {
    private func place() throws -> (UserDefaults, String, String) {
        let suite = "carrier-record-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("carrier-record-\(UUID().uuidString).sqlite").path
        return (defaults, suite, path)
    }

    private func storedRows(_ path: String) throws -> [String: [String]] {
        let reader = try #require(try MaerDatabase(path: path).readerNow())
        return try KeyedRowStore<[String]>.loadNow(table: .carrierRecord, reader: reader).rows
    }

    private func choiceRow(_ key: String, _ value: String, t: Double) -> [String: [String]] {
        CloudKitChoiceCarrier.rows(of: [key: CloudChoiceRecord(key: key, payload: CloudChoicePayload.encode(.string(value)),
                                                               t: t, tombstone: false)])
    }

    @Test("the first access moves the blocks of the choices, playlists and statistics into rows; the three tokens go, the marks of the folding stay")
    func theFirstAccessMovesTheRecordBlobs() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let owners = ["cloudChoiceMirror", "cloudChoiceQueue", "cloudPlaylistMirror", "cloudPlaylistQueue",
                      "cloudStatsMirror", "cloudStatsQueue"]
        for (index, owner) in owners.enumerated() {
            defaults.set(try JSONEncoder().encode(["k\(index)": ["\(index)", "0", "eA=="]]), forKey: owner)
        }
        for token in ["cloudChoiceToken", "cloudPlaylistToken", "cloudStatsToken"] { defaults.set(Data([1]), forKey: token) }
        for mark in [CloudKitChoiceCarrier.migratedKey, CloudKitPlaylistCarrier.migratedKey, CloudKitStatsCarrier.migratedKey] {
            defaults.set(true, forKey: mark)
        }
        defaults.set(["gone"], forKey: CloudKitChoiceCarrier.removalsKey)

        let rows = CarrierRecordRows(database: MaerDatabase(path: path), defaults: defaults)
        #expect(rows.rows("cloudPlaylistQueue") == ["k3": ["3", "0", "eA=="]], "the queue is in memory at once")
        await rows.awaitPendingWrites()
        #expect(try storedRows(path).count == 6, "the rows did not land")
        for key in owners + ["cloudChoiceToken", "cloudPlaylistToken", "cloudStatsToken"] {
            #expect(defaults.object(forKey: key) == nil, "an older build still finds \(key)")
        }
        for mark in [CloudKitChoiceCarrier.migratedKey, CloudKitPlaylistCarrier.migratedKey, CloudKitStatsCarrier.migratedKey] {
            #expect(defaults.bool(forKey: mark), "\(mark) went; an older build would send the blob over the cloud")
        }
        #expect(defaults.stringArray(forKey: CloudKitChoiceCarrier.removalsKey) == ["gone"])
        #expect(defaults.bool(forKey: CarrierRecordRows.movedKey))
        #expect(!defaults.bool(forKey: CarrierStandRows.movedKey), "the records moved the stands' mark")
    }

    @Test("the record rows and the states are separate tables: a move does not take the blocks of the other")
    func theTwoKindsMoveApart() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(["rss:a": [1.0, 100]]), forKey: "cloudStandMirror")
        defaults.set(try JSONEncoder().encode(["k": ["1", "0", "eA=="]]), forKey: "cloudChoiceMirror")
        let records = CarrierRecordRows(database: MaerDatabase(path: path), defaults: defaults)
        #expect(records.rows("cloudChoiceMirror") == ["k": ["1", "0", "eA=="]])
        await records.awaitPendingWrites()
        #expect(defaults.object(forKey: "cloudStandMirror") != nil, "the records took the stands' blob")
        #expect(CarrierRecordRows.isLegacyOwner("cloudStatsQueue") && !CarrierRecordRows.isLegacyOwner("cloudStandQueue"))
        #expect(!CarrierRecordRows.isLegacyOwner(CloudKitChoiceCarrier.removalsKey) && !CarrierRecordRows.isLegacyOwner(CloudKitChoiceCarrier.foldedKey))
    }

    /// A table whose columns are not `key` and `payload`: the start read
    /// fails as a whole, and the file is no fresh install.
    private func unreadable(_ path: String) async throws -> MaerDatabase {
        let database = MaerDatabase(path: path)
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE carrier_record (other TEXT)")
        try await connection.execute("INSERT INTO carrier_record (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        return database
    }

    @Test("if the start cannot read the rows, the token of the choices carrier drops, and once read no row is lost")
    func anUnreadStartDropsTheChoiceTokenAndLosesNoRow() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CarrierRecordRows.movedKey)
        defaults.set(Data("7".utf8), forKey: CloudKitChoiceCarrier.tokenKey)
        let database = try await unreadable(path)
        let rows = CarrierRecordRows(database: database, defaults: defaults)
        let carrier = CloudKitChoiceCarrier(database: CloudKitChoiceCarrierTests.FakeZone(),
                                            fallback: KeyValueChoiceCarrier(store: InMemoryCloudStore()),
                                            defaults: defaults, rows: rows)
        #expect(rows.unread, "the precondition: the start read failed")
        #expect(defaults.data(forKey: CloudKitChoiceCarrier.tokenKey) == nil, "the token stayed over an unknown mirror")

        let connection = try database.connection()
        try await connection.execute("DROP TABLE carrier_record")
        let store = try await KeyedRowStore<[String]>(connection: connection, table: .carrierRecord)
        let old = choiceRow("choice.old", "x", t: 100)
        _ = try await store.apply(previous: [:], current: [CarrierRecordRows.key(CloudKitChoiceCarrier.mirrorKey, "choice.old"): old["choice.old"]!])

        carrier.storeBlob(["choice.new": UserChoiceEntry(value: .string("y"), t: 200).plist])
        await rows.awaitPendingWrites()
        #expect(!rows.unread)
        #expect(UserChoiceEntry.from(plist: carrier.loadBlob()["choice.old"])?.t == 100, "the read row did not join the mirror")
        #expect(try storedRows(path)[CarrierRecordRows.key(CloudKitChoiceCarrier.mirrorKey, "choice.old")] != nil, "a read row left with the write")
        carrier.stop()
    }
}
#endif
