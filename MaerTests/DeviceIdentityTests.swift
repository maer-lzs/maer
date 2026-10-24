// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The name the other devices see for this one.
struct DeviceIdentityTests {
    @Test("auf dem Mac heisst das Geraet Mac, nicht iPad; iPhone und iPad behalten den Namen des Systems")
    func theMacIsNotAnIPad() {
        #expect(DeviceIdentity.name(system: "iPad", onMac: true) == "Mac")
        #expect(DeviceIdentity.name(system: "iPad", onMac: false) == "iPad")
        #expect(DeviceIdentity.name(system: "iPhone", onMac: false) == "iPhone")
    }

    @Test("die Frage, ob die App auf einem Mac laeuft, stellt nur PlatformIdiom; DeviceIdentity fragt dort", .needsTheSources)
    func oneQuestionForTheMac() throws {
        var askers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "PlatformScrubber.swift" {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if text.contains("isiOSAppOnMac") || text.contains("isMacCatalystApp") { askers.append(file.lastPathComponent) }
        }
        #expect(askers.isEmpty, "a second place asks the system whether it runs on a Mac: \(askers)")
        let identity = try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/DeviceIdentity.swift"), encoding: .utf8)
        #expect(identity.contains("onMac: PlatformIdiom.isAppOnMac"), "DeviceIdentity does not ask the one place")
    }
}
#endif
