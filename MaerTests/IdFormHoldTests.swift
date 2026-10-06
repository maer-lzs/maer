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
                                               idFormKnown: { known })
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
                                       now: { clock += 1; return clock }, idFormKnown: { known })
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

    @Test("die Form ist bekannt ohne Server und nach der ersten Antwort des eingetragenen, davor nicht")
    func theFormIsKnownAfterTheFirstAnswer() throws {
        let address = "https://id-form-\(UUID().uuidString).example/music"
        let server = SubsonicClient.serverKey(for: try #require(URL(string: address)))
        let previous = AppStorageKeys.subsonicServerURLValue
        defer {
            AppStorageKeys.subsonicServerURLValue = previous
            AppStorageKeys.set(nil, for: "subsonicType.\(server)")
        }
        AppStorageKeys.subsonicServerURLValue = ""
        #expect(SubsonicProvider.idFormKnown, "without a server there is nothing to wait for")
        AppStorageKeys.subsonicServerURLValue = address
        #expect(!SubsonicProvider.idFormKnown, "a new address before its first answer")
        SubsonicClient.persistReportedType("navidrome", server: server)
        #expect(SubsonicProvider.idFormKnown)
    }
}
#endif
