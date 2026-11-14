// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stamps of the choices live in rows with their owner in the key: the
/// blob moves once to the holder of the choices, no account reads another
/// account's stamps (not even after a restart in the middle of a
/// hand-over), a rest laid by an earlier build brings its stamps into the
/// rows, a round waits while the stamps cannot be read, and no source reads
/// or writes the stamps in the defaults.
@MainActor
struct ChoiceStampRowsTests {
    /// One document per account.
    private final class AccountCarrier: ChoiceCarrier {
        var name: String { "accounts" }
        let scope: () -> String?
        var pots: [String: [String: Any]] = [:]
        init(scope: @escaping () -> String?) { self.scope = scope }
        func loadBlob() -> [String: Any] { pots[scope() ?? "-"] ?? [:] }
        func storeBlob(_ blob: [String: Any]) { pots[scope() ?? "-"] = blob }
        func flush() {}
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
    }

    private struct Place {
        let suite: String
        let defaults: UserDefaults
        let directory: URL
        let path: String
        var shelf: RestingShelf { RestingShelf(directory: directory) }
        func cleanup() {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func place() throws -> Place {
        let suite = "choice-stamp-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("choice-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Place(suite: suite, defaults: try #require(UserDefaults(suiteName: suite)), directory: directory,
                     path: directory.appendingPathComponent("maer.sqlite").path)
    }

    private func storedRows(_ path: String) throws -> [String: Double] {
        let reader = try #require(try MaerDatabase(path: path).readerNow())
        return try KeyedRowStore<Double>.loadNow(table: .choiceStamp, reader: reader).rows
    }

    @Test("the stamps move once from the defaults into the rows of the holder of the choices")
    func theBlobMovesToTheHolder() async throws {
        let place = try place()
        defer { place.cleanup() }
        place.defaults.set(["librarySortOption": 5_000.0, "playbackRate.buch": 6_000.0], forKey: UserChoiceCloudSync.stampsKey)
        let rows = ChoiceStampRows(database: MaerDatabase(path: place.path), defaults: place.defaults)
        let sync = UserChoiceCloudSync(defaults: place.defaults, carrier: AccountCarrier(scope: { nil }), syncEnabled: { true },
                                       stamps: rows, idFormSettled: { true })
        #expect(sync.localStamps() == ["librarySortOption": 5_000.0, "playbackRate.buch": 6_000.0])
        await rows.awaitPendingWrites()
        #expect(place.defaults.object(forKey: UserChoiceCloudSync.stampsKey) == nil, "the blob stayed in the defaults")
        #expect(try storedRows(place.path) == [ChoiceStampRows.key("", "librarySortOption"): 5_000.0,
                                               ChoiceStampRows.key("", "playbackRate.buch"): 6_000.0])
        #expect(!rows.holds(ChoiceStampRows.legacyOwner), "the moved blob was not handed to the holder")
    }

    /// The invariant: no account dates its choices with another account's
    /// stamps. Each account's stamps are its own rows; a session built anew
    /// in the middle of a hand-over reads only the holder's.
    @Test("no account carries foreign stamps: B does not read A's, not even after a restart, and A gets its own back")
    func noAccountCarriesAnothersStamps() async throws {
        let place = try place()
        defer { place.cleanup() }
        var scope: String? = "account-a"
        var clock = 1000.0
        let carrier = AccountCarrier(scope: { scope })
        let rows = ChoiceStampRows(database: MaerDatabase(path: place.path), defaults: place.defaults)
        func session() -> UserChoiceCloudSync {
            let sync = UserChoiceCloudSync(defaults: place.defaults, carrier: carrier, syncEnabled: { true },
                                           now: { clock += 1; return clock }, identity: { scope },
                                           shelf: place.shelf, stamps: rows, idFormSettled: { true })
            sync.sourcesAdopted = {}
            return sync
        }
        let sync = session()
        sync.reconcile()
        place.defaults.set("title", forKey: "librarySortOption")
        sync.noteScalar(key: "librarySortOption", value: "title")
        let stampOfA = try #require(sync.localStamps()?["librarySortOption"], "the precondition: A's choice has a stamp")

        scope = "account-b"
        sync.reconcile()
        #expect(sync.localStamps()?["librarySortOption"] == nil, "B reads A's stamp")
        await rows.awaitPendingWrites()
        #expect(try storedRows(place.path)[ChoiceStampRows.key("account-a", "librarySortOption")] == stampOfA,
                "A's stamp left the rows instead of resting under A")
        #expect(session().localStamps()?["librarySortOption"] == nil, "a session built anew reads A's stamp for B")

        scope = "account-a"
        sync.reconcile()
        #expect(sync.localStamps()?["librarySortOption"] == stampOfA, "A's stamp did not come back")
    }

    @Test("a rest left by an earlier build carries the stamps as keys: they go into the rows of the account that comes back")
    func aRestOfAnEarlierBuildBringsItsStamps() async throws {
        let place = try place()
        defer { place.cleanup() }
        let laid = try PropertyListSerialization.data(fromPropertyList: ["librarySortOption": 7_000.0], format: .binary, options: 0)
        let sort = try PropertyListSerialization.data(fromPropertyList: "author", format: .binary, options: 0)
        try place.shelf.lay(UserChoiceCloudSync.Resting(values: [UserChoiceCloudSync.stampsKey: laid, "librarySortOption": sort]),
                            of: "choices", owner: "account-a")
        try place.shelf.setHolding(.init(owner: "account-b"), of: "choices")
        let rows = ChoiceStampRows(database: MaerDatabase(path: place.path), defaults: place.defaults)
        let sync = UserChoiceCloudSync(defaults: place.defaults, carrier: AccountCarrier(scope: { "account-a" }), syncEnabled: { true },
                                       identity: { "account-a" }, shelf: place.shelf, stamps: rows, idFormSettled: { true })
        sync.sourcesAdopted = {}
        sync.reconcile()
        #expect(place.defaults.string(forKey: "librarySortOption") == "author", "the precondition: A's rest came back")
        #expect(sync.localStamps()?["librarySortOption"] == 7_000.0, "the stamps of the rest did not reach the rows")
        #expect(place.defaults.object(forKey: UserChoiceCloudSync.stampsKey) == nil, "the stamps went back into the defaults")
    }

    /// Stamps nobody could read are unknown, not empty: a round over them
    /// would date every choice here from nothing.
    @Test("if the start cannot read the stamps, the round waits; once read, it runs with the stamps read")
    func anUnreadStartHoldsTheRound() async throws {
        let place = try place()
        defer { place.cleanup() }
        place.defaults.set(true, forKey: ChoiceStampRows.movedKey)
        let database = MaerDatabase(path: place.path)
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE choice_stamp (other TEXT)")
        try await connection.execute("INSERT INTO choice_stamp (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        let rows = ChoiceStampRows(database: database, defaults: place.defaults)
        let carrier = AccountCarrier(scope: { nil })
        let sync = UserChoiceCloudSync(defaults: place.defaults, carrier: carrier, syncEnabled: { true },
                                       stamps: rows, idFormSettled: { true })
        place.defaults.set("title", forKey: "librarySortOption")
        sync.reconcile()
        #expect(rows.unread, "the precondition: the start read failed")
        #expect(carrier.pots["-"] == nil, "a round ran over stamps nobody read")

        try await connection.execute("DROP TABLE choice_stamp")
        let store = try await KeyedRowStore<Double>(connection: connection, table: .choiceStamp)
        _ = try await store.apply(previous: [:], current: [ChoiceStampRows.key("", "librarySortOption"): 5_000.0])
        sync._seedStampsForWitness(["other": 1.0])
        await rows.awaitPendingWrites()
        #expect(!rows.unread)
        #expect(sync.localStamps()?["librarySortOption"] == 5_000.0, "the read stamp did not join")
        let sent = UserChoiceEntry.from(plist: carrier.pots["-"]?["librarySortOption"])
        #expect(sent?.t == 5_000.0, "the round did not run with the read stamp")
    }

    /// A sync over a stamp table its start cannot read.
    private func unreadSync(_ place: Place) async throws -> (UserChoiceCloudSync, ChoiceStampRows, SQLiteConnection) {
        place.defaults.set(true, forKey: ChoiceStampRows.movedKey)
        let database = MaerDatabase(path: place.path)
        let connection = try database.connection()
        try await connection.execute("CREATE TABLE choice_stamp (other TEXT)")
        try await connection.execute("INSERT INTO choice_stamp (other) VALUES ('x')")
        _ = try await connection.checkpoint()
        let rows = ChoiceStampRows(database: database, defaults: place.defaults)
        let sync = UserChoiceCloudSync(defaults: place.defaults, carrier: AccountCarrier(scope: { nil }), syncEnabled: { true },
                                       stamps: rows, idFormSettled: { true })
        sync.sourcesAdopted = {}
        return (sync, rows, connection)
    }

    /// Every caller of the stamps says what it does while they are unknown:
    /// the source answers nil, not an empty set.
    @Test("unread, the source answers nil; re-keying moves nothing, the question for music identifiers is not answered")
    func everyCallerWaitsForUnreadStamps() async throws {
        let place = try place()
        defer { place.cleanup() }
        let (sync, rows, _) = try await unreadSync(place)
        let old = "playbackRate.sub:song:alt-1"
        place.defaults.set(1.5, forKey: old)
        #expect(rows.unread, "the precondition: the start read failed")
        #expect(sync.localStamps() == nil, "unknown stamps answered as no stamps")
        #expect(sync.holdsServerMusicIds() == nil, "the question about music ids answered over unknown stamps")
        #expect(sync.rekeyLocalChoices { $0.replacingOccurrences(of: "alt-1", with: "neu-1") } == nil,
                "the rekey ran over unknown stamps")
        #expect(place.defaults.double(forKey: old) == 1.5, "the rekey moved a choice without its stamp")
        #expect(place.defaults.object(forKey: "playbackRate.sub:song:neu-1") == nil)
    }

    @Test("choices over unread stamps stamp themselves and keep each other, the read ones are added")
    func aNoteOverUnreadStampsKeepsTheRead() async throws {
        let place = try place()
        defer { place.cleanup() }
        let (sync, rows, connection) = try await unreadSync(place)
        place.defaults.set("title", forKey: "librarySortOption")
        sync.noteScalar(key: "librarySortOption", value: "title")
        place.defaults.set("author", forKey: "podcastSortOption")
        sync.noteScalar(key: "podcastSortOption", value: "author")
        // The notes' writes run before the table is made readable: they hold
        // over the unreadable rows. Left running, one of them could read the
        // fresh empty table before the read stamp was put in, take that as
        // the rows, and the later read was never asked for (1 in 7 runs).
        await rows.awaitPendingWrites()
        #expect(rows.unread, "the precondition: the notes ran over unread rows and held")
        try await connection.execute("DROP TABLE choice_stamp")
        let store = try await KeyedRowStore<Double>(connection: connection, table: .choiceStamp)
        _ = try await store.apply(previous: [:], current: [ChoiceStampRows.key("", "playbackRate.buch"): 4_000.0])
        place.defaults.set("title", forKey: "musicSortOption")
        sync.noteScalar(key: "musicSortOption", value: "title")
        await rows.awaitPendingWrites()
        let stamps = try #require(sync.localStamps(), "the stamps are read")
        #expect(stamps["playbackRate.buch"] == 4_000.0, "a read stamp was lost over the notes")
        #expect(stamps["librarySortOption"] != nil, "the first note lost its stamp to the second")
        #expect(stamps["podcastSortOption"] != nil, "the second note did not stamp its own choice")
    }

    /// The standby asks the stamps through the shared sync, which a witness
    /// cannot start unread; held at the form: unknown stamps keep it.
    @Test("the standby player stays put as long as the stamps are not read", .needsTheSources)
    func theStandbyKeepsOverUnreadStamps() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        let open = try #require(code.range(of: "func refreshStandbyFromTruth() async {"))
        let body = code[open.upperBound...].prefix(600)
        #expect(body.contains("guard let stamps = UserChoiceCloudSync.shared.localStamps() else {"), "the standby reads the stamps without asking whether they are known")
        #expect(body.contains("STANDBY kept: the stamps of the choices are not read"))
    }

    @Test("no source reads or writes the stamps in the defaults", .needsTheSources)
    func noSourceReadsTheStampsFromTheDefaults() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        var named: [String: Int] = [:]
        for file in SourceTree.files(under: sources) where file.pathExtension == "swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            #expect(!code.contains("forKey: Self.stampsKey") && !code.contains("forKey: UserChoiceCloudSync.stampsKey"),
                    "\(file.lastPathComponent) reads or writes the stamps in the defaults")
            // The stamps of the feed logins have a key of the same name there.
            guard file.lastPathComponent != "PodcastFeedAuth.swift" else { continue }
            let n = code.components(separatedBy: "stampsKey").count - 1
            if n > 0 { named[file.lastPathComponent] = n }
        }
        // The declaration and the one branch for a rest of an earlier build.
        #expect(named == ["UserChoiceCloudSync.swift": 2], "the stamps' key stands elsewhere: \(named)")
    }
}
#endif
