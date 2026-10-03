// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The runner sends a local playlist change by itself: a list made without
/// a restart and without the far side moving stands at the carrier after
/// the send delay, and the reconcile's own apply does not send again.
@MainActor
struct MaerPlaylistCloudSyncTests {
    private final class RecordingCarrier: PlaylistCarrier {
        var name: String { "recording" }
        var snapshot = MaerPlaylistMerge.Snapshot()
        var stores: [MaerPlaylistMerge.Snapshot] = []
        func held() -> MaerPlaylistMerge.Snapshot { snapshot }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
            self.snapshot = snapshot
            stores.append(snapshot)
        }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    @Test("eine lokale Aenderung erreicht den Traeger ohne Neustart und ohne Gegenseite")
    func aLocalChangeReachesTheCarrierByItself() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playlist-send-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let was = UserDefaults.standard.object(forKey: AppStorageKeys.podcastICloudSync)
        UserDefaults.standard.set(true, forKey: AppStorageKeys.podcastICloudSync)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: AppStorageKeys.podcastICloudSync) }
            else { UserDefaults.standard.removeObject(forKey: AppStorageKeys.podcastICloudSync) }
        }

        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let carrier = RecordingCarrier()
        let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store)
        runner.start()
        let sentAtStart = carrier.stores.count

        let list = store.create(name: "Unterwegs")
        _ = store.add(itemId: "rss:a", to: list.id)
        _ = store.add(itemId: "rss:b", to: list.id)
        #expect(carrier.stores.count == sentAtStart, "the send runs on the next turn, three edits become one")
        try await Task.sleep(for: .milliseconds(300))
        #expect(carrier.stores.count == sentAtStart + 1, "the change travelled without a restart, once")
        #expect(carrier.snapshot.lists[list.id]?.itemIds == ["rss:a", "rss:b"])

        // The reconcile's own apply of the far side is not a local change:
        // the far side renames, nothing is sent back for it.
        var far = carrier.snapshot
        var renamed = try #require(far.lists[list.id])
        renamed.name = "Unterwegs (iPad)"
        renamed.nameUpdatedAt = (renamed.nameUpdatedAt ?? 0) + 60
        renamed.updatedAt += 60
        far.lists[list.id] = renamed
        carrier.snapshot = far
        let sentBefore = carrier.stores.count
        runner.reconcile()
        #expect(store.playlist(id: list.id)?.name == "Unterwegs (iPad)", "the far side's name was applied")
        try await Task.sleep(for: .milliseconds(300))
        #expect(carrier.stores.count == sentBefore, "applying the far side sends nothing back")
        withExtendedLifetime(runner) {}
    }
}
#endif
