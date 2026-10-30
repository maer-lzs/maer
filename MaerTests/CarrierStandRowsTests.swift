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

    /// The keys the move takes out of the defaults, from every spec: whole
    /// owners, owners per identity (`<owner>.<scope>`), and the prefixes of
    /// keys with one entry each.
    nonisolated static let legacySpecs: [CarrierRowsSpec] = [.stands, .records, .stamps, .documents, .jumpRings, .bookmarks]

    nonisolated static func isLegacyKey(_ key: String) -> Bool {
        legacySpecs.contains { spec in
            spec.legacyOwners.contains(key)
                || spec.legacyScopedOwners.contains { key == $0 || key.hasPrefix($0 + ".") }
                || spec.legacyPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// The names a source declares for an old key: a constant whose value
    /// is one, or a function whose text begins with one (a key per entry).
    nonisolated static func legacyNames(declaredIn code: String) -> Set<String> {
        let patterns = [#"let\s+(\w+)\s*(?::\s*String\s*)?=\s*"([^"\\]*)"#, #"func\s+(\w+)\([^)]*\)\s*->\s*String\s*\{\s*"([^"\\]*)"#]
        var names: Set<String> = []
        for pattern in patterns {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let name = Range(match.range(at: 1), in: code), let value = Range(match.range(at: 2), in: code) else { continue }
                if isLegacyKey(String(code[value])) { names.insert(String(code[name])) }
            }
        }
        return names
    }

    /// The types a source declares, so that `Type.name` finds the file
    /// whose constants it means.
    nonisolated static func typesDeclared(in code: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\b(?:class|struct|enum|actor|extension)\s+(\w+)"#)
        return Set(regex.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        })
    }

    /// Whether a source reads an old key from the defaults, through any
    /// door: a read of the defaults by key, or a read of the house door
    /// `AppStorageKeys`. The key is an old name as text, a name the same
    /// source declares for one (`own`, also as `Self.`), or `Type.name`
    /// of a type whose source declares it (`byType`). The value decides,
    /// not the name: the same name for another key is no reader. Writes and
    /// removals are no reads.
    nonisolated static func readsALegacyKey(_ code: String, own: Set<String>, byType: [String: Set<String>]) -> Bool {
        let defaults = #"\.(?:data|object|dictionary|array|stringArray|string|integer|double|float|bool|url)\(forKey:\s*"#
        let door = #"AppStorageKeys\.(?:data|object|dictionary|array|stringArray|string|int|double|float|bool|exists)\(\s*"#
        let regex = try! NSRegularExpression(pattern: "(?:" + defaults + "|" + door + #")("[^"\\]*|[A-Za-z_][\w.]*)"#)
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range(at: 1), in: code) else { continue }
            let key = String(code[range])
            if key.hasPrefix("\"") {
                if isLegacyKey(String(key.dropFirst())) { return true }
                continue
            }
            let parts = key.split(separator: ".").map(String.init)
            guard let name = parts.last else { continue }
            if parts.count == 1 || (parts.count == 2 && parts[0] == "Self") {
                if own.contains(name) { return true }
            } else if byType[parts[parts.count - 2]]?.contains(name) == true {
                return true
            }
        }
        return false
    }

    @Test("der Leser alter Schluessel sieht jede Tuer und den Wert der Konstante, nicht ihren Namen; Schreiben und Loeschen lesen nicht")
    func theLegacyReaderSeesEveryDoorAndTheValue() {
        let carrier = "struct OldCarrier {\n    static let mirrorKey = \"cloudStandMirror\"\n    static let queueKey: String = \"cloudStandQueue\"\n"
            + "    static func ring(_ id: String) -> String { \"jumpRing.\\(id)\" }\n}"
        let own = Self.legacyNames(declaredIn: carrier)
        #expect(own == ["mirrorKey", "queueKey", "ring"], "the declared names of old keys: \(own.sorted())")
        let byType = ["OldCarrier": own]
        #expect(Self.readsALegacyKey("let d = defaults.data(forKey: Self.mirrorKey)", own: own, byType: [:]), "a read by key")
        #expect(Self.readsALegacyKey("let m = AppStorageKeys.dictionary(mirrorKey)", own: own, byType: [:]), "the house door")
        #expect(Self.readsALegacyKey("let d = store.object(forKey: OldCarrier.mirrorKey)", own: [], byType: byType), "a type's constant")
        #expect(Self.readsALegacyKey("let d = defaults.data(forKey: \"maerSyncStandsQueue\")", own: [], byType: [:]), "an old name as text")
        #expect(Self.readsALegacyKey("let d = defaults.data(forKey: \"maerSyncChoices.\\(scope)\")", own: [], byType: [:]), "an owner per identity")
        #expect(!Self.isLegacyKey("maerSyncStandsQueueRemovals"), "a key of this build that begins like an old one")
        #expect(Self.readsALegacyKey("let r = defaults.data(forKey: \"bookmarkCache.\\(id)\")", own: [], byType: [:]), "a key per entry")
        #expect(Self.readsALegacyKey("let r = AppStorageKeys.data(OldCarrier.ring(id))", own: [], byType: byType), "a function of a key per entry")
        let feed = "enum FeedAuth {\n    static let stampsKey = \"feedAuthStamps\"\n}"
        #expect(Self.legacyNames(declaredIn: feed).isEmpty, "another key under a shared name")
        #expect(!Self.readsALegacyKey("let s = defaults.dictionary(forKey: FeedAuth.stampsKey)", own: [],
                                      byType: ["FeedAuth": [], "UserChoiceCloudSync": ["stampsKey"]]), "the name decided, not the value")
        #expect(!Self.readsALegacyKey("defaults.set(data, forKey: Self.mirrorKey)\ndefaults.removeObject(forKey: Self.mirrorKey)",
                                      own: own, byType: [:]), "a write or a removal")
        #expect(!Self.readsALegacyKey("ablage.loadNow([String: [String]].self, name: document)", own: own, byType: [:]), "a store's own document")
    }

    /// The way back holds only while no build writes the old names again:
    /// the tokens and the version of this build have names of their own,
    /// no source writes a blob of a mirror into the defaults, and none reads
    /// an old key from them by its name. The move does not either: it walks
    /// the keys of the defaults (`dictionaryRepresentation`), so it is held
    /// to the same rule and stands in no exception.
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
        var codes: [(name: String, code: String)] = []
        for file in SourceTree.files(under: sources) where file.pathExtension == "swift" {
            codes.append((file.lastPathComponent, SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))))
        }
        var byType: [String: Set<String>] = [:]
        for (_, code) in codes {
            let names = Self.legacyNames(declaredIn: code)
            for type in Self.typesDeclared(in: code) { byType[type, default: []].formUnion(names) }
        }
        #expect(byType["CloudKitStandCarrier"]?.contains("mirrorKey") == true, "the fence does not see the constants of an old key")
        var named: [String] = []
        var legacyReaders: [String] = []
        for (name, code) in codes {
            if (legacy + versions).contains(where: { code.contains("\"\($0)\"") }) {
                named.append(name)
            }
            if Self.readsALegacyKey(code, own: Self.legacyNames(declaredIn: code), byType: byType) {
                legacyReaders.append(name)
            }
            if name == "StandCarrier.swift" {
                #expect(!code.contains("func save(_ value:") && !code.contains("func saveRows("), "a mirror blob writer came back")
            }
        }
        #expect(named == ["CarrierRows.swift"], "the old names stand outside the move: \(named.sorted())")
        #expect(legacyReaders.isEmpty, "an old key is read by its name: \(legacyReaders.sorted())")
    }
}
#endif
