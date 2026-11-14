// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Combine
@testable import Maer

/// A routine's rules travel as text in a Mär playlist. Each of the three
/// wires hands them back as written, and a build that knows no rule carries
/// them, writes nothing for them and asks no source about them. The ids are
/// written out here, not built by `RoutineRule`, so the same file runs
/// against a build without routines.
@MainActor
@Suite(.serialized)
struct RoutineCarryTests {
    /// One rule of each spelling; `RoutineRuleTests` reads them as rules.
    nonisolated static let ruleIds = ["rule:newest:9f2c", "rule:next:4e1a", "rule:next:3:b07d"]

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

    private struct Device {
        let store: MaerPlaylists
        let runner: MaerPlaylistCloudSync
    }

    /// The music server's id move runs as on a device with the new ids, so
    /// the round reads the rules through it as well.
    private func device(_ name: String, on carrier: RecordingCarrier, in directory: URL) -> Device {
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("\(name).sqlite").path))
        let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store,
                                           itemIdMap: { SubsonicProvider.canonicalItemId($0, canonical: true) },
                                           deviceName: { name }, idFormSettled: { true })
        return Device(store: store, runner: runner)
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routine-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("three wires carry the rules of a routine there and back, in order, with their stamps")
    func threeWiresCarryTheRules() throws {
        let itemIds = ["rss:f:e1"] + Self.ruleIds
        var added: [String: Double] = [:]
        for (offset, id) in itemIds.enumerated() { added[id] = 1_700_000_000 + Double(offset) }
        let entry = MaerPlaylistMerge.Entry(name: "Morgens", updatedAt: 1_700_000_010, itemIds: itemIds,
                                            titles: ["rss:f:e1": "Folge 1"], nameUpdatedAt: 1_700_000_000,
                                            removed: ["rule:next:2:b07d": 1_699_999_000],
                                            added: added, device: "phone")
        var snapshot = MaerPlaylistMerge.Snapshot()
        snapshot.lists["l1"] = entry

        let kvs = KeyValuePlaylistCarrier(store: InMemoryCloudStore())
        kvs.store(snapshot)
        let service = MaerSyncPlaylistWire.decode(try MaerSyncPlaylistWire.encode(snapshot))?.lists["l1"]
        let cloudKit = MaerPlaylistEntryWire.decode(MaerPlaylistEntryWire.encode(entry))
        for (wire, back) in [("kvs", kvs.held().lists["l1"]), ("service", service), ("cloudkit", cloudKit)] {
            let back = try #require(back, "\(wire) read the list back")
            #expect(back.itemIds == itemIds, "\(wire) keeps every rule in its place")
            #expect(back.added == added && back.removed == entry.removed, "\(wire) keeps the stamps of the rules")
            #expect(MaerPlaylistMerge.isSameVersion(back, entry), "\(wire) changes no field")
        }
    }

    @Test("a state without routines on the same carrier: the rules travel along, settled over five rounds no write on the carrier and none in a store")
    func aBuildWithoutRoutinesCarriesThemQuietly() throws {
        let restore = SyncSwitchProbe.armOn()
        defer { restore() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = RecordingCarrier()
        let a = device("Geraet-A", on: carrier, in: directory)
        let b = device("Geraet-B", on: carrier, in: directory)

        let list = a.store.create(name: "Morgens")
        for id in ["rss:f:e1"] + Self.ruleIds {
            #expect(a.store.add(itemId: id, to: list.id) == .added, "\(id) is an entry like any other")
        }
        let itemIds = ["rss:f:e1"] + Self.ruleIds
        for _ in 0..<3 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        #expect(carrier.snapshot.lists[list.id]?.itemIds == itemIds, "the carrier holds the rules")
        #expect(b.store.playlist(id: list.id)?.itemIds == itemIds, "the other device holds them too")

        final class Counter { var writes = 0 }
        let local = Counter()
        let watching = [a.store.objectWillChange.sink { local.writes += 1 },
                        b.store.objectWillChange.sink { local.writes += 1 }]
        let settled = carrier.stores
        for _ in 0..<5 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        #expect(carrier.stores == settled, "a rule is no reason to write")
        #expect(local.writes == 0, "no write to either store: \(local.writes)")

        // A real change beside the rules is written once and leaves them in place.
        _ = b.store.add(itemId: "rss:f:e2", to: list.id)
        #expect(local.writes > 0, "the precondition: the change signal counts a store write")
        b.runner.reconcile()
        #expect(carrier.stores == settled + 1, "a real change is written once")
        a.runner.reconcile()
        #expect(a.store.playlist(id: list.id)?.itemIds == itemIds + ["rss:f:e2"], "the rules stay where they were")
        withExtendedLifetime((a.runner, b.runner, watching)) {}
    }

    /// The same file runs in a build without routines, so it asks what both
    /// builds answer alike: no source, no cover, no title, nothing to play.
    @Test("a state without routines asks no source for a rule, does not play it as a title and heals no title")
    func aBuildWithoutRoutinesAsksNoSource() async throws {
        for id in Self.ruleIds {
            #expect(AppSession.shared.provider(for: id) is UnknownSourceProvider, "\(id) reaches no source")
            #expect(AppSession.shared.coverURL(forItemId: id) == nil)
            #expect(AppSession.shared.libraryItem(forId: id) == nil)
            #expect(AppSession.shared.resolve(forId: id, carried: nil).item == nil, "dimmed and skipped")
        }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("one.sqlite").path))
        let list = store.create(name: "Morgens")
        for id in Self.ruleIds { _ = store.add(itemId: id, to: list.id) }

        final class Counter { var writes = 0 }
        let local = Counter()
        let watching = store.objectWillChange.sink { local.writes += 1 }
        // What opening the list page does, then the healing it starts, to its end.
        let healing = store.backfillTitles(playlistId: list.id)
        #expect(healing == nil, "a rule is no title: the page asks no source for it")
        await healing?.value
        await store.fetchMissingTitles(Self.ruleIds, playlistId: list.id)
        #expect(local.writes == 0, "nothing learned, nothing written: \(local.writes)")
        #expect(store.playlist(id: list.id)?.snapshots.isEmpty == true)
        #expect(store.playlist(id: list.id)?.itemIds == Self.ruleIds)
        withExtendedLifetime(watching) {}
    }

    @Test("the healing of titles asks only entries without an image that name a title, no rule")
    func theHealingAsksTitlesNotRules() {
        var list = MaerPlaylists.Playlist(id: "l", name: "Morgens", updatedAt: 1,
                                          itemIds: ["sub:song:1", "rule:newest:abc", "rule:later:9:abc", "lva:2"])
        list.snapshots["lva:2"] = CarriedItem(id: "lva:2", title: "Kept")
        #expect(MaerPlaylists.untitled(list) == ["sub:song:1"],
                "a rule, also in a form this build does not read, and a kept entry are not asked")
    }
}
#endif
