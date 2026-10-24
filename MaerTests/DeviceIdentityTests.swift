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
}
#endif
