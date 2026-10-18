// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The playlists and choices documents of the Mär sync service live in rows,
/// one body per owner and identity: the bodies move once with their
/// versions, the session reads them back, a start that cannot read the rows
/// drops the versions, and no build writes the old names again.
@MainActor
struct CarrierDocumentRowsTests {
    typealias FakeTransport = MaerSyncCarrierTests.FakeTransport
    typealias FakeAnnouncer = MaerSyncCarrierTests.FakeAnnouncer

    private func place() throws -> (UserDefaults, String, String) {
        let suite = "carrier-document-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("carrier-document-\(UUID().uuidString).sqlite").path
        return (defaults, suite, path)
    }

    private func storedRows(_ path: String) throws -> [String: String] {
        let reader = try #require(try MaerDatabase(path: path).readerNow())
        return try KeyedRowStore<String>.loadNow(table: .carrierDocument, reader: reader).rows
    }

    private func session(_ defaults: UserDefaults, documents: CarrierDocumentRows) -> MaerSyncSession {
        MaerSyncSession(transport: FakeTransport(), announcer: FakeAnnouncer(),
                        access: { MaerSyncIdentityTests.accessA }, identity: { MaerSyncIdentityTests.identityA },
                        deviceId: { "dev-a" }, defaults: defaults, documents: documents)
    }

    @Test("der erste Zugriff zieht die vier Dokumente in Zeilen; die Versionen gehen, die Sitzung liest die Dokumente zurueck")
    func theFirstAccessMovesTheDocuments() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = MaerSyncIdentityTests.identityA
        let playlists = Data(#"{"lists":{},"tombstones":{}}"#.utf8)
        let choices = Data(#"{"entries":{"librarySortOption":{"t":5,"v":{"s":"title"}}}}"#.utf8)
        defaults.set(playlists, forKey: identity.keyed("maerSyncPlaylists"))
        defaults.set(choices, forKey: identity.keyed("maerSyncChoices"))
        defaults.set(choices, forKey: identity.keyed("maerSyncChoicesPending"))
        defaults.set(playlists, forKey: "maerSyncPlaylistsPending")
        defaults.set("p7", forKey: identity.keyed("maerSyncPlaylistsVersion"))
        defaults.set("c7", forKey: identity.keyed("maerSyncChoicesVersion"))
        defaults.set("c1", forKey: "maerSyncChoicesVersion")
        defaults.set(true, forKey: CarrierStandRows.movedKey)

        let documents = CarrierDocumentRows(database: MaerDatabase(path: path), defaults: defaults)
        #expect(documents.body(identity.keyed("maerSyncChoices")) == choices, "the body is in memory at once")
        await documents.awaitPendingWrites()
        #expect(try storedRows(path).count == 4, "the rows did not land")
        for key in [identity.keyed("maerSyncPlaylists"), identity.keyed("maerSyncChoices"), identity.keyed("maerSyncChoicesPending"),
                    "maerSyncPlaylistsPending", identity.keyed("maerSyncPlaylistsVersion"), identity.keyed("maerSyncChoicesVersion"),
                    "maerSyncChoicesVersion"] {
            #expect(defaults.object(forKey: key) == nil, "an older build still finds \(key)")
        }
        #expect(defaults.bool(forKey: CarrierDocumentRows.movedKey))

        let session = session(defaults, documents: documents)
        #expect(session.playlistsBody == playlists && session.choicesBody == choices, "the session did not read the documents back")
    }

    @Test("ein Schrieb der Sitzung legt die Dokumente in die Zeilen und keinen alten Namen in die Voreinstellungen")
    func aWriteKeepsTheOldNamesEmpty() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let documents = CarrierDocumentRows(database: MaerDatabase(path: path), defaults: defaults)
        let session = session(defaults, documents: documents)
        let body = Data(#"{"lists":{},"tombstones":{"x":1}}"#.utf8)
        session.writePlaylists(body, by: "witness")
        session.enqueue(upserts: ["rss:a:1": [1, 1_000]], removing: [], by: "witness")
        await documents.awaitPendingWrites()
        let owner = MaerSyncIdentityTests.identityA.keyed(MaerSyncSession.playlistsMirrorKey)
        #expect(documents.body(owner) == body)
        #expect(try storedRows(path)[CarrierDocumentRows.key(owner, CarrierRowsSpec.bodyEntry)] != nil, "the body did not reach the rows")
        let old = defaults.dictionaryRepresentation().keys.filter {
            CarrierDocumentRows.isLegacyOwner($0) || CarrierRowsSpec.documents.isLegacyVersion($0)
        }
        #expect(old.isEmpty, "an older build finds \(old.sorted())")
    }

    @Test("kann der Start die Dokumente nicht lesen, fallen ihre Versionen, und gelesen steht der Koerper, wo der Lauf keinen haelt")
    func anUnreadStartDropsTheVersions() async throws {
        let (defaults, suite, path) = try place()
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = MaerSyncIdentityTests.identityA
        defaults.set(true, forKey: CarrierDocumentRows.movedKey)
        defaults.set("c7", forKey: identity.keyed(MaerSyncSession.choicesVersionKey))
        defaults.set("p7", forKey: identity.keyed(MaerSyncSession.playlistsVersionKey))
        let database = MaerDatabase(path: path)
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE carrier_document (other TEXT)")
        try await connection.execute("INSERT INTO carrier_document (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        let documents = CarrierDocumentRows(database: database, defaults: defaults)
        let session = session(defaults, documents: documents)
        #expect(documents.unread, "the precondition: the start read failed")
        #expect(defaults.string(forKey: identity.keyed(MaerSyncSession.choicesVersionKey)) == nil, "the choices' version stayed")
        #expect(defaults.string(forKey: identity.keyed(MaerSyncSession.playlistsVersionKey)) == nil, "the playlists' version stayed")

        try await connection.execute("DROP TABLE carrier_document")
        let store = try await KeyedRowStore<String>(connection: connection, table: .carrierDocument)
        let choices = #"{"entries":{}}"#
        _ = try await store.apply(previous: [:], current: [
            CarrierDocumentRows.key(identity.keyed(MaerSyncSession.choicesMirrorKey), CarrierRowsSpec.bodyEntry): choices])
        session.writePlaylists(Data(#"{"lists":{},"tombstones":{}}"#.utf8), by: "witness")
        await documents.awaitPendingWrites()
        #expect(!documents.unread)
        #expect(session.choicesBody == Data(choices.utf8), "the read body did not join")
    }
}
#endif
