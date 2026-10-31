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
        #expect(TestProcess.isUnitTestHost, "the precondition: this process is the unit test host")
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

    /// Who names the monitor under `Sources/Networking` and
    /// `Sources/Providers`, each with its reason. The stock holds in both
    /// directions: a new file is a finding, and so is an entry that no
    /// longer names the monitor. Every other reader stands in
    /// `outsideStock`.
    nonisolated static let monitorStock: [String: String] = [
        "Reachability.swift": "the door itself",
        "MaerSyncCarriers.swift": "hands the monitor to the sync session as its path source, it reads nothing",
        "RoutinePlayback.swift": "a list page counts a routine's episodes synchronously; the start asks the door",
    ]

    @Test("unter Networking und Providers nennt nur der Bestand den Netzwaechter, jeder mit Grund, in beide Richtungen", .needsTheSources)
    func onlyTheStockNamesTheMonitor() throws {
        var files: [URL] = []
        for folder in ["Sources/Networking", "Sources/Providers"] {
            let root = SourceTree.root.appendingPathComponent(folder)
            files += SourceTree.files(under: root).filter { $0.pathExtension == "swift" }
        }
        #expect(files.contains { $0.lastPathComponent == "Reachability.swift" }, "the fence read Networking")
        #expect(files.contains { $0.lastPathComponent == "ProviderSearch.swift" }, "the fence read Providers")
        var naming: Set<String> = []
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("NetworkMonitor.shared") { naming.insert(file.lastPathComponent) }
        }
        #expect(naming == Set(Self.monitorStock.keys), "names the monitor outside the stock or left it: \(naming.sorted())")
    }

    /// Who reads the monitor outside those two folders, each with what the
    /// answer decides. Only two of them show it; the others decide before a
    /// load or a playback, synchronously, so they cannot ask the door
    /// (`async`). In the test host they follow the machine's network, and
    /// no fence keeps a witness from leaning on that; this stock only keeps
    /// the list true in both directions.
    nonisolated static let outsideStock: [String: String] = [
        "RootView.swift": "shows: the offline banner observes it",
        "PodcastHelpers.swift": "shows: the episode menu offers play and download by it",
        "FreeCatalogStore.swift": "decides: its four load gates start a catalog pass by it",
        "PlayerCoordinator.swift": "decides: opening refuses an undownloaded title offline, both next-item picks skip one, and a path change rebuilds a stopped load failure",
        "PlayerViewModel.swift": "decides: a missing track download restarts, and a failed local file is dropped for streaming",
        "PodcastAutoContinue.swift": "decides: offline the next episode is picked among the downloaded ones",
        "Lyrics.swift": "decides: offline LRCLIB is not asked and the round books a failure",
        "RadioArtwork.swift": "decides: a logo that does not serve is booked as a failure only online",
    ]

    @Test("ausserhalb von Networking und Providers lesen nur die genannten Dateien den Netzwaechter, in beide Richtungen", .needsTheSources)
    func onlyTheNamedFilesReadTheMonitorOutside() throws {
        let fenced = ["/Sources/Networking/", "/Sources/Providers/"]
        var naming: Set<String> = []
        var read = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where !fenced.contains(where: { file.path.contains($0) }) {
            read += 1
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("NetworkMonitor.shared") { naming.insert(file.lastPathComponent) }
        }
        #expect(read > 0, "the fence read no source outside the two folders")
        #expect(naming == Set(Self.outsideStock.keys), "reads the monitor outside the stock or left it: \(naming.sorted())")
    }

    /// The one answer to "does this process run under a test?": no other
    /// source reads the test host's environment key or asks the harness in
    /// its place.
    @Test("nur TestProcess beantwortet, ob der Prozess unter einem Test laeuft", .needsTheSources)
    func oneAnswerToUnderTest() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = SourceTree.files(under: sources).filter { $0.pathExtension == "swift" }
        var reading: [String] = []
        for file in files where file.lastPathComponent != "TestProcess.swift" {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("XCTestConfigurationFilePath") { reading.append(file.lastPathComponent) }
        }
        #expect(!files.isEmpty, "the fence read the sources")
        #expect(reading.isEmpty, "the test host's key read outside TestProcess: \(reading)")
        #expect(TestProcess.isUnderTest, "the unit test host is under test")
    }
}
#endif
