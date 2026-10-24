// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The side column never shows the cog and the system's back button at
/// once: the cog leaves before a push, and returns after a pop.
struct SideColumnCogTests {
    @Test("leaving the root hides the cog at once, before the back button slides in")
    func leavingTheRootHidesAtOnce() {
        let step = SideColumnCog.step(atRoot: false)
        #expect(step.visible == false)
        #expect(step.after == 0)
    }

    @Test("coming back shows the cog only after the system's pop has run")
    func comingBackWaitsForThePop() {
        let step = SideColumnCog.step(atRoot: true)
        #expect(step.visible)
        // UIKit's push and pop run 0.35 s; the cog waits longer.
        #expect(step.after > 0.35)
    }
}
#endif
