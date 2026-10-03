// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A device name on its own is nothing to write. Each device stamps its own
/// name on every list it reconciles; comparing the name made two devices
/// rewrite the same content after each other on every round. The witnesses
/// run two devices on one carrier through the name seam and count the
/// writes once things have settled.
@MainActor
@Suite(.serialized)
struct PlaylistDeviceNameTests {
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

    /// One device: its own store in its own directory, its own name.
    private struct Device {
        let store: MaerPlaylists
        let runner: MaerPlaylistCloudSync
    }

    private func device(_ name: String, on carrier: RecordingCarrier, in directory: URL) -> Device {
        let store = MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("\(name).sqlite").path))
        let runner = MaerPlaylistCloudSync(carrier: carrier, playlists: store,
                                           itemIdMap: { $0 }, deviceName: { name })
        return Device(store: store, runner: runner)
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devname-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("der Vergleich sieht den Geraetenamen nicht, jede andere Abweichung schon")
    func theComparisonIgnoresOnlyTheDeviceName() {
        let base = MaerPlaylistMerge.Entry(name: "Morgens", updatedAt: 100, itemIds: ["rss:a"],
                                           device: "iPhone")
        var renamedDevice = base
        renamedDevice.device = "iPad"
        var unnamed = base
        unnamed.device = nil
        #expect(!MaerPlaylistMerge.differs(["l": base], ["l": renamedDevice]))
        #expect(!MaerPlaylistMerge.differs(["l": base], ["l": unnamed]))

        var moreItems = renamedDevice
        moreItems.itemIds.append("rss:b")
        var laterClock = base
        laterClock.updatedAt = 101
        var otherListName = base
        otherListName.name = "Abends"
        #expect(MaerPlaylistMerge.differs(["l": base], ["l": moreItems]))
        #expect(MaerPlaylistMerge.differs(["l": base], ["l": laterClock]))
        #expect(MaerPlaylistMerge.differs(["l": base], ["l": otherListName]))
        #expect(MaerPlaylistMerge.differs(["l": base], [:]))
    }

    @Test("zwei Geraete auf einem Traeger: nach dem Einschwingen kein Schrieb ueber fuenf Runden, eine echte Aenderung schreibt einmal mit eigenem Namen")
    func twoDevicesSettleAndStayQuiet() throws {
        let restore = SyncSwitchProbe.armOn()
        defer { restore() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = RecordingCarrier()
        let a = device("Geraet-A", on: carrier, in: directory)
        let b = device("Geraet-B", on: carrier, in: directory)

        let list = a.store.create(name: "Morgens")
        _ = a.store.add(itemId: "rss:f:e1", to: list.id)
        for _ in 0..<3 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        #expect(carrier.stores >= 1, "the list reached the carrier at all")
        #expect(b.store.playlist(id: list.id)?.itemIds == ["rss:f:e1"], "the other device holds the list")

        let settled = carrier.stores
        for _ in 0..<5 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        #expect(carrier.stores == settled, "two device names alone are no reason to write")

        _ = b.store.add(itemId: "rss:f:e2", to: list.id)
        b.runner.reconcile()
        #expect(carrier.stores == settled + 1, "a real change is written once")
        let written = try #require(carrier.snapshot.lists[list.id])
        #expect(written.device == "Geraet-B", "the change carries the name of the device that made it")
        #expect(written.itemIds == ["rss:f:e1", "rss:f:e2"])

        let changed = carrier.stores
        for _ in 0..<5 {
            a.runner.reconcile()
            b.runner.reconcile()
        }
        #expect(carrier.stores == changed, "quiet again after the change")
        #expect(a.store.playlist(id: list.id)?.itemIds == ["rss:f:e1", "rss:f:e2"], "the change arrived")
        withExtendedLifetime((a.runner, b.runner)) {}
    }

    @Test("ein Schreiber wie 3.3 stempelt in jeder Runde seinen Namen, der neue Laeufer schreibt danach null Mal")
    func anOldBuildStampingEveryRoundGetsNoAnswer() throws {
        let restore = SyncSwitchProbe.armOn()
        defer { restore() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let carrier = RecordingCarrier()
        let a = device("Geraet-A", on: carrier, in: directory)

        let list = a.store.create(name: "Morgens")
        _ = a.store.add(itemId: "rss:f:e1", to: list.id)
        a.runner.reconcile()
        #expect(carrier.snapshot.lists[list.id]?.device == "Geraet-A", "the list stands at the carrier")

        // The old build writes the same content and clock under its own
        // name whenever it reconciles. Here it does so on every round, past
        // the runner's counter, which only counts the new runner's writes.
        let settled = carrier.stores
        for _ in 0..<5 {
            for (id, entry) in carrier.snapshot.lists {
                var stamped = entry
                stamped.device = "Altes-Geraet"
                carrier.snapshot.lists[id] = stamped
            }
            a.runner.reconcile()
        }
        #expect(carrier.snapshot.lists[list.id]?.device == "Altes-Geraet", "the old build's name stood there each round")
        #expect(carrier.stores == settled, "the new runner never answers a name")
        withExtendedLifetime(a.runner) {}
    }

    /// The name the system hands out is read in one place and reaches the
    /// sync code as an input: the default of a seam, so a witness can run
    /// two devices. The one named exception is the key-value carrier's
    /// fallback for a blob entry written without a name.
    @Test("DeviceIdentity.name steht nur als Vorgabe einer Naht oder an der benannten Stelle", .needsTheSources)
    func theDeviceNameIsReadOnlyAtASeam() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the fence read the sources")

        var seams: [String] = []
        var exceptions: [String] = []
        var direct: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains("DeviceIdentity.name") else { continue }
                let squeezed = code.replacingOccurrences(of: " ", with: "")
                let place = "\(file.lastPathComponent): \(code)"
                if squeezed.contains("@escaping()->String={DeviceIdentity.name}") {
                    seams.append(place)
                } else if file.lastPathComponent == "PlaylistCarrier.swift",
                          squeezed == "staticvardeviceName:String{DeviceIdentity.name}" {
                    exceptions.append(place)
                } else {
                    direct.append(place)
                }
            }
        }
        #expect(direct.isEmpty, "read DeviceIdentity.name through a seam: \(direct)")
        #expect(seams.count == 2, "the seams of the playlist runner and the claim runner: \(seams)")
        #expect(exceptions.count == 1, "the named exception still stands, or its entry goes: \(exceptions)")
    }
}
#endif
