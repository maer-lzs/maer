// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Mac branch is NOTWEHR against an OS defect (Apple's fluid-slider
/// haptics assert on the iOS app running on macOS; six byte-identical
/// reports across two app versions, no app frame). The fence that
/// matters is the RED PROBE: the branch may only ever fire in the Mac
/// case, because everywhere else the system slider is the better
/// control and stays untouched.
struct PlatformScrubberTests {
    @Test("die Weiche greift NUR im Mac-Fall")
    func onlyMacAvoidsTheSystemSlider() {
        #expect(PlatformIdiom.avoidsSystemSlider(isAppOnMac: true))
        // Rot-Probe: iPhone und iPad behalten den System-Regler.
        #expect(!PlatformIdiom.avoidsSystemSlider(isAppOnMac: false))
    }

    @Test("auf einem echten iOS-Geraet ist die Weiche aus")
    func runtimeIdiomIsOffHere() {
        // Die Suite laeuft im iOS-Simulator: die Laufzeit-Antwort MUSS
        // false sein, sonst wuerde die Notwehr-Form ausgeliefert, wo sie
        // niemand braucht.
        #expect(!PlatformIdiom.isAppOnMac)
    }
}
#endif
