// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// After a new music server address, before its first answer, the form of
/// its ids is unknown. Playlists and choices that hold the server's ids
/// wait with their round; the others go on.
@MainActor
struct IdFormHoldTests {
    private final class RecordingCarrier: PlaylistCarrier {
        var name: String { "recording" }
        var snapshot = MaerPlaylistMerge.Snapshot()
        var stores: [MaerPlaylistMerge.Snapshot] = []
        func held() -> MaerPlaylistMerge.Snapshot { snapshot }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) { self.snapshot = snapshot; stores.append(snapshot) }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    private func withSyncOn(_ body: () async throws -> Void) async rethrows {
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }
        try await body()
    }

    @Test("Playlisten mit Kennungen des Musikservers warten, solange deren Form unbekannt ist; andere laufen")
    func playlistsWaitForTheIdForm() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("id-form-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await withSyncOn {
            var known = false
            let store = MaerPlaylists(database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path))
            let carrier = RecordingCarrier()
            let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, identity: { nil },
                                               idFormSettled: { known })
            let feeds = store.create(name: "Unterwegs")
            _ = store.add(itemId: "rss:a", to: feeds.id)
            runner.reconcile()
            #expect(carrier.snapshot.lists[feeds.id] != nil, "a list without the server's ids waited")

            let music = store.create(name: "Musik")
            _ = store.add(itemId: "sub:song:alt-1", to: music.id)
            let before = carrier.stores.count
            runner.reconcile()
            #expect(carrier.stores.count == before, "a round ran with the server's ids in an unknown form")
            #expect(carrier.snapshot.lists[music.id] == nil)

            known = true
            runner.reconcile()
            #expect(carrier.snapshot.lists[music.id] != nil, "the round did not go on once the form was known")
            withExtendedLifetime(runner) {}
        }
    }

    @Test("Wahlen mit Kennungen des Musikservers warten, solange deren Form unbekannt ist; andere laufen")
    func choicesWaitForTheIdForm() {
        let suite = "id-form-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var known = false
        var clock = 1000.0
        let cloud = UserChoiceFakeCloud()
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                       now: { clock += 1; return clock }, idFormSettled: { known })
        sync.sourcesAdopted = {}
        defaults.set("title", forKey: "librarySortOption")
        sync.noteScalar(key: "librarySortOption", value: "title")
        #expect(!sync.holdsServerMusicIds())
        sync.reconcile()
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(blob["librarySortOption"] != nil, "choices without the server's ids waited")

        defaults.set(1.5, forKey: "playbackRate.sub:song:alt-1")
        #expect(sync.holdsServerMusicIds())
        cloud.storage[UserChoiceCloudSync.blobKey] = [:]
        sync.reconcile()
        #expect((cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]).isEmpty,
                "a round ran with the server's ids in an unknown form")

        known = true
        sync.reconcile()
        #expect((cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any])?["librarySortOption"] != nil,
                "the round did not go on once the form was known")
    }

    @Test("eine Liste, die eine Server-Kennung nur unter den Entfernten traegt, wartet ebenso")
    func aRemovedServerIdWaits() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("id-form-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await withSyncOn {
            var settled = false
            let store = MaerPlaylists(database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path))
            let carrier = RecordingCarrier()
            let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, identity: { nil },
                                               idFormSettled: { settled })
            let list = store.create(name: "Gemischt")
            _ = store.add(itemId: "rss:a", to: list.id)
            _ = store.add(itemId: "sub:song:gone", to: list.id)
            store.remove(itemId: "sub:song:gone", from: list.id)
            let held = try #require(store.syncable.first { $0.id == list.id })
            #expect(!held.itemIds.contains("sub:song:gone") && held.removed["sub:song:gone"] != nil,
                    "the precondition: the server's id stands only among the removed")
            runner.reconcile()
            #expect(carrier.stores.isEmpty, "a list with the server's id among its removals ran in an unknown form")
            settled = true
            runner.reconcile()
            #expect(carrier.snapshot.lists[list.id] != nil, "the round did not go on once the form was settled")
            withExtendedLifetime(runner) {}
        }
    }

    @Test("eine Rate, die im Fenster notiert wird, steht nicht in alter Form im Dokument und reist nach dem Warten")
    func aRateNotedInTheWindowWaits() {
        let suite = "id-form-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var settled = false
        var clock = 1000.0
        let cloud = UserChoiceFakeCloud()
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                       now: { clock += 1; return clock }, itemIdMap: { $0 },
                                       idFormSettled: { settled })
        sync.sourcesAdopted = {}
        let rate = "playbackRate.sub:song:alt-2"
        defaults.set(1.5, forKey: rate)
        sync.noteScalar(key: rate, value: 1.5)
        defaults.set("title", forKey: "librarySortOption")
        sync.noteScalar(key: "librarySortOption", value: "title")
        let blob = cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
        #expect(blob[rate] == nil, "a rate with the server's id went into the document in an unknown form")
        #expect(blob["librarySortOption"] != nil, "a statement without the server's ids waited")
        settled = true
        sync.reconcile()
        #expect((cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any])?[rate] != nil,
                "the held rate did not travel after the wait")
    }

    @Test("die Form steht fest ohne Server, mit Typ und Fassung, nach einem Versuch, der nichts lehrte, oder nach der Frist; die Runden laufen dann wieder")
    func theWaitEnds() async throws {
        let previous = AppStorageKeys.subsonicServerURLValue
        let run = UUID().uuidString.prefix(8)
        let never = "http://127.0.0.1:9/never-\(run)"
        let idle = "https://idle-\(run).example/music"
        let navi = "https://navi-\(run).example/music"
        let servers = try [never, idle, navi].map { SubsonicClient.serverKey(for: try #require(URL(string: $0))) }
        defer {
            AppStorageKeys.subsonicServerURLValue = previous
            for server in servers {
                AppStorageKeys.set(nil, for: "subsonicType.\(server)")
                AppStorageKeys.set(nil, for: "subsonicServerVersion.\(server)")
                AppStorageKeys.set(nil, for: "subsonicSignIn.\(server)")
            }
        }
        let now = Date().timeIntervalSince1970
        AppStorageKeys.subsonicServerURLValue = ""
        #expect(SubsonicProvider.idFormSettled(now: now), "without a server there is nothing to wait for")

        // An address that never answers: the families run again after the try.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("id-form-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        AppStorageKeys.subsonicServerURLValue = never
        try await withSyncOn {
            let store = MaerPlaylists(database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path))
            let carrier = RecordingCarrier()
            let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store, identity: { nil })
            let list = store.create(name: "Musik")
            _ = store.add(itemId: "sub:song:alt-3", to: list.id)
            runner.reconcile()
            #expect(carrier.stores.isEmpty, "the round ran before the address said anything")
            let client = try #require(SubsonicClient(serverURL: never, username: "hoerer", password: "geheim-42"))
            var failed = false
            do { try await client.ping() } catch { failed = true }
            try #require(failed, "the precondition: nothing answers at this address")
            runner.reconcile()
            #expect(carrier.snapshot.lists[list.id] != nil, "the round still waited after the try that taught nothing")
            withExtendedLifetime(runner) {}
        }

        // No try at all: the wait ends at the limit.
        AppStorageKeys.subsonicServerURLValue = idle
        #expect(!SubsonicProvider.idFormSettled(now: now))
        #expect(!SubsonicProvider.idFormSettled(now: now + SubsonicProvider.idFormWaitLimit - 1))
        #expect(SubsonicProvider.idFormSettled(now: now + SubsonicProvider.idFormWaitLimit))

        // Navidrome needs its version too: the type alone decides nothing.
        AppStorageKeys.subsonicServerURLValue = navi
        SubsonicClient.persistReportedType("navidrome", server: servers[2])
        #expect(!SubsonicProvider.idFormSettled(now: now), "the type alone settled the form of a Navidrome")
        SubsonicClient.persistReportedVersion("0.64.2 (38dc2727)", server: servers[2])
        #expect(SubsonicProvider.idFormSettled(now: now))
        #expect(NavidromeIDRule.isDecided(type: "gonic", version: nil), "a server that is not Navidrome needs no version")
    }
}
#endif
