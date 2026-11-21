// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A CarPlay rebuild cannot run in the test host, so what one costs is
/// counted on a device: every rebuild writes one line with the covers it
/// asked for, and every cover of the car goes through the one counting way.
struct CarPlayRebuildLineTests {
    @Test("Fence: every cover of the car is asked through the counting way, and a rebuild names its count", .needsTheSources)
    func rebuildNamesItsCovers() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/CarPlay/CarPlaySceneDelegate.swift"), encoding: .utf8))
        #expect(code.components(separatedBy: "Artwork.thumbnail(").count - 1 == 1, "a cover past the counting way")
        #expect(code.contains("coversAsked += 1"))
        #expect(code.contains("CARPLAY rebuild covers="), "a rebuild names no count")
    }
}
#endif
