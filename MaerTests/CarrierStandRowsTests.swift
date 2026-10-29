// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stands of the carriers live in rows: the blobs move once, with the
/// token and the versions an older build would read beside them; the
/// migration mark stays. One owner's write leaves the other owners' rows.
@MainActor
struct CarrierStandRowsTests {
    private func place() throws -> (UserDefaults, String, String) {
        let suite = "carrier-stand-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("carrier-stand-\(UUID().uuidString).sqlite").path
        return (defaults, suite, path)
    }

    private func blob(_ stands: [String: [Double]]) throws -> Data {
        try JSONEncoder().encode(stands)
    }

    private func storedRows(_ path: String) throws -> [String: [Double]] {
        let reader = try #require(try MaerDatabase(path: path).readerNow())
        return try KeyedRowStore<[Double]>.loadNow(table: .carrierStand, reader: reader).rows
    }

    @Test("der erste Zugriff zieht die Bloecke beider Traeger und aller Identitaeten in Zeilen; Blob, Token und Version gehen, die Marke der Einfaltung bleibt")
    func theFirstAccessMovesTheBlobs() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = "sync.example/acc"
        defaults.set(try blob(["rss:a": [10, 1_000]]), forKey: "cloudStandMirror")
        defaults.set(try blob(["rss:q": [20, 2_000]]), forKey: "cloudStandQueue")
        defaults.set(try blob(["rss:s": [30, 3_000]]), forKey: "maerSyncStands.\(scope)")
        defaults.set(try blob(["rss:p": [40, 4_000]]), forKey: "maerSyncStandsQueue")
        defaults.set(["rss:gone"], forKey: "maerSyncStandsQueueRemovals")
        defaults.set(Data([1, 2]), forKey: CarrierStandRows.legacyToken)
        defaults.set("v7", forKey: "maerSyncStandsVersion.\(scope)")
        defaults.set("v1", forKey: "maerSyncStandsVersion")
        defaults.set(true, forKey: CloudKitStandCarrier.migratedKey)

        let rows = CarrierStandRows(database: MaerDatabase(path: path), defaults: defaults)
        #expect(rows.rows("cloudStandMirror") == ["rss:a": [10, 1_000]], "the mirror is in memory at once")
        #expect(rows.rows("maerSyncStands.\(scope)") == ["rss:s": [30, 3_000]])
        #expect(rows.rows("maerSyncStandsQueue") == ["rss:p": [40, 4_000]])
        await rows.awaitPendingWrites()

        #expect(try storedRows(path).count == 4, "the rows did not land")
        for key in ["cloudStandMirror", "cloudStandQueue", "maerSyncStands.\(scope)", "maerSyncStandsQueue",
                    CarrierStandRows.legacyToken, "maerSyncStandsVersion.\(scope)", "maerSyncStandsVersion"] {
            #expect(defaults.object(forKey: key) == nil, "an older build still finds \(key)")
        }
        #expect(defaults.bool(forKey: CloudKitStandCarrier.migratedKey), "the migration mark went; an older build would send the blob over the cloud")
        #expect(defaults.stringArray(forKey: "maerSyncStandsQueueRemovals") == ["rss:gone"], "a key that is no blob went")
        #expect(defaults.bool(forKey: CarrierStandRows.movedKey))

        let later = CarrierStandRows(database: MaerDatabase(path: path), defaults: defaults)
        #expect(later.rows("cloudStandQueue") == ["rss:q": [20, 2_000]], "the next start reads the rows")
    }

    @Test("ein abgebrochener Umzug fuehrt Blob und Zeilen zusammen, die Zeilen gewinnen")
    func aBrokenMoveMerges() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = CarrierStandRows(database: MaerDatabase(path: path), defaults: defaults)
        first.set("cloudStandMirror", ["rss:a": [99, 9_000]])
        await first.awaitPendingWrites()
        // The rows stand, the mark of the move does not: the blob is found again.
        defaults.removeObject(forKey: CarrierStandRows.movedKey)
        defaults.set(try blob(["rss:a": [1, 100], "rss:b": [2, 200]]), forKey: "cloudStandMirror")

        let again = CarrierStandRows(database: MaerDatabase(path: path), defaults: defaults)
        #expect(again.rows("cloudStandMirror") == ["rss:a": [99, 9_000], "rss:b": [2, 200]])
        await again.awaitPendingWrites()
        #expect(defaults.object(forKey: "cloudStandMirror") == nil)
    }

    @Test("ein Besitzer schreibt nur seine Zeilen; Umbenennen traegt sie zum neuen Namen")
    func oneOwnerLeavesTheOthers() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows(database: MaerDatabase(path: path), defaults: defaults)
        rows.set("maerSyncStands.a", ["rss:1": [1, 1]])
        rows.set("maerSyncStands.b", ["rss:2": [2, 2]])
        rows.set("maerSyncStands.a", [:])
        rows.rename(owner: "maerSyncStands.b", to: "maerSyncStands.c")
        await rows.awaitPendingWrites()
        let stored = try storedRows(path)
        #expect(stored == ["maerSyncStands.c\u{1F}rss:2": [2, 2]], "\(stored)")
    }

    /// A table whose columns are not `key` and `payload`: the start read
    /// fails as a whole, and the file is no fresh install.
    private func unreadable(_ path: String) async throws -> MaerDatabase {
        let database = MaerDatabase(path: path)
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE carrier_stand (other TEXT)")
        try await connection.execute("INSERT INTO carrier_stand (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        return database
    }

    /// The table readable again, with the given rows.
    private func healed(_ database: MaerDatabase, rows: [String: [Double]]) async throws {
        let connection = try database.connection()
        try await connection.execute("DROP TABLE carrier_stand")
        let store = try await KeyedRowStore<[Double]>(connection: connection, table: .carrierStand)
        _ = try await store.apply(previous: [:], current: rows)
    }

    /// The invariant of the move: rows the start could not read are an
    /// unknown mirror, not an empty one. The token goes, so the next round
    /// fetches from the start, and once the rows are read they join the
    /// mirror instead of leaving with the next write.
    @Test("kann der Start die Zeilen nicht lesen, faellt das Token des CloudKit-Traegers, und gelesen geht keine Zeile verloren")
    func anUnreadStartDropsTheTokenAndLosesNoRow() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CarrierStandRows.movedKey)
        defaults.set(Data("7".utf8), forKey: CloudKitStandCarrier.tokenKey)
        let database = try await unreadable(path)
        let rows = CarrierStandRows(database: database, defaults: defaults)
        let carrier = CloudKitStandCarrier(database: CloudKitStandCarrierTests.FakeDatabase(),
                                           fallback: KeyValueStandCarrier(cloud: InMemoryCloudStore(), spacingSeconds: 0),
                                           defaults: defaults, rows: rows)
        #expect(rows.unread, "the precondition: the start read failed")
        #expect(defaults.data(forKey: CloudKitStandCarrier.tokenKey) == nil, "the token stayed over an unknown mirror")

        try await healed(database, rows: [CarrierStandRows.key(CloudKitStandCarrier.mirrorKey, "rss:old"): [1, 100]])
        carrier.write(upserts: ["rss:new": [2, 200]], removing: [], by: "play")
        await rows.awaitPendingWrites()
        #expect(!rows.unread)
        #expect(carrier.stands()["rss:old"] == [1, 100], "the read row did not join the mirror")
        let stored = try storedRows(path)
        #expect(stored[CarrierStandRows.key(CloudKitStandCarrier.mirrorKey, "rss:old")] == [1, 100], "a read row left with the write")
        #expect(stored[CarrierStandRows.key(CloudKitStandCarrier.mirrorKey, "rss:new")] == [2, 200])
        carrier.stop()
    }

    @Test("kann der Start die Zeilen nicht lesen, faellt die Version des Mär-Sync, und gelesen geht keine Zeile verloren")
    func anUnreadStartDropsTheVersionAndLosesNoRow() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = MaerSyncIdentityTests.identityA
        defaults.set(true, forKey: CarrierStandRows.movedKey)
        defaults.set("v7", forKey: identity.keyed(MaerSyncSession.versionKey))
        let database = try await unreadable(path)
        let rows = CarrierStandRows(database: database, defaults: defaults)
        let session = MaerSyncSession(transport: MaerSyncCarrierTests.FakeTransport(), announcer: MaerSyncCarrierTests.FakeAnnouncer(),
                                      access: { MaerSyncIdentityTests.accessA }, identity: { identity },
                                      deviceId: { "dev-a" }, defaults: defaults, rows: rows)
        #expect(rows.unread, "the precondition: the start read failed")
        #expect(defaults.string(forKey: identity.keyed(MaerSyncSession.versionKey)) == nil, "the version stayed over unknown stands")

        let owner = identity.keyed(MaerSyncSession.mirrorKey)
        try await healed(database, rows: [CarrierStandRows.key(owner, "rss:old"): [1, 100]])
        session.enqueue(upserts: ["rss:new": [2, 200]], removing: [], by: "witness")
        await rows.awaitPendingWrites()
        #expect(session.stands["rss:old"] == [1, 100], "the read row did not join the stands")
        #expect(try storedRows(path)[CarrierStandRows.key(owner, "rss:old")] == [1, 100], "a read row left with the write")
    }

    @Test("nur die Bloecke der Staende gelten als alter Besitzer, nicht die Nachbarschluessel")
    func theLegacyOwnersAreTheBlobs() {
        for key in ["cloudStandMirror", "cloudStandQueue", "maerSyncStands", "maerSyncStands.x/y", "maerSyncStandsQueue", "maerSyncStandsQueue.x"] {
            #expect(CarrierStandRows.isLegacyOwner(key), "\(key)")
        }
        for key in ["maerSyncStandsQueueRemovals", "maerSyncStandsQueueRemovals.x", "maerSyncStandsVersion.x",
                    "cloudStandQueueRemovals", "cloudStandToken", "maerSyncPlaylists"] {
            #expect(!CarrierStandRows.isLegacyOwner(key), "\(key)")
        }
    }

    /// Whether a source reads a carrier's mirror blob from the defaults, in
    /// either of its two forms. Encoded: the shape decoded (`….self`) AND a
    /// read of data from the defaults in the same text, through the house
    /// door or not. Property list: a read of an object cast to the shape in
    /// the same expression. A document of a store of its own (`Ablage`) has
    /// the shape, not the read.
    nonisolated static func readsAMirrorBlob(_ code: String) -> Bool {
        let shapes = ["[String: [Double]]", "[String: [String]]", "[String: Value]"]
        let decoded = shapes.contains { code.contains($0 + ".self") }
        let readsData = ["defaults.data(", ".data(forKey:", "AppStorageKeys.data("].contains { code.contains($0) }
        let cast = shapes.map { NSRegularExpression.escapedPattern(for: "as? " + $0) }.joined(separator: "|")
        let castRead = code.range(of: #"(\.object\(forKey:|AppStorageKeys\.object\()[^\n]*\)\s*("# + cast + ")",
                                  options: .regularExpression) != nil
        return (decoded && readsData) || castRead
    }

    @Test("der Leser der Abbilder sieht Form und Voreinstellung zusammen, ein Dokument einer Ablage nicht")
    func theBlobReaderNeedsShapeAndDefaults() {
        #expect(Self.readsAMirrorBlob("let d = defaults.data(forKey: k)\nJSONDecoder().decode([String: [Double]].self, from: d)"))
        #expect(Self.readsAMirrorBlob("store.data(forKey: k).map { try? JSONDecoder().decode([String: Value].self, from: $0) }"))
        #expect(!Self.readsAMirrorBlob("ablage.loadNow([String: [String]].self, name: document)"), "a store's own document")
        #expect(!Self.readsAMirrorBlob("guard let data = defaults.data(forKey: key)\ndecode([String].self, from: data)"), "a list, no mirror")
        #expect(Self.readsAMirrorBlob("guard let d = AppStorageKeys.data(k) else { return }\ndecode([String: [Double]].self, from: d)"),
                "the house door of data")
        #expect(Self.readsAMirrorBlob("let m = AppStorageKeys.object(k) as? [String: [String]]"), "the house door of objects")
        #expect(Self.readsAMirrorBlob("if let v = defaults.object(forKey: key) as? [String: Value] {"), "the property list")
        #expect(!Self.readsAMirrorBlob("let n = defaults.object(forKey: k) as? Int\nlet m: [String: [String]] = [:]"),
                "an object of another shape")
        #expect(!Self.readsAMirrorBlob("let m = defaults.dictionary(forKey: k) as? [String: [String]]"), "no object read")
    }

    /// The way back holds only while no build writes the old names again:
    /// the tokens and the version of this build have names of their own,
    /// and no source writes a blob of a mirror into the defaults.
    @Test("kein Bau schreibt die alten Namen wieder: Token und Version heissen neu, kein Ganzschrieb eines Abbilds in die Voreinstellungen", .needsTheSources)
    func theOldNamesAreNeverWrittenAgain() throws {
        let tokens = [CloudKitStandCarrier.tokenKey, CloudKitChoiceCarrier.tokenKey, CloudKitPlaylistCarrier.tokenKey,
                      CloudKitStatsCarrier.tokenKey]
        let legacy = CarrierRowsSpec.stands.legacyTokens + CarrierRowsSpec.records.legacyTokens
        #expect(Set(tokens).isDisjoint(with: legacy), "a token of this build carries an old name")
        #expect(legacy.count == 4, "the fence knows four old tokens")
        let versions = CarrierRowsSpec.stands.legacyScopedVersions + CarrierRowsSpec.documents.legacyScopedVersions
        #expect(versions.count == 3, "the fence knows three old versions")
        #expect(Set([MaerSyncSession.versionKey, MaerSyncSession.playlistsVersionKey, MaerSyncSession.choicesVersionKey])
            .isDisjoint(with: versions), "a version of this build carries an old name")
        #expect(!MaerSyncSession.identityKeys.contains { key in
            CarrierStandRows.isLegacyOwner(key) || CarrierDocumentRows.isLegacyOwner(key) || versions.contains(key)
        }, "an old name is kept per identity in the defaults")
        let sources = SourceTree.root.appendingPathComponent("Sources")
        var named: [String] = []
        var blobReaders: [String] = []
        for file in SourceTree.files(under: sources) where file.pathExtension == "swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if (legacy + versions).contains(where: { code.contains("\"\($0)\"") }) {
                named.append(file.lastPathComponent)
            }
            if Self.readsAMirrorBlob(code) {
                blobReaders.append(file.lastPathComponent)
            }
            if file.lastPathComponent == "StandCarrier.swift" {
                #expect(!code.contains("func save(_ value:") && !code.contains("func saveRows("), "a mirror blob writer came back")
            }
        }
        #expect(named == ["CarrierRows.swift"], "the old names stand outside the move: \(named.sorted())")
        #expect(blobReaders == ["CarrierRows.swift"], "a mirror blob is read outside the move: \(blobReaders.sorted())")
    }
}
#endif
