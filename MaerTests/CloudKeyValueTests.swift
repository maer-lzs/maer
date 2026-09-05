// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one door to the shared cloud store, and the two fences around it:
/// on a DEBUG build on the simulator the door leads to memory, every
/// family takes its store from the door, and every start of the UI harness
/// says so with an argument.
struct CloudKeyValueTests {
    @Test("Auf dem Simulator fuehrt die Tuer in den Speicher, nicht ins Konto")
    @MainActor
    func theDoorLeadsToMemoryOnTheSimulator() {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["MAER_LIVE_KVS"] != "1" {
            #expect(!CloudKeyValue.isLive, "a simulator build must never reach a real account")
            #expect(CloudKeyValue.notificationObject == nil)
            #expect(CloudKeyValue.store is InMemoryCloudStore)
        }
        #endif
    }

    @Test("Der Speicher hinter der Tuer spricht das Protokoll wie der echte")
    @MainActor
    func theMemoryStoreSpeaksTheProtocol() {
        let store = InMemoryCloudStore()
        store.set(["a": 1], forKey: "pot")
        store.set([1, 2], forKey: "list")
        #expect(store.dictionary(forKey: "pot")?["a"] as? Int == 1)
        #expect(store.array(forKey: "list")?.count == 2)
        #expect(store.dictionaryRepresentation.keys.sorted() == ["list", "pot"])
        #expect(store.synchronize())
        store.removeObject(forKey: "list")
        store.set(nil, forKey: "pot")
        #expect(store.dictionaryRepresentation.isEmpty)
    }

    // MARK: - Fences

    /// The only file that may name the real store is the door itself.
    @Test("Den echten Speicher nennt nur die Tuer")
    func onlyTheDoorNamesTheRealStore() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "CloudKeyValue.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("NSUbiquitousKeyValueStore.default") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "these files reach the real store past the door: \(offenders)")
    }

    /// Between `XCUIApplication()` and its `.launch()` a harness argument
    /// must be set: the app started by a UI test is a different process,
    /// and only the argument tells it so. Pure over one file's text, so
    /// the red probe feeds the checker.
    nonisolated static func launchesWithoutHarnessMarker(in text: String) -> Int {
        var count = 0
        var search = text.startIndex
        while let start = text.range(of: "XCUIApplication()", range: search..<text.endIndex) {
            guard let launch = text.range(of: ".launch()", range: start.upperBound..<text.endIndex) else { break }
            if !text[start.upperBound..<launch.lowerBound].contains("-uitest") { count += 1 }
            search = launch.upperBound
        }
        return count
    }

    @Test("Jede Startstelle der UI-Tests setzt ein Harness-Argument")
    func everyUILaunchCarriesTheMarker() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("MaerUITests"),
                                                   includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let bare = Self.launchesWithoutHarnessMarker(in: try String(contentsOf: file, encoding: .utf8))
            if bare > 0 { offenders.append("\(file.lastPathComponent): \(bare)") }
        }
        #expect(offenders.isEmpty, "UI tests that start the app without a harness argument: \(offenders)")
        // Red probes on the checker, both directions.
        #expect(Self.launchesWithoutHarnessMarker(in: """
            let app = XCUIApplication()
            app.launch()
            """) == 1)
        #expect(Self.launchesWithoutHarnessMarker(in: """
            let app = XCUIApplication()
            app.launchArguments += ["-uitest-harness"] + extra
            app.launch()
            """) == 0)
    }
}
#endif
