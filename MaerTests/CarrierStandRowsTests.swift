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

    /// The way back holds only while no build writes the old names again:
    /// the token and the version of this build have names of their own,
    /// and no source writes a blob of stands into the defaults.
    @Test("kein Bau schreibt die alten Namen wieder: Token und Version heissen neu, kein Ganzschrieb eines Abbilds in die Voreinstellungen", .needsTheSources)
    func theOldNamesAreNeverWrittenAgain() throws {
        #expect(CloudKitStandCarrier.tokenKey != CarrierStandRows.legacyToken)
        #expect(MaerSyncSession.versionKey != CarrierStandRows.legacyScopedVersion)
        #expect(!MaerSyncSession.identityKeys.contains { CarrierStandRows.isLegacyOwner($0) || $0 == CarrierStandRows.legacyScopedVersion })
        let sources = SourceTree.root.appendingPathComponent("Sources")
        var named: [String] = []
        var blobReaders: [String] = []
        for file in SourceTree.files(under: sources) where file.pathExtension == "swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("\"cloudStandToken\"") || code.contains("\"maerSyncStandsVersion\"") { named.append(file.lastPathComponent) }
            if code.contains("[String: [Double]].self") { blobReaders.append(file.lastPathComponent) }
            if file.lastPathComponent == "StandCarrier.swift" {
                #expect(!code.contains("func save(_ value: [String: [Double]]"), "the stand blob writer came back")
            }
        }
        #expect(named == ["CarrierStandRows.swift"], "the old names stand outside the move: \(named.sorted())")
        #expect(blobReaders == ["CarrierStandRows.swift"], "a stand blob is read outside the move: \(blobReaders.sorted())")
    }
}
#endif
