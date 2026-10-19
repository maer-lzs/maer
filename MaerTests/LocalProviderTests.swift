// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The stored pair → BookProgress math behind the off-main
/// `fetchAllProgress` loop of local files: the one rule of every source
/// whose continue lives on the device, no copy of it in the provider.
struct LocalProviderTests {
    @Test("Stored [time, lastUpdate] pair maps to clamped progress")
    func pairMapsToProgress() {
        let p = BookmarkProgressMath.progress(fromStand: [300, 1_700_000_000], duration: 600)
        #expect(p?.fraction == 0.5)
        #expect(p?.isFinished == false)
        #expect(p?.currentTime == 300)
        #expect(p?.lastUpdate == 1_700_000_000)
        // Overshoot clamps, and the last second counts as finished.
        let end = BookmarkProgressMath.progress(fromStand: [650, 1], duration: 600)
        #expect(end?.fraction == 1)
        #expect(end?.isFinished == true)
    }

    @Test("Malformed shapes and zero duration yield nil")
    func malformedYieldsNil() {
        #expect(BookmarkProgressMath.progress(fromStand: nil, duration: 600) == nil)
        #expect(BookmarkProgressMath.progress(fromStand: [300], duration: 600) == nil)
        // Three values are valid: the third is the duration that applied
        // when the mark was written (ProgressMark).
        #expect(BookmarkProgressMath.progress(fromStand: [1, 2, 3], duration: 600) != nil)
        #expect(BookmarkProgressMath.progress(fromStand: [300, 1], duration: 0) == nil)
    }

    @Test("der Anbieter lokaler Dateien fragt die eine Regel und baut keinen Fortschritt selbst", .needsTheSources)
    func theProviderAsksTheOneRule() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/LocalProvider.swift"), encoding: .utf8))
        #expect(code.contains("BookmarkProgressMath.progress(fromStand:"), "the provider no longer asks the rule")
        #expect(!code.contains("BookProgress("), "the provider builds a progress of its own again")
    }
}
#endif
