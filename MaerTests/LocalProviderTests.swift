// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

/// #62/V4: the pure stored-pair → BookProgress math behind the off-main
/// `fetchAllProgress` loop.
struct LocalProviderTests {
    @Test("Stored [time, lastUpdate] pair maps to clamped progress")
    func pairMapsToProgress() {
        let p = LocalProvider.storedProgress([300, 1_700_000_000], duration: 600)
        #expect(p?.fraction == 0.5)
        #expect(p?.isFinished == false)
        #expect(p?.currentTime == 300)
        #expect(p?.lastUpdate == 1_700_000_000)
        // Overshoot clamps, and the last second counts as finished.
        let end = LocalProvider.storedProgress([650, 1], duration: 600)
        #expect(end?.fraction == 1)
        #expect(end?.isFinished == true)
    }

    @Test("Malformed shapes and zero duration yield nil")
    func malformedYieldsNil() {
        #expect(LocalProvider.storedProgress(nil, duration: 600) == nil)
        #expect(LocalProvider.storedProgress([300], duration: 600) == nil)
        // Drei Werte sind GUELTIG: der dritte ist die Dauer, die beim
        // Markieren galt (ProgressMark).
        #expect(LocalProvider.storedProgress([1, 2, 3], duration: 600) != nil)
        #expect(LocalProvider.storedProgress([300, 1], duration: 0) == nil)
    }
}
#endif
