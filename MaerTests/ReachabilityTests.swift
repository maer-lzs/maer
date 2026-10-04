// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one door the services ask before the network, and its reach.
struct ReachabilityTests {
    @Test("die Tuer folgt der Antwort des Tests, nicht dem Netz des Wirts")
    func theDoorFollowsTheTestsAnswer() async {
        await Reachability.$assumed.withValue(false) {
            #expect(await Reachability.isConnected() == false)
        }
        await Reachability.$assumed.withValue(true) {
            #expect(await Reachability.isConnected() == true)
        }
    }

    @Test("ohne Netz fragt ein Dienst nichts, mit Netz fragt er, unabhaengig vom Wirt")
    func aServiceAsksOnlyWhenTheDoorSaysSo() async {
        let suite = "reachability-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let wire = RememberedNoneTests.Wire(["one": .files([(format: "VBR MP3", length: "600")])])
        let service = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        await Reachability.$assumed.withValue(false) {
            #expect(await service.runtimeSeconds(identifier: "one") == nil)
        }
        #expect(wire.asks("one") == 0, "offline, the service asked the wire")
        await Reachability.$assumed.withValue(true) {
            #expect(await service.runtimeSeconds(identifier: "one") == 600)
        }
        #expect(wire.asks("one") == 1, "online, the service did not ask")
    }

    /// In the unit test host the door never asks the machine's network: a
    /// suite that sets nothing gets "there", whatever the host's network is.
    @Test("im Test-Wirt fragt die Tuer nie das Netz des Rechners, ohne Antwort des Tests ist das Netz da")
    func theTestHostNeverAsksTheMachine() async {
        #expect(Reachability.inTestHost, "the precondition: this process is the unit test host")
        #expect(Reachability.assumed == nil, "the precondition: the test set no answer")
        #expect(await Reachability.isConnected() == true)
    }

    /// The services' network paths ask the door, none of them the monitor:
    /// a path that asks the monitor itself follows the host in every witness.
    @Test("jeder Netzweg der Dienste fragt die Tuer, keiner den Netzwaechter", .needsTheSources)
    func everyNetworkPathAsksTheDoor() throws {
        let paths = ["ArchiveRuntimeService", "FeedArtworkService", "RadioLogoService", "ArtistPortraitService",
                     "RadioArtworkService", "CoverArtArchive", "Artwork"]
        for name in paths {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/\(name).swift"), encoding: .utf8))
            #expect(code.contains("await Reachability.isConnected()"), "\(name) does not ask the door")
            #expect(!code.contains("NetworkMonitor.shared"), "\(name) asks the monitor itself")
        }
        let door = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/Reachability.swift"), encoding: .utf8))
        #expect(door.contains("return await NetworkMonitor.shared.isConnected"), "the door does not ask the monitor")
    }

    /// Who names the monitor under `Sources/Networking`, each with its
    /// reason. The stock holds in both directions: a new file is a finding,
    /// and so is an entry that no longer names the monitor.
    nonisolated static let monitorStock: [String: String] = [
        "Reachability.swift": "the door itself",
        "APIClient.swift": "the audiobook search falls back to its offline search when the monitor says offline",
        "MaerSyncCarriers.swift": "hands the monitor to the sync session as its path source, it reads nothing",
    ]

    @Test("unter Networking nennt nur der Bestand den Netzwaechter, jeder mit Grund, in beide Richtungen", .needsTheSources)
    func onlyTheStockNamesTheMonitor() throws {
        let networking = SourceTree.root.appendingPathComponent("Sources/Networking")
        let files = try #require(FileManager.default.enumerator(at: networking, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "Reachability.swift" }, "the fence read the folder")
        var naming: Set<String> = []
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("NetworkMonitor.shared") { naming.insert(file.lastPathComponent) }
        }
        #expect(naming == Set(Self.monitorStock.keys), "names the monitor outside the stock or left it: \(naming.sorted())")
    }
}
#endif
