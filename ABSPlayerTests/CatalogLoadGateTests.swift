// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
@testable import ABSPlayer

/// The gate that decides whether reading the catalogue rows may start a load.
///
/// The regression it fences: reading and loading are deliberately inseparable,
/// so the getter starts the fetch. While the decision asked whether CONTENT had
/// arrived, a pass that came back empty left the answer at "no". The next body
/// evaluation started the next pass, its publish re-rendered the view, the
/// render read again. Measured: 100 % CPU, the app drawing and answering no
/// touch at all; five journeys failed as "toggle does not flip" and "menu item
/// not hittable".
///
/// The calls are made into a local first because the check macro cannot invoke
/// a mutating member.
struct CatalogLoadGateTests {
    @Test("an empty pass is still a pass")
    func emptyPassCounts() {
        var gate = CatalogLoadGate()
        let first = gate.startIfNeeded(connected: true)
        #expect(first)
        gate.finish()
        // Nothing arrived. And it must STILL not start again by itself.
        let second = gate.startIfNeeded(connected: true)
        let third = gate.startIfNeeded(connected: true)
        #expect(!second)
        #expect(!third)
    }

    @Test("no two passes at once")
    func oneAtATime() {
        var gate = CatalogLoadGate()
        let first = gate.startIfNeeded(connected: true)
        let whileRunning = gate.startIfNeeded(connected: true)
        let explicitWhileRunning = gate.beginExplicit()
        #expect(first)
        #expect(!whileRunning)
        #expect(!explicitWhileRunning)
        gate.finish()
    }

    @Test("offline is not an attempt")
    func offlineIsNoAttempt() {
        var gate = CatalogLoadGate()
        let offline = gate.startIfNeeded(connected: false)
        // The first read after the network returns starts one.
        let backOnline = gate.startIfNeeded(connected: true)
        #expect(!offline)
        #expect(backOnline)
    }

    @Test("the explicit paths open a new attempt")
    func explicitPathsReopen() {
        var gate = CatalogLoadGate()
        let first = gate.startIfNeeded(connected: true)
        gate.finish()
        let used = gate.startIfNeeded(connected: true)
        // Retry, language change, network back.
        gate.reopen()
        let reopened = gate.startIfNeeded(connected: true)
        #expect(first)
        #expect(!used)
        #expect(reopened)
        gate.finish()
    }

    /// An explicit pass (pull to refresh, a page's own task) runs even when the
    /// automatic one is used up. It just cannot run twice at the same time.
    @Test("an explicit pass does not need a fresh attempt")
    func explicitRunsAnyway() {
        var gate = CatalogLoadGate()
        _ = gate.startIfNeeded(connected: true)
        gate.finish()
        let explicitPass = gate.beginExplicit()
        gate.finish()
        // And it closes the automatic one behind it, so no loop starts here.
        let afterwards = gate.startIfNeeded(connected: true)
        #expect(explicitPass)
        #expect(!afterwards)
    }
}
