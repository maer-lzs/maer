// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Podcast playlists become folders: a folder is a Mär playlist whose
/// entries are shows (`show:<feedKey>`). It stands in the Podcasts tab, a
/// show in a folder leaves the loose grid of subscriptions, the tile counts
/// the new episodes of all its shows and starts the newest unheard episode
/// of each, the page starts in order or shuffled. A podcast list of
/// episodes becomes the folder of their shows once, the same on every
/// device; its unheard episodes go to Up Next once per device.
struct PodcastFolderTests {
    @Test("a show entry names its feed, and a folder holds shows only")
    func entries() {
        #expect(PodcastFolder.entry(feedKey: "abc") == "show:abc")
        #expect(PodcastFolder.feedKey(of: "show:abc") == "abc")
        #expect(PodcastFolder.feedKey(of: "rss:abc:1") == nil)
        #expect(PodcastFolder.isFolder(["show:a", "show:b"]))
        #expect(!PodcastFolder.isFolder([]), "an empty list is no folder")
        #expect(!PodcastFolder.isFolder(["show:a", "rss:b:1"]))
    }

    @Test("a folder is podcasts and stands in the Podcasts tab")
    func home() {
        #expect(MediaFamily.kind(for: "show:abc") == .podcasts)
        #expect(PlaylistHome.of(itemIds: ["show:a", "show:b"], isRoutine: false, markedForm: { _ in nil }) == .podcasts)
    }

    @Test("a list of episodes becomes the folder of their shows: first appearance, no show twice, a show of another folder stays there; the unheard go to Up Next")
    func migration() {
        let ids = ["rss:a:1", "rss:b:1", "rss:a:2", "rss:c:1", "rss:d:1"]
        let migrated = PodcastFolder.migrated(ids,
                                              feedKeyOf: { $0.split(separator: ":")[1].description },
                                              isHeard: { $0 == "rss:a:1" || $0 == "rss:c:1" },
                                              inOtherFolders: ["d"])
        #expect(migrated.entries == ["show:a", "show:b", "show:c"])
        #expect(migrated.toUpNext == ["rss:b:1", "rss:a:2", "rss:d:1"])
        let again = PodcastFolder.migrated(migrated.entries, feedKeyOf: { _ in nil }, isHeard: { _ in false }, inOtherFolders: [])
        #expect(again.entries == migrated.entries && again.toUpNext.isEmpty, "a second run changes nothing")
        #expect(!PodcastFolder.needsMigration(["show:a"]))
        #expect(PodcastFolder.needsMigration(["rss:a:1"]))
        #expect(!PodcastFolder.needsMigration(["rss:a:1", "sub:song:1"]), "a mixed list is no podcast list")
    }

    @Test("a show in a folder leaves the loose grid; the tile counts the new episodes of all its shows")
    func gridAndCount() {
        let folded = PodcastFolder.foldedShows(in: [["show:a", "show:b"], ["rss:x:1"], ["show:c"]])
        #expect(folded == ["a", "b", "c"])
        #expect(PodcastFolder.loose(["a", "x", "c", "y"], folded: folded) == ["x", "y"])
        #expect(PodcastFolder.newCount(["show:a", "show:b"], new: { $0 == "a" ? 2 : 3 }) == 5)
    }

    @Test("a folder starts the newest episode of each show, through the rule of a routine")
    func start() {
        #expect(PodcastFolder.ruleIds(["show:a", "show:b"]) == ["rule:newest:a", "rule:newest:b"])
    }

    @Test("Fence: the Podcasts tab shows folders with a start button, the page starts and shuffles, the grid hides folded shows, a show can go into a folder", .needsTheSources)
    func surfaces() throws {
        let all = ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]).map { SyncContractFenceTests.stripped($0.1) }.joined(separator: "\n")
        #expect(all.contains("PodcastFolderRow("), "no folder row in the Podcasts tab")
        #expect(all.contains("PodcastFolderPage("), "no folder page")
        #expect(all.contains("PodcastFolder.loose("), "the grid does not hide folded shows")
        #expect(all.contains("PodcastFolder.ruleIds("), "a folder does not start through the routine's rule")
        #expect(all.contains("PodcastFolder.migrated("), "no migration of podcast lists")
        #expect(all.contains("AddShowToFolderSheet("), "a show cannot go into a folder")
    }
}

/// The move of the lists on devices that share a carrier: each folds its
/// own lists at start and a list that arrives by a merge after it; the
/// same input gives the same folder, so the devices settle and stop
/// writing, and each puts the unheard episodes in its own Up Next once.
@MainActor
@Suite(.serialized)
struct PodcastFolderSyncTests {
    private final class RecordingCarrier: PlaylistCarrier {
        var name: String { "recording" }
        var snapshot = MaerPlaylistMerge.Snapshot()
        var stores = 0
        func held() -> MaerPlaylistMerge.Snapshot { snapshot }
        func store(_ snapshot: MaerPlaylistMerge.Snapshot) {
            self.snapshot = snapshot
            stores += 1
        }
        func start(onChange: @escaping @MainActor () -> Void) {}
        func stop() {}
        func refresh(by caller: String) async {}
    }

    private final class Device {
        let store: MaerPlaylists
        var runner: MaerPlaylistCloudSync!
        var upNext: [String] = []
        var enqueuedBefore: Set<String> = []
        init(store: MaerPlaylists) { self.store = store }
        func fold() {
            store.foldPodcastLists(isHeard: { $0.hasSuffix(":heard") }, enqueue: { self.upNext += $0 },
                                   enqueuedBefore: &enqueuedBefore)
        }
    }

    private func device(_ name: String, on carrier: RecordingCarrier, in directory: URL) -> Device {
        let device = Device(store: MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("\(name).sqlite").path)))
        device.runner = MaerPlaylistCloudSync(carrier: carrier, playlists: device.store, itemIdMap: { $0 },
                                              deviceName: { name }, idFormSettled: { true },
                                              afterMerge: { [weak device] _ in device?.fold() })
        return device
    }

    @Test("a list of episodes from the carrier becomes a folder after the merge; both devices settle on it without a rescue copy and stop writing; Up Next once per device")
    func aMergedListFoldsAndSettles() throws {
        let restore = SyncSwitchProbe.armOn()
        defer { restore() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = RecordingCarrier()
        let a = device("Geraet-A", on: carrier, in: directory)
        let b = device("Geraet-B", on: carrier, in: directory)

        let list = a.store.create(name: "Morgens")
        _ = a.store.add(itemId: "rss:f:e1", to: list.id)
        _ = a.store.add(itemId: "rss:g:e2:heard", to: list.id)
        a.runner.reconcile()
        #expect(carrier.snapshot.lists[list.id]?.itemIds == ["rss:f:e1", "rss:g:e2:heard"], "the precondition: the list of episodes travels")
        // B receives the list of episodes and folds it after the merge; A
        // folds its own at its next start.
        b.runner.reconcile()
        a.fold()
        for _ in 0..<3 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        let folder = ["show:f", "show:g"]
        #expect(a.store.playlist(id: list.id)?.itemIds == folder)
        #expect(b.store.playlist(id: list.id)?.itemIds == folder, "the list that came by the merge is a folder")
        #expect(carrier.snapshot.lists[list.id]?.itemIds == folder)
        #expect(a.store.playlists.filter(\.isRescue).isEmpty && b.store.playlists.filter(\.isRescue).isEmpty, "a rescue copy")
        #expect(a.upNext == ["rss:f:e1"] && b.upNext == ["rss:f:e1"], "Up Next once on each device, the unheard only")

        let settled = carrier.stores
        for _ in 0..<5 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        #expect(carrier.stores == settled, "the devices write the folder back and forth")
        #expect(a.upNext == ["rss:f:e1"] && b.upNext == ["rss:f:e1"])

        // A device that joins later never held the episodes: it gets the
        // folder and nothing in its Up Next.
        let c = device("Geraet-C", on: carrier, in: directory)
        c.runner.reconcile()
        c.fold()
        #expect(c.store.playlist(id: list.id)?.itemIds == folder)
        #expect(c.upNext.isEmpty, "a device that never held the list fills its Up Next")
    }

    @Test("a sync without the hook leaves a list of episodes as it is: a witness's own store never folds")
    func withoutTheHookNothingFolds() throws {
        let restore = SyncSwitchProbe.armOn()
        defer { restore() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-nohook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = RecordingCarrier()
        let storeA = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("A.sqlite").path))
        let storeB = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("B.sqlite").path))
        let runA = MaerPlaylistCloudSync(carrier: carrier, playlists: storeA, itemIdMap: { $0 }, deviceName: { "A" }, idFormSettled: { true })
        let runB = MaerPlaylistCloudSync(carrier: carrier, playlists: storeB, itemIdMap: { $0 }, deviceName: { "B" }, idFormSettled: { true })
        let list = storeA.create(name: "Morgens")
        _ = storeA.add(itemId: "rss:f:e1", to: list.id)
        runA.reconcile()
        runB.reconcile()
        #expect(storeB.playlist(id: list.id)?.itemIds == ["rss:f:e1"])
    }
}
#endif
