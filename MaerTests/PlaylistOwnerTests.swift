// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The lists follow the account (decision of 03.10.2026, a new beginning):
/// at a switch the holder's lists rest on the shelf, the new account sees
/// none of them, and the way back brings every list back as it was.
@MainActor
struct PlaylistOwnerTests {
    /// One far side per account: what the runner reads and writes is the
    /// pot of the account signed in at that moment.
    private final class AccountCarrier: PlaylistCarrier {
        var name: String { "accounts" }
        let scope: () -> String?
        var pots: [String: MaerPlaylistMerge.Snapshot] = [:]
        init(scope: @escaping () -> String?) { self.scope = scope }
        func held() -> MaerPlaylistMerge.Snapshot { pots[scope() ?? "-"] ?? .init() }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) { pots[scope() ?? "-"] = snapshot }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    private struct Rig {
        let directory: URL
        var database: MaerDatabase { MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path) }
        var shelf: RestingShelf { database.restingShelf! }
    }

    private func rig() throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playlist-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Rig(directory: directory)
    }

    /// The runner rounds only with the sync switch on; the deletion marks
    /// are the app's. Both come back as they were.
    private func withSyncOn(_ body: () async throws -> Void) async rethrows {
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        let marks = MaerPlaylists.tombstones
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
            MaerPlaylists.tombstones = marks
        }
        MaerPlaylists.tombstones = [:]
        try await body()
    }

    @Test("A's Listen ruhen beim Wechsel, B sieht keine davon, der Rueckweg zu A bringt jede Liste Zeile fuer Zeile zurueck")
    func theListsRestUnderTheirAccount() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        await withSyncOn {
            var scope: String? = "account-a"
            let carrier = AccountCarrier(scope: { scope })
            let store = MaerPlaylists(database: rig.database)
            let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, identity: { scope })
            runner.start()

            // A's lists: two that travel, one deleted, one rescue copy that
            // never travels and lives only here.
            store.apply(merged: [:], rescued: [.init(name: "Alt", updatedAt: 1, itemIds: ["rss:r"])],
                        tombstones: [:], rescueName: { "Copy of \($0.name)" })
            let road = store.create(name: "Unterwegs")
            _ = store.add(itemId: "rss:a", to: road.id)
            _ = store.add(itemId: "rss:b", to: road.id)
            let gone = store.create(name: "Weg")
            store.delete(playlistId: gone.id)
            _ = store.create(name: "Abend")
            runner.reconcile()
            let ofA = store.playlists.sorted { $0.id < $1.id }
            let marksOfA = MaerPlaylists.tombstones
            #expect(ofA.count == 3 && ofA.contains(where: \.isRescue))

            scope = "account-b"
            runner.reconcile()
            #expect(store.playlists.isEmpty, "B sees A's lists")
            #expect(MaerPlaylists.tombstones.isEmpty, "B carries A's deletion marks")
            #expect((carrier.pots["account-b"]?.lists ?? [:]).isEmpty, "A's lists went to B")
            let ofB = store.create(name: "Nur B")
            runner.reconcile()

            scope = "account-a"
            runner.reconcile()
            #expect(store.playlists.sorted { $0.id < $1.id } == ofA, "A's lists did not come back as they were")
            #expect(MaerPlaylists.tombstones == marksOfA)
            #expect(carrier.pots["account-a"]?.lists[ofB.id] == nil, "B's list went to A")
            #expect(carrier.pots["account-b"]?.lists.keys.sorted() == [ofB.id])

            // Row for row: a new start on the same rows reads A's lists.
            await store.awaitPendingWrites()
            #expect(MaerPlaylists(database: rig.database).playlists.sorted { $0.id < $1.id } == ofA)
            withExtendedLifetime(runner) {}
        }
    }

    @Test("kann die Ruhe nicht gelegt werden, bleiben die Listen und die Runde haelt an")
    func anUnlaidRestHoldsTheRound() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            var scope: String? = "account-a"
            let carrier = AccountCarrier(scope: { scope })
            let store = MaerPlaylists(database: rig.database)
            let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, identity: { scope })
            runner.start()
            let list = store.create(name: "Unterwegs")
            runner.reconcile()

            // The shelf's place of the account is a file: nothing can be laid.
            let place = rig.shelf.directory.appendingPathComponent("playlists").appendingPathComponent("account-a.json")
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            scope = "account-b"
            runner.reconcile()
            #expect(store.playlists.map(\.id) == [list.id], "the lists left without a rest")
            #expect(carrier.pots["account-b"] == nil, "the held round carried A's lists to B")
            withExtendedLifetime(runner) {}
        }
    }

    @Test("sind die Zeilen beim Wechsel ungelesen, bleiben A's Listen unveraendert und die Runde haelt an")
    func unreadRowsHoldTheSwitch() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            // A's lists on the rows, A holding them.
            let before = MaerPlaylists(database: rig.database)
            #expect(before.follow(owner: "account-a"))
            let list = before.create(name: "Unterwegs")
            _ = before.add(itemId: "rss:a", to: list.id)
            await before.awaitPendingWrites()
            let ofA = before.playlists

            // The next start cannot read the rows.
            let file = rig.directory.appendingPathComponent("maer.sqlite").path
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
            var scope: String? = "account-b"
            let carrier = AccountCarrier(scope: { scope })
            let store = MaerPlaylists(database: rig.database)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
            let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, identity: { scope })
            runner.start()
            runner.reconcile()
            #expect(carrier.pots["account-b"] == nil, "the round ran over unread rows")
            #expect(try rig.shelf.holding(of: "playlists") == .init(owner: "account-a"), "the holder moved")
            #expect(try rig.shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-a") == nil,
                    "a rest was laid without the rows")
            await store.awaitPendingWrites()
            #expect(MaerPlaylists(database: rig.database).playlists == ofA, "A's rows changed")
            scope = nil
            withExtendedLifetime(runner) {}
        }
    }

    @Test("ein offenes Ersetzen eines frueheren Laufs und ein drittes Konto: B's Ruhe traegt keine Liste von A, A's bleiben bei A")
    func aThirdAccountAfterAnOpenReplacement() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            let shelf = rig.shelf
            let restOfA = MaerPlaylists.Resting(
                lists: [.init(id: "a1", name: "Von A", updatedAt: 1, itemIds: ["rss:a"])], tombstones: [:])
            let restOfB = MaerPlaylists.Resting(
                lists: [.init(id: "b1", name: "Von B", updatedAt: 2, itemIds: ["rss:b"])], tombstones: [:])
            try shelf.lay(restOfA, of: "playlists", owner: "account-a")
            try shelf.lay(restOfB, of: "playlists", owner: "account-b")
            try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: "open"),
                                 of: "playlists")
            // The replacement of a run before never landed: A's list is live.
            let store = MaerPlaylists(database: rig.database)
            _ = store.create(name: "A lebend")
            #expect(store.follow(owner: "account-c"))
            #expect(try shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-b") == restOfB,
                    "A's lists were laid as B's")
            #expect(try shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-a") == restOfA)
            #expect(store.playlists.isEmpty, "C sees a list of another account")
            await store.awaitPendingWrites()
        }
    }

    @Test("das Ersetzen der Listen landet mit seiner Marke, erst dann settled der Halter; ein Neustart davor ersetzt nicht noch einmal, was B danach anlegte")
    func theReplacementLandsWithItsMark() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            let shelf = rig.shelf
            let store = MaerPlaylists(database: rig.database)
            #expect(store.follow(owner: "account-a"))
            _ = store.create(name: "Von A")
            #expect(store.follow(owner: "account-b"))
            let name = try #require(try shelf.holding(of: "playlists")?.replacement)
            await store.awaitPendingWrites()
            #expect(try OwnerMark.stands(family: "playlists", replacement: name, database: rig.database),
                    "the rows of the replacement landed without its mark")
            #expect(try shelf.holding(of: "playlists") == .init(owner: "account-b"), "the holding did not settle with the mark")

            let ofB = store.create(name: "Von B")
            await store.awaitPendingWrites()
            try shelf.setHolding(.init(owner: "account-b", replacing: true, from: "account-a", replacement: name),
                                 of: "playlists")
            let restarted = MaerPlaylists(database: rig.database)
            #expect(restarted.follow(owner: "account-b"))
            #expect(restarted.playlists.map(\.id) == [ofB.id], "a landed replacement was done again over B's list")
            #expect(try shelf.holding(of: "playlists") == .init(owner: "account-b"))
        }
    }

    @Test("ein Wechsel bei ausgeschaltetem Sync und ohne Halter: A's Listen ruhen unter A, B sieht keine, B's Liste bleibt B's, auch wenn Sync wieder an ist")
    func aSwitchWithSyncOffAndNoHolder() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            UserDefaults.standard.set(false, forKey: AppStorageKeys.podcastICloudSync)
            let shelf = rig.shelf
            let store = MaerPlaylists(database: rig.database)
            _ = store.create(name: "Von A")
            let carrier = AccountCarrier(scope: { "account-b" })
            let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, identity: { "account-b" })
            runner.followOwner(previous: "account-a")
            let rested = try shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-a")
            #expect(rested?.lists.map(\.name) == ["Von A"], "A's lists do not rest under A")
            #expect(store.playlists.isEmpty, "B sees A's lists")
            let ofB = store.create(name: "Von B")
            UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
            runner.reconcile()
            #expect(store.playlists.map(\.id) == [ofB.id], "B's list left B")
            let restedAfter = try shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-a")
            #expect(restedAfter?.lists.map(\.name) == ["Von A"], "B's list went under A")
            await store.awaitPendingWrites()
            withExtendedLifetime(runner) {}
        }
    }

    @Test("ein Wechsel, dessen Ersetzen nicht ankam, wird beim naechsten Start beendet, ohne die Ruhe zu ueberschreiben")
    func aBrokenReplacementEndsWithoutTouchingTheRest() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            let shelf = rig.shelf
            let restOfA = MaerPlaylists.Resting(
                lists: [.init(id: "a1", name: "Von A", updatedAt: 1, itemIds: ["rss:a"])], tombstones: ["a0": 1])
            let restOfB = MaerPlaylists.Resting(
                lists: [.init(id: "b1", name: "Von B", updatedAt: 2, itemIds: ["rss:b"])], tombstones: [:])
            try shelf.lay(restOfA, of: "playlists", owner: "account-a")
            try shelf.lay(restOfB, of: "playlists", owner: "account-b")
            try shelf.setHolding(.init(owner: "account-b", replacing: true), of: "playlists")

            // The rows still hold A's lists: the replacement never landed.
            let store = MaerPlaylists(database: rig.database)
            _ = store.create(name: "Halb")
            #expect(store.follow(owner: "account-b"))
            #expect(store.playlists.map(\.id) == ["b1"])
            #expect(try shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-a") == restOfA,
                    "the half replaced lists were laid over A's rest")
            await store.awaitPendingWrites()
            try await Task.sleep(for: .milliseconds(100))
            #expect(try shelf.holding(of: "playlists") == .init(owner: "account-b"))
        }
    }

    private static let laterForm = Data("a list in a form of a later build".utf8)

    private func undecoded(_ database: MaerDatabase) throws -> [String: Data] {
        try KeyedRowStore<MaerPlaylists.Playlist>.undecodedNow(table: .maerPlaylist, reader: try #require(try database.readerNow()))
    }

    @Test("eine Zeile, die dieser Bau nicht liest, ruht mit A, steht nie unter B und kommt auf dem Rueckweg ungelesen zurueck")
    func anUnreadRowRestsWithItsAccount() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            let database = rig.database
            let first = MaerPlaylists(database: database)
            _ = first.create(name: "Von A")
            await first.awaitPendingWrites()
            _ = try await database.connection().run("INSERT INTO maer_playlist (key, payload) VALUES (?, ?)",
                                                    [.text("later-form"), .blob(Self.laterForm)])
            // A new start reads the list and skips the row.
            let store = MaerPlaylists(database: database)
            #expect(store.startIncomplete && store.playlists.map(\.name) == ["Von A"], "the precondition: one row unread")
            #expect(store.follow(owner: "account-a"))
            #expect(store.follow(owner: "account-b"))
            await store.awaitPendingWrites()
            try await Task.sleep(for: .milliseconds(100))
            let rest = try #require(try rig.shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-a"))
            #expect(rest.unread == ["later-form": Self.laterForm], "A's unread row did not rest with A")
            #expect(try undecoded(database).isEmpty, "A's unread row stands under B")
            #expect(store.playlists.isEmpty)
            // The rest is one file per account: no second file reads as an owner.
            #expect(try rig.shelf.owners(of: "playlists") == ["account-a"])

            // The way back, from a run that started under B and read every
            // row: the row comes back as it was, and this run knows its rows
            // hold more than it read.
            let underB = MaerPlaylists(database: database)
            #expect(!underB.startIncomplete, "the precondition: the run under B read every row")
            #expect(underB.follow(owner: "account-a"))
            await underB.awaitPendingWrites()
            try await Task.sleep(for: .milliseconds(100))
            #expect(try undecoded(database) == ["later-form": Self.laterForm], "A's unread row did not come back")
            #expect(underB.startIncomplete, "this run takes its rows for whole after a row came back unread")
            let again = MaerPlaylists(database: database)
            #expect(again.startIncomplete && again.playlists.map(\.name) == ["Von A"], "the way back lost A's list or its unread row")
        }
    }

    @Test("bricht die Uebergabe nach dem Ablegen und vor dem Ersetzen ab, geht die ungelesene Zeile nicht verloren und steht nicht doppelt")
    func anUnreadRowSurvivesABrokenReplacement() async throws {
        let rig = try rig()
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        try await withSyncOn {
            let shelf = rig.shelf
            let database = rig.database
            // A's rest is laid with its unread row; the replacement did not
            // land, so the row still stands in the table.
            let restOfA = MaerPlaylists.Resting(
                lists: [.init(id: "a1", name: "Von A", updatedAt: 1, itemIds: ["rss:a"])], tombstones: [:],
                unread: ["later-form": Self.laterForm])
            let restOfB = MaerPlaylists.Resting(
                lists: [.init(id: "b1", name: "Von B", updatedAt: 2, itemIds: ["rss:b"])], tombstones: [:])
            try shelf.lay(restOfA, of: "playlists", owner: "account-a")
            try shelf.lay(restOfB, of: "playlists", owner: "account-b")
            try shelf.setHolding(.init(owner: "account-b", replacing: true), of: "playlists")
            let seed = MaerPlaylists(database: database)
            _ = seed.create(name: "Halb")
            await seed.awaitPendingWrites()
            _ = try await database.connection().run("INSERT INTO maer_playlist (key, payload) VALUES (?, ?)",
                                                    [.text("later-form"), .blob(Self.laterForm)])

            let store = MaerPlaylists(database: database)
            #expect(store.follow(owner: "account-b"))
            await store.awaitPendingWrites()
            try await Task.sleep(for: .milliseconds(100))
            #expect(try shelf.rest(MaerPlaylists.Resting.self, of: "playlists", owner: "account-a") == restOfA,
                    "A's rest with its unread row was lost or overwritten")
            #expect(try undecoded(database).isEmpty, "the unread row stands twice: on A's shelf and under B")
            #expect(store.playlists.map(\.id) == ["b1"])
        }
    }
}
#endif
