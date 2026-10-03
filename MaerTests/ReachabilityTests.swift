// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Runs every test of a suite as if the network were there, so a witness
/// that fakes a service's wire or serves on the loopback does not follow the
/// network of the machine it runs on.
struct ReachableNetwork: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable @concurrent () async throws -> Void) async throws {
        try await Reachability.$assumed.withValue(true) { try await function() }
    }
}

extension Trait where Self == ReachableNetwork {
    static var reachableNetwork: Self { Self() }
}

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

    @Test("der Trait reicht in jeden Test der Suite", .reachableNetwork)
    func theTraitReachesTheTest() async {
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
}
#endif
