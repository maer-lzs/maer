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
}
#endif
